defmodule PieceProcessor do
  require Logger
  @compile {:inline, [collect: 8]}
  @max_piece_size 1_024 * 1_024 * 16
  @request_window 255
  @piece "piece"
  @msg_type "msg_type"
  def collect(sec_tr, ih, peer, pe_id, oe_id, utm_size, deadline, plen),
    do: do_collect(sec_tr, ih, peer, pe_id, oe_id, utm_size, deadline, plen)
  defp do_collect(
         secure_tr_struct,
         ih,
         peer,
         peer_ext_id,
         own_ext_id,
         utm_size,
         deadline,
         piece_size
       )
  defp do_collect(_sec_tr, _ih, _peer, _pe, _oe, _utm_size, _dl, plen)
       when plen > @max_piece_size do
    Logger.debug("[Piece] piece size overflow: #{plen}")
    {:error, :piece_overflow}
  end
  defp do_collect(sec_tr, ih, peer, pe_id, oe_id, utm_size, deadline, plen) do
    cached = MetadataCache.get_cached_pieces(ih)
    piece_count = div(utm_size + plen - 1, plen)
    :telemetry.execute(
      [:dht, :metadata, :piece_collection_started],
      %{total_pieces: piece_count, total_size: utm_size, piece_length: plen},
      %{}
    )
    pending =
      MapSet.new(0..(piece_count - 1))
      |> MapSet.difference(MapSet.new(Map.keys(cached)))
    st = %{
      sec_tr: sec_tr,
      ih: ih,
      peer: peer,
      peer_ext_id: pe_id,
      own_ext_id: oe_id,
      pending: pending,
      requested: %{},
      received: cached,
      fails: 0,
      total_size: utm_size,
      piece_count: piece_count,
      deadline: deadline,
      plen: plen,
      choked: true
    }
    PieceProcessor.Loop.run(st)
  end
  def request_one_piece(sec_tr, peer_ext_id, idx) do
    payload_map = %{@msg_type => 0, @piece => idx}
    bencode = SimpleBencodeSync.encode(payload_map)
    length = byte_size(bencode) + 2
    msg = <<length::32-big, 20, peer_ext_id, bencode::binary>>
    result = SecureTransport.send(sec_tr, msg)
    case result do
      {:ok, _} -> :noop
      {:error, r} -> Logger.debug("[Piece] of #{inspect(peer_ext_id)} failed: #{inspect(r)}")
    end
    result
  end
  defp last_piece?(idx, total_pieces), do: idx == total_pieces - 1
  def expected_piece_size(idx, total_pieces, total_size, plen) do
    case last_piece?(idx, total_pieces) do
      true ->
        case rem(total_size, plen) do
          0 -> plen
          rem -> rem
        end
      false ->
        plen
    end
  end
  def priority_score(idx, total) do
    cond do
      idx == 0 -> -1_000_000
      idx == total - 1 -> -999_999
      idx == 1 -> -999_998
      idx == total - 2 -> -999_997
      :middle_piece -> min(idx, total - 1 - idx) * -1000 - idx
    end
  end
  def assemble(pieces, count) when map_size(pieces) == count do
    utm =
      0..(count - 1)
      |> Enum.map(&Map.fetch!(pieces, &1))
      |> :erlang.iolist_to_binary()
    {:ok, utm}
  end
  def assemble(pieces, count) do
    missing = for i <- 0..(count - 1), !Map.has_key?(pieces, i), do: i
    Logger.error(
      "[Piece] Incomplete, have: #{map_size(pieces)}, need: #{count} missing: #{inspect(missing)}"
    )
    {:error, :missing_pieces}
  end
  def request_window, do: @request_window
