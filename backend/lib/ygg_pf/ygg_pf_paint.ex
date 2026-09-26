defmodule YggPF.Paint do
  @moduledoc """
  Query emission for paint and scan, with per-node cooldown and bookkeeping.

  ## Why this exists rather than calling `Sender.many_find_node/2`

  `Sender` picks the nodes to query internally, so the caller never learns which
  nodes were asked. Painting needs that visibility for three reasons: to rate-limit
  per node, to count how many *distinct* nodes are holding our paint, and to show
  the operator what is actually being asked. So node selection is done here.

  ## What actually paints

  In Mainline DHT a node stores the **sender id** of an incoming query against the
  sender's address. The `target` only chooses which nodes get returned in the reply.

  Therefore the payload-bearing `yid` must be sent as the **sender identity**:

      find_node(sender_id = yid_i, target = id_paint_i)

  Sending `id_paint` (prefix + *random* affix) as the identity, as an earlier reading
  of the specification did, paints an id whose checksum can never validate - remote
  nodes store it faithfully and every scanner discards it. That produced 20k+ scan
  replies and zero fragments in the field. `id_paint` is the *probe point*: a random
  affix under the region prefix, used as the `target` so successive paints spread
  across the region instead of converging on one point.

  Both halves of the rendezvous work because the 80-bit prefix is effectively unique -
  no real DHT node shares it - so "closest to `prefix || anything`" resolves to the
  same small, stable set of nodes for every participant, painter and scanner alike.
  """

  require Logger
  alias YggPF.{Const, Funnel}

  @ets_cooldown :ygg_pf_asked
  @ets_unique :ygg_pf_asked_uniq
  @ets_recent :ygg_pf_recent
  @recent_key :recent
  @recent_keep 3

  @type node_entry :: {binary(), binary()}

  @doc "Create the cooldown and bookkeeping tables. Idempotent."
  def create_tables,
    do: TryETS.create_many_named([@ets_cooldown, @ets_unique, @ets_recent], :set, :public, true, true)

  # ------------------------------------------------------------------ #
  # Emission                                                            #
  # ------------------------------------------------------------------ #

  @doc """
  Paint `yid` into the region: advertise ourselves as `yid` to the nodes closest to
  `target`.

  Returns the number of nodes actually queried, which may be fewer than the nodes
  available because each is put on a short cooldown after being asked.
  """
  @spec paint(binary(), binary(), term()) :: non_neg_integer()
  def paint(yid, target, ctx), do: emit(target, yid, ctx, :paint)

  @doc "Scan the region: query `target` under our ordinary node id."
  @spec scan(binary(), term()) :: non_neg_integer()
  def scan(target, ctx), do: emit(target, :nid, ctx, :scan)

  defp emit(target, sender_id, ctx, kind) do
    all = pick_nodes(target)
    ready = Enum.filter(all, fn {_rid, nodev4} -> cooled_down?(nodev4) end)

    Funnel.bump(stage(kind, :target_nodes), length(all))
    if all == [], do: Funnel.bump(stage(kind, :no_nodes))

    Logger.debug(fn ->
      "[YggPF] #{kind}: target=#{hex(target)} sender_id=#{sender_label(sender_id)} " <>
        "candidates=#{length(all)} ready_after_cooldown=#{length(ready)}"
    end)

    sent =
      Enum.reduce(ready, 0, fn {rid, nodev4}, acc ->
        TryETS.set_cooldown_ms(@ets_cooldown, nodev4, Const.ask_cooldown_ms())
        if kind == :paint, do: note_asked(rid, nodev4)

        Logger.debug(fn ->
          "[YggPF]   -> #{kind} #{fmt(nodev4)} their_id=#{hex(rid)}"
        end)

        KRPCOutSync.find_node(target, nodev4, ctx, sender_id)
        acc + 1
      end)

    Funnel.bump(stage(kind, :sent), sent)
    sent
  end

  defp stage(:paint, :target_nodes), do: :paint_target_nodes
  defp stage(:paint, :no_nodes), do: :paint_no_nodes
  defp stage(:paint, :sent), do: :paint_sent
  defp stage(:scan, :target_nodes), do: :scan_target_nodes
  defp stage(:scan, :no_nodes), do: :scan_no_nodes
  defp stage(:scan, :sent), do: :scan_sent

  defp sender_label(:nid), do: "our own node id (:nid)"
  defp sender_label(id) when is_binary(id), do: hex(id) <> " (yid - the payload)"

  defp hex(b) when is_binary(b), do: Base.encode16(b, case: :lower)
  defp hex(other), do: inspect(other)

  defp fmt(u) do
    PrinterSync.peer(u)
  rescue
    _ -> hex(u)
  end

  # Mirrors Sender.send_fn_queries/2: fall back to a random node when the routing
  # table has nothing near the target, so a cold start still makes progress.
  defp pick_nodes(target) do
    case ETSLookup.closest_nodes(target) do
      [] -> ETSLookup.random_nodes(1)
      found -> found
    end
  end

  defp cooled_down?(nodev4), do: TryETS.cooled_down_ms?(@ets_cooldown, nodev4)

  # ------------------------------------------------------------------ #
  # Bookkeeping                                                         #
  # ------------------------------------------------------------------ #

  # `rid` is the remote node's own DHT id, which is what the operator needs to see:
  # it is the identity now holding a copy of our paint.
  defp note_asked(rid, nodev4) do
    TryETS.insert(@ets_unique, {nodev4, rid})

    recent =
      [{rid, nodev4, System.os_time(:millisecond)} | recent()]
      |> Enum.take(@recent_keep)

    TryETS.insert(@ets_recent, {@recent_key, recent})
  end

  @doc "The last few nodes we painted to, newest first: `[{node_id, uaddr, unix_ms}]`."
  @spec recent() :: [{binary(), binary(), integer()}]
  def recent do
    case TryETS.lookup(@ets_recent, @recent_key) do
      [{@recent_key, list}] when is_list(list) -> list
      _absent -> []
    end
  end

  @doc "How many distinct nodes we have painted to in the current epoch."
  @spec unique_asked() :: non_neg_integer()
  def unique_asked, do: TryETS.size(@ets_unique)

  @doc "How many nodes are currently inside their ask cooldown."
  @spec cooling() :: non_neg_integer()
  def cooling, do: TryETS.size(@ets_cooldown)

  @doc """
  Reset the per-epoch unique-node set.

  The cooldown table is deliberately *not* cleared: it is a rate limit on our own
  outbound traffic and has nothing to do with the epoch rotation.
  """
  @spec reset_epoch() :: any()
  def reset_epoch, do: TryETS.delete_all(@ets_unique)

  @doc """
  Re-query the nodes we painted to, asking for the region around our own yid.

  This is a direct test of whether remote nodes actually *retain* our paint.
  Mainline implementations commonly hold an unknown sender as pending and only
  keep it once it answers a verification ping - and our KRPC responder answers
  under our ordinary node id, not under the painted yid. If that is happening,
  painting silently decays and discovery can never work no matter how correct the
  encoding is.

  The replies come back through the normal `:ygg_pf` context, so if a painted node
  still holds us, our own yid reappears and the self-sighting path reports it.
  Counters `verify_asked` / `verify_returned_our_yid` in `YggPF.Funnel` summarise
  the outcome. Bypasses the ask cooldown on purpose: this is a measurement.
  """
  @spec verify(binary(), term()) :: non_neg_integer()
  def verify(own_yid, ctx) when is_binary(own_yid) do
    painted = TryETS.tab2list(@ets_unique)

    Logger.info(
      "[YggPF] PAINT VERIFY: re-querying #{length(painted)} previously painted node(s) " <>
        "for yid=#{Base.encode16(own_yid, case: :lower)}"
    )

    Enum.each(painted, fn {nodev4, _rid} ->
      Funnel.bump(:verify_asked)
      KRPCOutSync.find_node(own_yid, nodev4, ctx, :nid)
    end)

    length(painted)
  end

  @doc "Drop expired cooldown entries."
  @spec clean() :: any()
  def clean, do: TryETS.clean_expired(@ets_cooldown)
end
