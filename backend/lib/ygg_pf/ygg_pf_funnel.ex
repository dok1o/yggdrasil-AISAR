defmodule YggPF.Funnel do
  @moduledoc """
  Stage-by-stage counters for the whole SDP pipeline, plus a diagnosis of where it
  is dying.

  Discovery is a long funnel and every stage can fail silently. A single "0
  candidates" line cannot distinguish "we never painted" from "we painted garbage"
  from "nobody is out there" from "we found peers but cannot reach them". This
  module counts every stage and then reports **the first stage that is zero**,
  together with what that specific zero means and what to check.

      paint : tick -> addr ok -> target nodes -> sent
      scan  : tick -> target nodes -> sent
      reply : reply -> entry -> prefix hit -> checksum ok -> pair
              -> ygg range ok -> candidate -> pingx -> pong -> validated

  Counters are plain ETS and survive the scheduler and scanner independently, so
  both processes write into the same picture.
  """

  require Logger

  @ets :ygg_pf_funnel
  @gauge_best_bits :gauge_best_prefix_bits

  # Ordered: the diagnosis walks this list and stops at the first zero.
  @paint_stages [:paint_tick, :paint_addr_ok, :paint_target_nodes, :paint_sent]
  @scan_stages [:scan_tick, :scan_target_nodes, :scan_sent]
  @reply_stages [
    :reply,
    :entry,
    :prefix_hit,
    :checksum_ok,
    :pair,
    :ygg_ok,
    :candidate,
    :pingx,
    :pong,
    :validated
  ]

  @extra [
    :paint_skip_no_addr,
    :paint_skip_lag,
    :paint_no_nodes,
    :scan_no_nodes,
    :scan_gated,
    :checksum_fail,
    :ygg_fail,
    :self_candidate,
    :reply_stale_epoch,
    :verify_asked,
    :verify_returned_our_yid
  ]

  @all @paint_stages ++ @scan_stages ++ @reply_stages ++ @extra

  def stages, do: @all

  @doc "Create the counter table. Idempotent."
  def create_table, do: TryETS.create_many_named([@ets], :set, :public, true, true)

  @doc "Increment a stage counter."
  @spec bump(atom(), pos_integer()) :: any()
  def bump(stage, n \\ 1) when is_atom(stage) and is_integer(n) do
    case n > 0 do
      true -> TryETS.new_and_count(@ets, stage, :infinite, n)
      false -> :noop
    end
  end

  @doc "Read one counter."
  @spec get(atom()) :: non_neg_integer()
  def get(stage) do
    case TryETS.lookup(@ets, stage) do
      [{^stage, n}] when is_integer(n) -> n
      _absent -> 0
    end
  end

  @doc """
  Record the best (largest) number of leading bits any returned node id shared
  with one of our region prefixes.

  This is the single clearest indicator of whether the DHT is routing us into the
  right neighbourhood at all. An unpainted region typically tops out around 10-25
  bits of accidental agreement; a genuine painted yid scores the full 80.
  """
  @spec note_prefix_bits(non_neg_integer()) :: any()
  def note_prefix_bits(bits) when is_integer(bits) do
    case get(@gauge_best_bits) < bits do
      true -> TryETS.insert(@ets, {@gauge_best_bits, bits})
      false -> :noop
    end
  end

  def best_prefix_bits, do: get(@gauge_best_bits)

  @doc "All counters as a map."
  @spec snapshot() :: map()
  def snapshot do
    Map.new([@gauge_best_bits | @all], &{&1, get(&1)})
  end

  @doc "Clear every counter. Called on epoch roll so each minute is judged on its own."
  def reset, do: TryETS.delete_all(@ets)

  # ------------------------------------------------------------------ #
  # Reporting                                                           #
  # ------------------------------------------------------------------ #

  @doc "Log the funnel and the diagnosis."
  @spec report() :: :ok
  def report do
    s = snapshot()

    Logger.info([
      "\n[YggPF] ------------------- PIPELINE FUNNEL ------------------\n",
      "[YggPF]  PAINT  tick=#{s.paint_tick} addr_ok=#{s.paint_addr_ok} " <>
        "target_nodes=#{s.paint_target_nodes} sent=#{s.paint_sent}\n",
      "[YggPF]         skipped: no_addr=#{s.paint_skip_no_addr} lag=#{s.paint_skip_lag} " <>
        "no_nodes=#{s.paint_no_nodes}\n",
      "[YggPF]  SCAN   tick=#{s.scan_tick} target_nodes=#{s.scan_target_nodes} " <>
        "sent=#{s.scan_sent} gated=#{s.scan_gated} no_nodes=#{s.scan_no_nodes}\n",
      "[YggPF]  REPLY  reply=#{s.reply} entry=#{s.entry} stale_epoch=#{s.reply_stale_epoch}\n",
      "[YggPF]         prefix_hit=#{s.prefix_hit} " <>
        "checksum_ok=#{s.checksum_ok} checksum_fail=#{s.checksum_fail}\n",
      "[YggPF]         pair=#{s.pair} ygg_ok=#{s.ygg_ok} ygg_fail=#{s.ygg_fail} " <>
        "candidate=#{s.candidate} self=#{s.self_candidate}\n",
      "[YggPF]  PROBE  pingx=#{s.pingx} pong=#{s.pong} validated=#{s.validated}\n",
      "[YggPF]  best prefix agreement seen: #{s[@gauge_best_bits]}/80 bits" <>
        bits_note(s[@gauge_best_bits]) <> "\n",
      "[YggPF]  PAINT VERIFY: asked=#{s.verify_asked} " <>
        "still_holding_our_yid=#{s.verify_returned_our_yid}\n",
      diagnosis(s),
      "[YggPF] ------------------------------------------------------"
    ])

    :ok
  end

  defp bits_note(b) when b >= 80, do: "  <- a real painted yid was seen"
  defp bits_note(b) when b >= 40, do: "  <- suspiciously high for noise"
  defp bits_note(0), do: "  <- no replies measured yet"
  defp bits_note(_b), do: "  (normal accidental agreement for an unpainted region)"

  # The whole point of the module: name the first dead stage and explain it.
  defp diagnosis(s) do
    cond do
      s.paint_sent == 0 and s.scan_sent == 0 ->
        why(
          "NOTHING IS BEING SENT AT ALL",
          paint_send_reason(s) <>
            "  Neither paint nor scan emitted a query. Check that Spv.YggPFSup started\n" <>
            "  (enable_ygg must be true) and that the Mainline routing table is populated."
        )

      s.paint_sent == 0 ->
        why("SCANNING BUT NEVER PAINTING", paint_send_reason(s))

      s.reply == 0 ->
        why(
          "QUERIES SENT, NO REPLIES COMING BACK",
          "  #{s.scan_sent + s.paint_sent} queries went out and not one reply was routed\n" <>
            "  back to YggPF. Either the KRPC context is not reaching\n" <>
            "  KRPCReplySubTask.handle_ctx/4, or outbound UDP is being dropped."
        )

      s.entry == 0 ->
        why(
          "REPLIES ARRIVE BUT CONTAIN NO NODES",
          "  Peers are answering with empty node lists. Unusual - check that the\n" <>
            "  find_node target is well formed."
        )

      s.prefix_hit == 0 ->
        why(
          "NO ID IN THE REGION - NOBODY'S PAINT IS VISIBLE (not even ours)",
          "  #{s.entry} node ids were examined and none carried one of our 80-bit\n" <>
            "  prefixes. Best agreement seen was #{s[@gauge_best_bits]}/80 bits.\n" <>
            "  Most likely one of:\n" <>
            "    (a) we are not painting - see PAINT above (sent=#{s.paint_sent});\n" <>
            "    (b) remote nodes accept our paint but drop it again, e.g. they only\n" <>
            "        keep a node id after verifying it with a ping we answer under a\n" <>
            "        DIFFERENT id - run PAINT VERIFY (asked=#{s.verify_asked},\n" <>
            "        still_holding=#{s.verify_returned_our_yid}) to confirm;\n" <>
            "    (c) no other node is painting, and our own paint has not yet come back."
        )

      s.checksum_ok == 0 and s.checksum_fail > 0 ->
        why(
          "PAINTED IDS FOUND, BUT EVERY AFFIX FAILS ITS CHECKSUM",
          "  #{s.checksum_fail} ids carried a correct region prefix and a bad affix.\n" <>
            "  That is the signature of painting an id whose affix is not a real\n" <>
            "  payload - e.g. advertising id_paint (random affix) as the sender id\n" <>
            "  instead of the yid. It can also mean a peer is using a different\n" <>
            "  checksum or bit-reversal convention than we are."
        )

      s.pair == 0 ->
        why(
          "ONLY ONE HALF OF THE ADDRESS IS EVER FOUND",
          "  #{s.checksum_ok} valid fragments, but never both parts together, so no\n" <>
            "  address can be reassembled. Both part 0 and part 1 must be found within\n" <>
            "  the same epoch. Check that painting covers BOTH parts."
        )

      s.ygg_ok == 0 and s.ygg_fail > 0 ->
        why(
          "FRAGMENTS COMBINE BUT NEVER FORM A VALID YGGDRASIL ADDRESS",
          "  #{s.ygg_fail} combinations reconstructed outside 200::/7. Fragments from\n" <>
            "  different nodes are being mispaired, or part order is inverted."
        )

      s.candidate == 0 ->
        why("NO CANDIDATES", "  Reconstruction produced nothing this window.")

      s.pingx == 0 ->
        why(
          "CANDIDATES FOUND BUT NEVER PROBED",
          "  #{s.candidate} candidates and no pingx sent - all of them were either our\n" <>
            "  own address (self=#{s.self_candidate}) or still inside their cooldown."
        )

      s.pong == 0 ->
        why(
          "PROBED, NO PONG",
          "  #{s.pingx} pingx sent, no binary PF pong. The reconstructed peers are\n" <>
            "  unreachable, or they are legacy nodes that answer bencoded ping only.\n" <>
            "  Per spec section 31 these are correctly discarded."
        )

      s.validated == 0 ->
        why(
          "PONGS ARRIVE BUT NOTHING BECOMES TRUSTED",
          "  #{s.pong} pong(s) over the underlay, 0 validated over Yggdrasil.\n" <>
            "  Trust requires an authenticated pong over the Ygg transport\n" <>
            "  (spec section 34). Check that the embedded Ygg node is up and that\n" <>
            "  YggPF.YggProbe can resolve the peer's key."
        )

      true ->
        "[YggPF]  DIAGNOSIS: pipeline healthy end to end " <>
          "(#{s.validated} validated fnode(s)).\n"
    end
  end

  defp paint_send_reason(s) do
    cond do
      s.paint_skip_no_addr > 0 ->
        "  Painting skipped #{s.paint_skip_no_addr}x because our own Yggdrasil address\n" <>
          "  is not available yet - the embedded Ygg node is not ready, so there is\n" <>
          "  nothing to paint.\n"

      s.paint_no_nodes > 0 ->
        "  Painting had no DHT nodes to send to (#{s.paint_no_nodes}x). The Mainline\n" <>
          "  routing table is empty or has nothing near the region prefix.\n"

      s.paint_skip_lag > 0 ->
        "  Painting is still withheld behind the scan lag (#{s.paint_skip_lag}x).\n" <>
          "  Expected briefly at startup; persistent means scanning never ran.\n"

      s.paint_tick == 0 ->
        "  The paint dispatcher never ran. The scheduler may not be ticking.\n"

      true ->
        "  Reason not captured.\n"
    end
  end

  defp why(headline, detail) do
    "[YggPF]  DIAGNOSIS: #{headline}\n" <> detail <> "\n"
  end
end