end
defmodule PieceProcessor.Loop do
  import TimeSync
  require Logger
  @max_attempts 25
  @retry_delay_ms 750
  @piece_timeout 10_000
  @added "added"
  @piece "piece"
  @msg_type "msg_type"
  @keepalive <<>>
  @unchoke 1
  @choke 0
  @reject 2
  @utm_data 1
  def run(%{pending: pending, fails: fails} = loop_st), do: do_run(pending, fails, loop_st)
  defp metadata_extension?(rcvd_id, own_ext_id), do: rcvd_id == own_ext_id
  defp good_idx?(idx, pc), do: idx >= 0 and idx < pc
  defp good_piece_size?(benc, cons, expd), do: byte_size(benc) - cons == expd
  defp retry_sleep(), do: Process.sleep(@retry_delay_ms + :rand.uniform(100))
  defp do_run(pending, fails, loop_st) do
    scenario =
      case {MapSet.size(pending), fails >= @max_attempts} do
        {0, _failed?} -> :finished
        {_pend, true} -> :failed
        {_pend, false} -> :continue
      end
    case scenario do
      :finished ->
        finish_collection(loop_st)
      :failed ->
        {:error, :max_piece_retries}
      :continue ->
        loop_st
        |> ensure_requests_sent()
        |> check_deadline_and_receive()
    end
  end
  defp ensure_requests_sent(%{choked: true} = st), do: st
  defp ensure_requests_sent(%{pending: pending, requested: req, piece_count: pc} = st) do
    now = mono_ms()
    slots =
      max(0, PieceProcessor.request_window() - map_size(req))
    retryable =
      pending
      |> Enum.filter(fn idx ->
        case Map.get(req, idx) do
          nil -> false
          sent_at -> now - sent_at > @retry_delay_ms
        end
      end)
    fresh =
      pending
      |> Enum.filter(fn idx ->
        not Map.has_key?(req, idx)
      end)
    to_request = select_requests(retryable, fresh, slots, pc)
    case to_request do
      [] -> st
      list -> send_requests(st, list)
    end
  end
  defp select_requests(retryable, fresh, slots, piece_count) do
    (retryable ++ Enum.take(fresh, slots))
    |> Enum.sort_by(&PieceProcessor.priority_score(&1, piece_count))
  end
  defp send_requests(st, []), do: st
  defp send_requests(%{sec_tr: s, peer_ext_id: pe_id, requested: req} = st, [idx | rest]) do
    case PieceProcessor.request_one_piece(s, pe_id, idx) do
      {:ok, next_sec_tr} ->
        new_req = Map.put(req, idx, mono_ms())
        send_requests(%{st | sec_tr: next_sec_tr, requested: new_req}, rest)
      {:error, :busy} ->
        st
      {:error, reason} ->
        if MathSync.rolled?(1, 400),
          do: Logger.debug("[Piece] Request fail: #{inspect(reason)}")
        %{st | fails: st.fails + 1}
    end
  end
  defp check_deadline_and_receive(%{deadline: dl} = loop_st) do
    case deadline?(dl) do
      true -> {:error, :deadline_exceeded}
      false -> recv_to_run_loop(loop_st, deadline_in(dl))
    end
  end
  defp recv_to_run_loop(%{sec_tr: secure_tr_st, own_ext_id: own_ext_id} = loop_st, rem_ms) do
    timeout = max(0, min(rem_ms, @piece_timeout))
    case SecureTransport.recv_stream(secure_tr_st, timeout) do
      {:ok, @keepalive, next_sec_tr} ->
        run(%{loop_st | sec_tr: next_sec_tr})
      {:ok, <<20, rcvd_id, bencode::binary>>, next_sec_tr} ->
        case metadata_extension?(rcvd_id, own_ext_id) do
          true -> process_metadata_payload(bencode, %{loop_st | sec_tr: next_sec_tr})
          false -> handle_other_extension(bencode, %{loop_st | sec_tr: next_sec_tr})
        end
      {:ok, <<type, _::binary>>, next_sec_tr} when type <= 19 ->
        handle_standard_bt_message(type, %{loop_st | sec_tr: next_sec_tr})
      {:error, :timeout} ->
        handle_timeout(loop_st)
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp handle_standard_bt_message(type, st) do
    if MathSync.rolled?(1, 100), do: log_bt_message_maybe_act(type, st)
    case type do
      @choke ->
        run(%{st | choked: true, requested: %{}})
      @unchoke ->
        run(%{st | choked: false})
      _ignore ->
        run(st)
    end
  end
  defp process_metadata_payload(bencode, %{peer: peer} = st) do
    case SimpleBencodeSync.decode_consuming(bencode) do
      {:ok, %{@msg_type => @utm_data, @piece => idx}, consumed} ->
        handle_piece_data(idx, bencode, consumed, st)
      {:ok, %{@msg_type => @reject, @piece => idx}, _any} ->
        if MathSync.rolled?(1, 20) do
          Logger.debug("[Piece] Peer #{PrinterSync.peer(peer)} rejected piece ask #{idx}")
        end
        new_requested = Map.delete(st.requested, idx)
        run(%{st | requested: new_requested, fails: st.fails + 1})
      {:ok, %{@msg_type => @choke}, _piece} ->
        run(st)
      {:ok, _msg_type, _bytes} ->
        run(st)
      {:error, _reason} ->
        {:error, :decode_failed}
    end
  end
  defp handle_piece_data(idx, bencode, consumed, %{ih: ih, piece_count: pc} = st) do
    case good_idx?(idx, pc) do
      false ->
        run(%{st | fails: st.fails + 1})
      true ->
        expected =
          PieceProcessor.expected_piece_size(
            idx,
            pc,
            st.total_size,
            st.plen
          )
        case good_piece_size?(bencode, consumed, expected) do
          true ->
            st
            |> process_good_piece(idx, bencode, consumed, expected, ih)
            |> run()
          false ->
            run(%{st | fails: st.fails + 1})
        end
    end
  end
  defp process_good_piece(st, idx, benc, cons, expd, ih) do
    %{received: rcvd, pending: pend, requested: req} = st
    data = binary_part(benc, cons, expd)
    MetadataCache.cache_piece(ih, idx, data)
    new_recv = Map.put(rcvd, idx, data)
    new_pend = MapSet.delete(pend, idx)
    new_req = Map.delete(req, idx)
    %{st | received: new_recv, pending: new_pend, requested: new_req, fails: 0}
  end
  defp handle_other_extension(bencode, %{ih: ih, peer: peer} = st) do
    case SimpleBencodeSync.decode(bencode) do
      {:ok, %{@added => p_bin} = _peer_ext_dict} -> pex_run(st, ih, p_bin, peer)
      {:ok, _other_ext} -> handle_unknown_msg(st)
      {:error, _reason} -> run(%{st | fails: st.fails + 1})
    end
  end
  defp pex_run(st, ih, peers_bin, peer) do
    GenS.IHWorkerRouter.find(ih, peers_bin, peer, :pex)
    run(st)
  end
  defp log_bt_message_maybe_act(type, st) do
    name =
      case type do
        0 -> "CHOKE (Metadata may stall)"
        1 -> "UNCHOKE (Resuming requests)"
        2 -> "INTERESTED"
        3 -> "NOT_INTERESTED"
        4 -> "HAVE"
        5 -> nil
        6 -> "REQUEST"
        7 -> "PIECE"
        8 -> "CANCEL"
        9 -> nil
        _ -> "UNKNOWN(#{type})"
      end
    if name do
      Logger.debug("#{log_ctx(st)} Protocol: #{name}")
    end
  end
  defp log_ctx(st),
    do: "[Piece] [#{map_size(st.received)}/#{st.piece_count}] [#{PrinterSync.peer(st.peer)}]"
  defp handle_unknown_msg(%{fails: fails} = st) do
    new_fails = fails + 1
    failed? = fails + 1 >= @max_attempts
    case failed? do
      true -> {:error, :too_many_unknown_messages}
      false -> run(%{st | fails: new_fails})
    end
  end
  defp handle_timeout(%{fails: fails, deadline: dl} = st) do
    retry? =
      case {fails < @max_attempts, deadline_in(dl) > @retry_delay_ms} do
        {true, true} -> :sleep_and_retry
        {false, _} -> :too_many_fails
        {_, false} -> :no_time
      end
    case retry? do
      :sleep_and_retry ->
        retry_sleep()
        run(%{st | fails: fails + 1})
      :too_many_fails ->
        {:error, :metadata_timeout}
      :no_time ->
        {:error, :deadline_exceeded}
    end
  end
  defp finish_collection(%{received: recvd, piece_count: pc} = _st) do
    :telemetry.execute(
      [:dht, :metadata, :piece_collection_complete],
      %{pieces: pc},
      %{}
    )
    case PieceProcessor.assemble(recvd, pc) do
      {:error, _reason} = err -> err
      {:ok, utm} -> {:ok, utm}
    end
  end
end