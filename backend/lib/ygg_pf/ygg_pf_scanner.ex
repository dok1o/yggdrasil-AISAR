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

  alias YggPF.{Codec, Const, Funnel, Log, Reconstruct, Self, Store, Wire}

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
              rejected_yaddr_mismatch: 0,
              # self-sightings: our own yaddr scanned back out of the DHT,
              # split by who returned it (see YggPF.Self.origin/1)
              self_sightings: 0,
              self_via_other: 0,
              self_via_self: 0,
              self_via_unknown: 0
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

  @doc """
  Feed a `nodes` reply in. Called from the KRPC reply path for the `:ygg_pf` context.

  `responder` is the underlay address of the node that sent the reply. Supplying it
  is what lets a self-sighting be attributed to a third party rather than to our own
  echo; pass `nil` only when the origin genuinely is not available.
  """
  def nodes_reply(server \\ __MODULE__, nodes, cursor, epoch, responder),
    do: GenServer.cast(server, {:nodes, nodes, cursor, epoch, responder})

  @doc """
  Feed a reply to a fixed-prefix (epoch-independent) query in (spec section 27).

  Counted separately so that "the epoch path found nothing but the fixed path
  worked" stays detectable - that asymmetry is the spec section 42 clock-desync signal.
  """
  def fixed_nodes_reply(server \\ __MODULE__, nodes, responder),
    do: GenServer.cast(server, {:fixed_nodes, nodes, responder})

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
  def handle_cast({:nodes, nodes, cursor, epoch, responder}, st) do
    Funnel.bump(:reply)
    live = Codec.current_epoch()
    if epoch != live, do: Funnel.bump(:reply_stale_epoch)

    Logger.debug(fn ->
      "[YggPF] reply: #{length(nodes)} entries from #{fmt(responder)} " <>
        "ctx cursor=#{cursor} epoch=#{epoch}" <>
        if(epoch != live, do: " STALE (live epoch #{live})", else: "")
    end)

    frags = Reconstruct.fragments(nodes, cursor, epoch, responder)
    matched = Reconstruct.match_count(frags)

    # Density feedback drives cursor escalation (spec section 21).
    if matched > 0, do: GenS.YggPFScheduler.observe(st.scheduler, matched)

    # Our own yaddr is separated out before probing: pinging ourselves would waste
    # a query, occupy a cooldown slot and could register us as our own candidate.
    {mine, others} =
      frags
      |> Reconstruct.candidates()
      |> Enum.split_with(&Self.own_yaddr?(&1.yaddr))

    Funnel.bump(:self_candidate, length(mine))
    if mine != [], do: Funnel.bump(:verify_returned_our_yid, length(mine))
    origins = Enum.map(mine, &Log.log_self_discovery/1)
    Enum.each(others, &probe_candidate/1)

    st = %{
      st
      | epoch_candidates: st.epoch_candidates + length(others),
        stats:
          st.stats
          |> Map.update!(:replies, &(&1 + 1))
          |> Map.update!(:fragments, &(&1 + matched))
          |> Map.update!(:candidates, &(&1 + length(others)))
          |> Map.update!(:pingx_sent, &(&1 + length(others)))
          |> count_origins(origins)
    }

    {:noreply, st}
  end

  def handle_cast({:fixed_nodes, nodes, responder}, st) do
    frags = Reconstruct.fixed_fragments(nodes, responder)

    {mine, others} =
      frags
      |> Reconstruct.candidates()
      |> Enum.split_with(&Self.own_yaddr?(&1.yaddr))

    origins = Enum.map(mine, &Log.log_self_discovery/1)
    Enum.each(others, &probe_candidate/1)

    st = %{
      st
      | fixed_candidates: st.fixed_candidates + length(others),
        stats:
          st.stats
          |> Map.update!(:replies, &(&1 + 1))
          |> Map.update!(:fragments, &(&1 + Reconstruct.match_count(frags)))
          |> count_origins(origins)
    }

    {:noreply, st}
  end

  defp count_origins(stats, origins) do
    Enum.reduce(origins, stats, fn origin, acc ->
      acc
      |> Map.update!(:self_sightings, &(&1 + 1))
      |> Map.update!(origin_key(origin), &(&1 + 1))
    end)
  end

  defp origin_key(:other), do: :self_via_other
  defp origin_key(:self), do: :self_via_self
  defp origin_key(:unknown), do: :self_via_unknown

  # Periodic roll-up of the self-sighting counters. "Has any third party ever
  # returned my yaddr?" is the clearest answer available to "is my paint working?",
  # so it is reported separately from the general scan counters rather than buried.
  defp log_self_visibility(%{self_sightings: 0}) do
    Logger.debug("[YggPF] self-visibility: own yaddr not yet seen back from the DHT")
  end

  defp log_self_visibility(s) do
    Logger.info(
      "[YggPF] self-visibility: #{s.self_sightings} sighting(s) of our own yaddr - " <>
        "#{s.self_via_other} from OTHER nodes, #{s.self_via_self} self-echo, " <>
        "#{s.self_via_unknown} unattributed" <>
        case s.self_via_other do
          0 -> " (no third party has returned our paint yet)"
          _ -> " (paint confirmed discoverable by third parties)"
        end
    )
  end

  # A PF packet over the underlay proves reachability, not identity (spec section 35).
  def handle_cast({:pf_packet, packet, uaddr}, st) do
    case Wire.pong_fid(packet) do
      {:ok, fid} ->
        Funnel.bump(:pong)
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
        Logger.debug(fn ->
          "[YggPF] inbound PF packet from #{fmt(uaddr)} is not a v2 pong: " <>
            inspect(Wire.parse(packet))
        end)

        {:noreply, st}
    end
  end

  # Only this path may promote to trusted (spec section 34, INV-018).
  def handle_cast({:pf_packet_ygg, packet, yaddr}, st) do
    with {:ok, fid} <- Wire.pong_fid(packet),
         true <- Store.yaddr_matches?(fid, yaddr) do
      uaddrs = pending_uaddrs(fid)
      Funnel.bump(:validated)
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

    log_self_visibility(s)

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
  defp probe_candidate(%{uaddrs: uaddrs}) do
    Enum.each(uaddrs, fn uaddr ->
      if TryETS.cooled_down_ms?(@ets_cooldown, uaddr) do
        TryETS.set_cooldown_ms(@ets_cooldown, uaddr, Const.cooldown_ms())
        Funnel.bump(:pingx)
        Logger.info("[YggPF] pingx -> #{fmt(uaddr)} (reconstructed candidate)")
        Wire.pingx(uaddr)
      else
        Logger.debug(fn -> "[YggPF] pingx suppressed, #{fmt(uaddr)} still cooling" end)
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

  defp fmt(nil), do: "unknown"

  defp fmt(u) do
    PrinterSync.peer(u)
  rescue
    _ -> Base.encode16(u, case: :lower)
  end
  defp now_ms, do: System.monotonic_time(:millisecond)
end
