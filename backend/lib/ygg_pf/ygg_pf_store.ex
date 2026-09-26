defmodule YggPF.Store do
  @moduledoc """
  ETS trust storage for validated fnodes (spec sections 33, 34, 35).

  ## The rule this module exists to enforce

  > If a candidate responds through `uaddr`, the corresponding `fid` must only be
  > saved into the trusted structures if `yaddr` also responds successfully.
  > (spec section 34, INV-018)

  The purpose is to reject forks and incompatible implementations that alter the
  `yid` encoding while still answering on an ordinary underlay address. Answering
  over the Yggdrasil transport proves the peer really is on the Ygg network under
  the `fid` it claims.

  ## Structures

  Two trusted tables, matching spec section 33, plus one explicitly untrusted staging table:

    * `:ygg_fnodes`      - `{fid, meta}`         trusted only
    * `:ygg_fnodes_rev`  - `{{fid, uaddr}, meta}` trusted only
    * `:ygg_pending`     - `{fid, meta}`          uaddr-only, **never** trusted

  Naming and creation follow the house convention established by
  `b_pf_new/pf_routing_table.ex`: public `:set` tables created through
  `TryETS.create_many_named/5` with read and write concurrency enabled.

  Nothing reaches `:ygg_fnodes` or `:ygg_fnodes_rev` except through
  `note_yaddr_response/3`. `note_uaddr_response/3` can only ever write to
  `:ygg_pending`, so uaddr-only reachability structurally cannot be mistaken for
  validation (INV-018).
  """

  require Logger

  @ets_fnodes :ygg_fnodes
  @ets_fnodes_rev :ygg_fnodes_rev
  @ets_pending :ygg_pending

  @sets [@ets_fnodes, @ets_fnodes_rev, @ets_pending]

  @type fid :: <<_::256>>
  @type uaddr :: binary()
  @type yaddr :: {:inet.ip6_address(), :inet.port_number()}
  @type trust :: :validated | :uaddr_only | :unknown

  @doc "Create the three tables. Idempotent; safe to call from a supervisor child's init."
  @spec create_tables() :: any()
  def create_tables, do: TryETS.create_many_named(@sets, :set, :public, true, true)

  def table_fnodes, do: @ets_fnodes
  def table_fnodes_rev, do: @ets_fnodes_rev
  def table_pending, do: @ets_pending

  # ------------------------------------------------------------------ #
  # Writes                                                              #
  # ------------------------------------------------------------------ #

  @doc """
  Record that a candidate answered a `pingx` over its **underlay** address.

  This grants no trust. It writes only to `:ygg_pending` (spec section 35): the node is
  "reachable by uaddr", which is a strictly weaker statement than "validated
  through yaddr".
  """
  @spec note_uaddr_response(fid(), uaddr(), yaddr() | nil) :: :uaddr_only
  def note_uaddr_response(<<fid::binary-32>>, uaddr, yaddr \\ nil) when is_binary(uaddr) do
    meta =
      fid
      |> pending_meta()
      |> Map.merge(%{yaddr: yaddr, last_seen: now_ms()})
      |> Map.update(:uaddrs, [uaddr], &Enum.uniq([uaddr | &1]))

    TryETS.insert(@ets_pending, {fid, meta})
    :uaddr_only
  end

  @doc """
  Record that a candidate answered over its **Yggdrasil** address.

  This is the only promotion path. It writes both trusted structures and clears the
  pending entry.

  `yaddr` must be the address the response actually came from. Callers should have
  already checked it against `Ygg.Address.addr_for_key(fid)` - see `yaddr_matches?/2`.
  """
  @spec note_yaddr_response(fid(), yaddr(), [uaddr()]) :: :validated
  def note_yaddr_response(<<fid::binary-32>>, yaddr, uaddrs \\ []) when is_list(uaddrs) do
    prior = lookup_meta(@ets_fnodes, fid) || pending_meta(fid)

    meta =
      prior
      |> Map.merge(%{
        fid: fid,
        yaddr: yaddr,
        trust: :validated,
        validated_at: prior[:validated_at] || now_ms(),
        last_seen: now_ms()
      })
      |> Map.update(:uaddrs, uaddrs, &Enum.uniq(&1 ++ uaddrs))

    TryETS.insert(@ets_fnodes, {fid, meta})
    Enum.each(meta.uaddrs, &TryETS.insert(@ets_fnodes_rev, {{fid, &1}, meta}))
    TryETS.delete(@ets_pending, fid)
    :validated
  end

  @doc """
  Does `yaddr` match the address derived from `fid`?

  `Ygg.Address.addr_for_key/1` is deterministic, so a peer cannot claim a `fid`
  whose derived address differs from the one that answered. This is the check that
  makes spec section 34's fork protection meaningful rather than cosmetic.
  """
  @spec yaddr_matches?(fid(), yaddr() | :inet.ip6_address()) :: boolean()
  def yaddr_matches?(<<fid::binary-32>>, {ip, _port}), do: yaddr_matches?(fid, ip)

  def yaddr_matches?(<<fid::binary-32>>, {_, _, _, _, _, _, _, _} = ip) do
    case Ygg.Address.addr_for_key(fid) do
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> ->
        {a, b, c, d, e, f, g, h} == ip

      _other ->
        false
    end
  end

  def yaddr_matches?(_fid, _yaddr), do: false

  # ------------------------------------------------------------------ #
  # Reads                                                               #
  # ------------------------------------------------------------------ #

  @doc "Trust level for a `fid` (spec section 35)."
  @spec trust(fid()) :: trust()
  def trust(<<fid::binary-32>>) do
    cond do
      lookup_meta(@ets_fnodes, fid) != nil -> :validated
      lookup_meta(@ets_pending, fid) != nil -> :uaddr_only
      true -> :unknown
    end
  end

  @doc "True only for fids validated through the Yggdrasil path."
  @spec trusted?(fid()) :: boolean()
  def trusted?(fid), do: trust(fid) == :validated

  @doc "Metadata for a trusted fid, or `nil`."
  @spec get(fid()) :: map() | nil
  def get(<<fid::binary-32>>), do: lookup_meta(@ets_fnodes, fid)

  @doc "Known underlay addresses for a trusted fid."
  @spec uaddrs(fid()) :: [uaddr()]
  def uaddrs(fid) do
    case get(fid) do
      nil -> []
      meta -> Map.get(meta, :uaddrs, [])
    end
  end

  @doc "Is this exact `{fid, uaddr}` pair recorded as trusted?"
  @spec trusted_pair?(fid(), uaddr()) :: boolean()
  def trusted_pair?(<<fid::binary-32>>, uaddr),
    do: lookup_meta(@ets_fnodes_rev, {fid, uaddr}) != nil

  @doc "Count of validated fnodes - the input to the spec section 43 degraded-discovery check."
  @spec reachable_yaddr_count() :: non_neg_integer()
  def reachable_yaddr_count, do: TryETS.size(@ets_fnodes)

  @doc "Count of nodes reachable by uaddr only, i.e. not trusted."
  @spec pending_count() :: non_neg_integer()
  def pending_count, do: TryETS.size(@ets_pending)

  @doc "All validated fnodes."
  @spec all_validated() :: [{fid(), map()}]
  def all_validated, do: TryETS.tab2list(@ets_fnodes)

  # ------------------------------------------------------------------ #
  # Internals                                                           #
  # ------------------------------------------------------------------ #

  defp lookup_meta(table, key) do
    case TryETS.lookup(table, key) do
      [{^key, meta}] -> meta
      _absent -> nil
    end
  end

  defp pending_meta(fid) do
    lookup_meta(@ets_pending, fid) ||
      %{fid: fid, trust: :uaddr_only, uaddrs: [], first_seen: now_ms()}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
