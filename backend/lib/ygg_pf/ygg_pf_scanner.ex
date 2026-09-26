defmodule GenS.YggPFScanner do
  @moduledoc """
  Candidate discovery and validation (spec sections 8, 9, 28, 31-35).

      nodes reply
          -> YggPF.Reconstruct.fragments/3     prefix + checksum filtering
          -> match count -> cursor observe     (spec section 21)
          -> YggPF.Reconstruct.candidates/2    combinatorial reconstruction
          -> pingx over uaddr                  (spec section 31)
          -> binary v2 pong -> fid             (spec section 32)
          -> yaddr probe                       (spec section 34)
          -> YggPF.Store trusted write         (spec sections 33, 35)

  ## Why a pong alone is not enough

  Spec section 34 is protocol-critical: a `fid` may only enter the trusted tables if the
  **yaddr** answered, not merely the uaddr. Otherwise a fork that changed the `yid`
  encoding, or any node that simply answers on the underlay, would be indistinguishable
  from a real peer. `handle_pong/2` therefore records uaddr reachability as
  *pending* and schedules a separate yaddr probe; only `handle_yaddr_pong/2`
  promotes.

  The reconstructed yaddr is additionally checked against
  `Ygg.Address.addr_for_key(fid)`, so a peer cannot answer for a `fid` whose derived
  address differs from the one we painted and probed.
  """

  use GenServer
  require Logger

  alias YggPF.{Codec, Const, Log, Reconstruct, Store, Wire}

  @ets_cooldown :ygg_pf_pinged
  @stats_tick_ms 5_000
  @clean_tick_ms 2_000

  defstruct stats: %{
              replies: 0,
              fragments: 0,
              candidates: 0,
              pingx_sent: 0,
              pongs: 0,
              validated: 0,
              uaddr_only: 0,
              rejected_yaddr_mismatch: 0
            },
            started_ms: 0,
            epoch_candidates: 0,
            fixed_candidates: 0,
            scheduler: nil

  # ------------------------------------------------------------------ #
  # API                                                                 #
  # ------------------------------------------------------------------ #

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: name(opts))
  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @doc "Feed a `nodes` reply in. Called from the KRPC reply path for the `:ygg_pf` context."
  def nodes_reply(server \\ __MODULE__, nodes, cursor, epoch),
    do: GenServer.cast(server, {:nodes, nodes, cursor, epoch})

  @doc "Feed an inbound PF packet received over the **underlay**."
  def pf_packet(server \\ __MODULE__, packet, uaddr),
    do: GenServer.cast(server, {:pf_packet, packet, uaddr})

  @doc "Feed an inbound PF packet received over the **Yggdrasil** transport."
  def pf_packet_ygg(server \\ __MODULE__, packet, yaddr),
    do: GenServer.cast(server, {:pf_packet_ygg, packet, yaddr})

  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ------------------------------------------------------------------ #
  # Callbacks                                                           #
  # ------------------------------------------------------------------ #

  @impl true
  def init(opts) do
    Store.create_tables()
    TryETS.create_many_named([@ets_cooldown], :set, :public, true, true)

    if Keyword.get(opts, :autotick, true) do
      :timer.send_interval(@stats_tick_ms, :stats)
      :timer.send_interval(@clean_tick_ms, :clean)
    end

    {:ok,
     %__MODULE__{
       started_ms: now_ms(),
       scheduler: Keyword.get(opts, :scheduler, GenS.YggPFScheduler)
     }}
  end

  @impl true
  def handle_call(:stats, _from, st), do: {:reply, st.stats, st}

  @impl true
  def handle_cast({:nodes, nodes, cursor, epoch}, st) do
    frags = Reconstruct.fragments(nodes, cursor, epoch)
    matched = Reconstruct.match_count(frags)

    # Density feedback drives cursor escalation (spec section 21).
    if matched > 0, do: GenS.YggPFScheduler.observe(st.scheduler, matched)

    candidates = Reconstruct.candidates(frags)
    Enum.each(candidates, &probe_candidate/1)

    st = %{
      st
      | epoch_candidates: st.epoch_candidates + length(candidates),
        stats:
          st.stats
          |> Map.update!(:replies, &(&1 + 1))
          |> Map.update!(:fragments, &(&1 + matched))
          |> Map.update!(:candidates, &(&1 + length(candidates)))
          |> Map.update!(:pingx_sent, &(&1 + length(candidates)))
    }

    {:noreply, st}
  end

  # A PF packet over the underlay proves reachability, not identity (spec section 35).
  def handle_cast({:pf_packet, packet, uaddr}, st) do
    case Wire.pong_fid(packet) do
      {:ok, fid} ->
        Log.log_pong(uaddr, fid)
        Store.note_uaddr_response(fid, uaddr)
        probe_yaddr(fid)

        {:noreply,
         %{
           st
           | stats:
               st.stats
               |> Map.update!(:pongs, &(&1 + 1))
               |> Map.update!(:uaddr_only, &(&1 + 1))
         }}

      :error ->
        # Malformed, wrong opcode, or a legacy v1 packet that cannot carry a fid.
        {:noreply, st}
    end
  end

  # Only this path may promote to trusted (spec section 34, INV-018).
  def handle_cast({:pf_packet_ygg, packet, yaddr}, st) do
    with {:ok, fid} <- Wire.pong_fid(packet),
         true <- Store.yaddr_matches?(fid, yaddr) do
      uaddrs = pending_uaddrs(fid)
      Store.note_yaddr_response(fid, yaddr, uaddrs)

      Logger.info(
        "[YggPF] VALIDATED fid=#{short(fid)} via yaddr - now trusted " <>
          "(#{Store.reachable_yaddr_count()} total)"
      )

      {:noreply, %{st | stats: Map.update!(st.stats, :validated, &(&1 + 1))}}
    else
      false ->
        Logger.warning(
          "[YggPF] yaddr/fid mismatch from #{inspect(yaddr)} - refusing to trust. " <>
            "Possible fork or spoofed identity."
        )

        {:noreply,
         %{st | stats: Map.update!(st.stats, :rejected_yaddr_mismatch, &(&1 + 1))}}

      :error ->
        {:noreply, st}
    end
  end

  @impl true
  def handle_info(:stats, st) do
    s = st.stats

    Logger.info(
      "[YggPF] scan: #{s.replies} replies, #{s.fragments} fragments, #{s.candidates} candidates, " <>
        "#{s.pongs} pongs, #{s.validated} validated, #{s.uaddr_only} uaddr-only"
    )

    Log.report(%{
      epoch_candidates: st.epoch_candidates,
      fixed_candidates: st.fixed_candidates,
      reachable_yaddrs: Store.reachable_yaddr_count(),
      new_candidates: s.candidates,
      cached_fnodes: Store.reachable_yaddr_count() + Store.pending_count(),
      dht_booted?: dht_booted?(),
      elapsed_ms: now_ms() - st.started_ms
    })

    {:noreply, st}
  end

  def handle_info(:clean, st) do
    TryETS.clean_expired(@ets_cooldown)
    {:noreply, st}
  end

  def handle_info(_other, st), do: {:noreply, st}

  # ------------------------------------------------------------------ #
  # Probing                                                             #
  # ------------------------------------------------------------------ #

  # spec section 31: every reconstructed candidate is queried with pingx. Cooldown keeps a
  # flooded region from turning into an outbound amplifier (spec section 23).
  defp probe_candidate({_yaddr, uaddrs}) do
    Enum.each(uaddrs, fn uaddr ->
      if TryETS.cooled_down_ms?(@ets_cooldown, uaddr) do
        TryETS.set_cooldown_ms(@ets_cooldown, uaddr, Const.cooldown_ms())
        Wire.pingx(uaddr)
      end
    end)
  end

  # spec section 34: the yaddr probe is what converts reachability into trust.
  defp probe_yaddr(fid) do
    case Ygg.Address.addr_for_key(fid) do
      <<_::binary-16>> = addr ->
        YggPF.YggProbe.pingx(addr, Const.ygg_pf_port(), fid)

      _invalid ->
        Logger.debug("[YggPF] cannot derive yaddr for fid=#{short(fid)}")
    end
  end

  defp pending_uaddrs(fid) do
    case TryETS.lookup(Store.table_pending(), fid) do
      [{^fid, meta}] -> Map.get(meta, :uaddrs, [])
      _absent -> Store.uaddrs(fid)
    end
  end

  defp dht_booted? do
    case TryETS.size(:nodes) do
      n when is_integer(n) and n > 0 -> true
      _none -> false
    end
  end

  defp short(fid), do: fid |> Base.encode16(case: :lower) |> binary_part(0, 12)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
