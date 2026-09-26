defmodule YggPF.Log do
  @moduledoc """
  Distinguishable bootstrap failure conditions (spec sections 41-45).

  Spec section 41 is explicit: these must not collapse into a generic "bootstrap failed".
  Each condition points at a different root cause and a different user action, so
  `classify/1` returns them as distinct tagged tuples and `report/1` logs each with
  its own message.

  | Condition | Meaning | Spec |
  |---|---|---|
  | `:wall_clock_desync` | epoch scheme fails, fixed-prefix fallback works | 42 |
  | `:too_few_yaddrs` | fewer than 4 reachable yaddrs - degraded, not fatal | 43 |
  | `:no_new_candidates` | nothing new, but a prior-run cache exists | 44 |
  | `:no_candidates_no_dht` | 20s+, no candidates, no DHT bootstrap | 45 |

  `classify/1` is pure, so the whole taxonomy is testable without a running node.
  """

  require Logger
  alias YggPF.Const

  @type state :: %{
          optional(:epoch_candidates) => non_neg_integer(),
          optional(:fixed_candidates) => non_neg_integer(),
          optional(:reachable_yaddrs) => non_neg_integer(),
          optional(:new_candidates) => non_neg_integer(),
          optional(:cached_fnodes) => non_neg_integer(),
          optional(:dht_booted?) => boolean(),
          optional(:elapsed_ms) => non_neg_integer()
        }

  @type condition ::
          {:wall_clock_desync, map()}
          | {:too_few_yaddrs, map()}
          | {:no_new_candidates, map()}
          | {:no_candidates_no_dht, map()}

  @doc """
  Classify the current bootstrap state into zero or more distinct conditions.

  Conditions are independent - more than one can hold at once, and each is reported
  separately rather than being folded into a single verdict.
  """
  @spec classify(state()) :: [condition()]
  def classify(state) when is_map(state) do
    []
    |> maybe_wall_clock_desync(state)
    |> maybe_too_few_yaddrs(state)
    |> maybe_no_new_candidates(state)
    |> maybe_no_candidates_no_dht(state)
    |> Enum.reverse()
  end

  # spec section 42 - the epoch-dependent scheme finds nothing while the epoch-independent
  # fixed prefix does. Both paths use the same DHT, the same encoding and the same
  # peers; the only variable that distinguishes them is the epoch term in the
  # prefix. So this asymmetry points squarely at the system clock.
  defp maybe_wall_clock_desync(acc, %{epoch_candidates: 0, fixed_candidates: f} = s)
       when is_integer(f) and f > 0 do
    [{:wall_clock_desync, Map.take(s, [:epoch_candidates, :fixed_candidates])} | acc]
  end

  defp maybe_wall_clock_desync(acc, _state), do: acc

  # spec section 43 - degraded discovery, explicitly not total failure.
  defp maybe_too_few_yaddrs(acc, %{reachable_yaddrs: n} = s) when is_integer(n) do
    case n < Const.min_reachable_yaddrs() do
      true -> [{:too_few_yaddrs, Map.take(s, [:reachable_yaddrs])} | acc]
      false -> acc
    end
  end

  defp maybe_too_few_yaddrs(acc, _state), do: acc

  # spec section 44 - nothing new, but we are not starting from nothing. Cached state may
  # still be usable, so this is a visibility warning rather than a failure.
  defp maybe_no_new_candidates(acc, %{new_candidates: 0, cached_fnodes: c} = s)
       when is_integer(c) and c > 0 do
    [{:no_new_candidates, Map.take(s, [:cached_fnodes])} | acc]
  end

  defp maybe_no_new_candidates(acc, _state), do: acc

  # spec section 45 - hard network/bootstrap failure. Must not block forever.
  defp maybe_no_candidates_no_dht(acc, %{elapsed_ms: ms} = s) when is_integer(ms) do
    if ms >= Const.no_boot_deadline_ms() and
         Map.get(s, :new_candidates, 0) == 0 and
         Map.get(s, :dht_booted?, false) == false do
      [{:no_candidates_no_dht, Map.take(s, [:elapsed_ms])} | acc]
    else
      acc
    end
  end

  defp maybe_no_candidates_no_dht(acc, _state), do: acc

  @doc "Classify and log. Returns the conditions so callers can act on them."
  @spec report(state()) :: [condition()]
  def report(state) do
    conditions = classify(state)
    Enum.each(conditions, &log/1)
    conditions
  end

  defp log({:wall_clock_desync, d}) do
    Logger.error(
      "[YggPF] WALL CLOCK DESYNC SUSPECTED: epoch-derived prefixes yielded 0 candidates " <>
        "but the epoch-independent fixed prefix yielded #{d.fixed_candidates}. " <>
        "The 1-minute epoch is shared state - check system clock synchronisation (NTP)."
    )
  end

  defp log({:too_few_yaddrs, d}) do
    Logger.warning(
      "[YggPF] DEGRADED DISCOVERY: only #{d.reachable_yaddrs} reachable yaddr(s), " <>
        "below the minimum of #{Const.min_reachable_yaddrs()}. " <>
        "Discovery continues; this is not a total bootstrap failure."
    )
  end

  defp log({:no_new_candidates, d}) do
    Logger.warning(
      "[YggPF] NO NEW CANDIDATES this cycle, but #{d.cached_fnodes} fnode(s) are cached " <>
        "from a prior run. Possible causes: reduced network visibility, temporary " <>
        "connectivity loss, or DHT bootstrap degradation. Cached state may still be usable."
    )
  end

  defp log({:no_candidates_no_dht, d}) do
    Logger.error(
      "[YggPF] NETWORK/BOOTSTRAP FAILURE: #{div(d.elapsed_ms, 1000)}s elapsed with no " <>
        "candidates and no Mainline DHT bootstrap. Not waiting further - check UDP " <>
        "connectivity and whether outbound DHT traffic is being filtered."
    )
  end

  @doc "Log a successful pong, mirroring the legacy `GenS.PFLog.log_pong/1` format."
  def log_pong(uaddr, fid) do
    Logger.debug(
      "[YggPF] === PONG === #{PrinterSync.peer(uaddr)} fid=#{Base.encode16(fid, case: :lower)}"
    )
  end

  # ------------------------------------------------------------------ #
  # Self-discovery                                                      #
  # ------------------------------------------------------------------ #

  @doc """
  Log the scanner finding its **own** yaddr, naming the node the finding came from.

  The origin is the whole point of this log line:

    * from **another** node - our paint reached the DHT, was stored by a peer we
      did not query directly, and came back to us. This is positive proof that we
      are discoverable, and the strongest signal that painting works end to end.
    * from **ourselves** - a local echo out of our own routing table. Expected
      noise; it says nothing about whether anyone else can find us.
    * **unattributed** - no responder was recorded, so it could be either.

  Returns the origin so callers can count it.
  """
  @spec log_self_discovery(map()) :: :self | :other | :unknown
  def log_self_discovery(%{yaddr: {ip, port}} = candidate) do
    responders = Map.get(candidate, :responders, [])
    uaddrs = Map.get(candidate, :uaddrs, [])
    origin = YggPF.Self.origin(responders)
    addr = "#{:inet.ntoa(ip)}:#{port}"

    case origin do
      :other ->
        Logger.info(
          "[YggPF] SELF-DISCOVERY: own yaddr #{addr} was returned by OTHER node(s) " <>
            "#{peers(responders)} - origin is a third party, so our paint has " <>
            "propagated and we are discoverable."
        )

      :self ->
        Logger.debug(
          "[YggPF] SELF-DISCOVERY: own yaddr #{addr} was returned by the SAME node " <>
            "(ourselves, #{peers(responders)}) - local echo of our own paint, " <>
            "not evidence of propagation."
        )

      :unknown ->
        Logger.debug(
          "[YggPF] SELF-DISCOVERY: own yaddr #{addr} found but the origin is " <>
            "UNATTRIBUTED (#{origin_reason(responders)}) - cannot tell a third-party " <>
            "sighting from a local echo."
        )
    end

    warn_on_uaddr_mismatch(addr, uaddrs, origin)
    origin
  end

  def log_self_discovery(_malformed), do: :unknown

  # Someone reporting our yaddr against an underlay address that is not ours is
  # worth surfacing, but it is not automatically an attack: our own uaddr can
  # legitimately differ per observer under NAT.
  defp warn_on_uaddr_mismatch(_addr, [], _origin), do: :ok

  defp warn_on_uaddr_mismatch(addr, uaddrs, origin) when origin in [:other, :unknown] do
    known = Enum.reject(uaddrs, &is_nil/1)

    cond do
      known == [] ->
        :ok

      is_nil(YggPF.Self.uaddr()) ->
        :ok

      Enum.any?(known, &YggPF.Self.own_uaddr?/1) ->
        :ok

      true ->
        Logger.warning(
          "[YggPF] SELF-DISCOVERY: own yaddr #{addr} is painted against uaddr(s) " <>
            "#{peers(known)}, none of which is ours (#{peer(YggPF.Self.uaddr())}). " <>
            "Either a NAT remapping or another node painting our address."
        )
    end
  end

  defp warn_on_uaddr_mismatch(_addr, _uaddrs, _origin), do: :ok

  defp origin_reason(responders) do
    case Enum.reject(responders, &is_nil/1) do
      [] -> "responder not recorded"
      _known -> "own uaddr not yet known"
    end
  end

  defp peers(list) do
    case list |> Enum.reject(&is_nil/1) |> Enum.map(&peer/1) do
      [] -> "unknown"
      names -> Enum.join(names, ", ")
    end
  end

  defp peer(uaddr) do
    PrinterSync.peer(uaddr)
  rescue
    _ -> inspect(uaddr)
  end
end
