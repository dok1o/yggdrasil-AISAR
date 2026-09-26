defmodule SimpleUTP.Protocol do
  import Bitwise
  @init_ledbat_frames 10
  defmacro utp_version, do: 1
  defmacro gain_shift, do: 16
  defmacro max_delivery_queue_size, do: 1_024 * 1_024
  defmacro max_send_buffer_bytes, do: 1_024 * 512
  defmacro max_buffer_map_size, do: 256
  defmacro max_sack_bytes, do: 32
  defmacro max_sack_bits, do: 32 * 8
  defmacro effective_mtu, do: 1400 - (20 + 8 + 20 + (2 + 32))
  defmacro shifted_mtu, do: effective_mtu() <<< gain_shift()
  defmacro ledbat_mtu, do: (effective_mtu() * @init_ledbat_frames) <<< gain_shift()
  defmacro init_ssthresh, do: max_send_buffer_bytes() <<< gain_shift()
  defmacro protocol_to_ms, do: 30_000
  defmacro protocol_to_micro, do: protocol_to_ms() * 1_000
  defmacro burst_pkt_cnt, do: 3
  defmacro min_window_size_bytes, do: 16
  defmacro packet_params,
    do: [
      :abs_recv_next,
      :last_recv_micro,
      :future_buffer,
      :future_buffer_bytes,
      :unread_bytes
    ]
  defmacro wrap_add(a, b), do: quote(do: unquote(a) + unquote(b) &&& 0xFFFF)
  defmacro wrap_sub_32(a, b), do: quote(do: unquote(a) - unquote(b) &&& 0xFFFFFFFF)
  defmacro mono_micro, do: quote(do: System.monotonic_time(:microsecond) &&& 0xFFFFFFFF)
  defmacro mono_ms, do: quote(do: System.monotonic_time(:millisecond) &&& 0xFFFFFFFF)
end
defmodule SimpleUTP.Math do
  import Bitwise
  @half_seq_space 32768
  @full_seq_space 65536
  @compile {:inline, [to_abs: 2, rand_utp_bytes: 0]}
  def to_abs(wire_seq, last_abs) do
    last_wire = last_abs &&& 0xFFFF
    diff = wire_seq - last_wire &&& 0xFFFF
    case diff < @half_seq_space do
      true -> last_abs + diff
      false -> last_abs - (@full_seq_space - diff)
    end
  end
  def rand_utp_bytes() do
    <<int::16>> = :crypto.strong_rand_bytes(2)
    max(1, int)
  end
end
defmodule SimpleUTP.LEDBAT do
  import Bitwise
  import SimpleUTP.Protocol
  @compile {:inline,
            [
              init_or_update_base_delay: 3,
              update_cwnd_and_rto: 4,
              empty_sample?: 1,
              zeroed_rtt?: 1,
              rotate_history?: 1,
              clamp: 3,
              safe_current_delay: 2
            ]}
  @moduledoc """
  Congestion Control (BEP 29) with Robust Base Delay.
  """
  @max_pkt_size_acked 1_024 * 1_024
  @max_cwnd_size 1024 * 1024 * 128
  @max_cw_increase 6000
  @history_buckets 4
  @rto_alpha_denom 8
  @rto_beta_denom 4
  @rto_k_factor 4
  @spike_multiplier 4
  @rto_clock_ms 150
  @target_delay_micro 100_000
  @max_ledbat_micro 10_000_000
  defstruct [
    base_history: [],
    last_history_update: 0,
    current_min_candidate: :infinity,
    base_delay: :infinity,
    current_delay: 0,
    cwnd: ledbat_mtu(),
    ssthresh: init_ssthresh(),
    rtt: 0,
    rtt_var: 0,
    rto_ms: 1_000,
    recovery_point: 0
  ]
  def init_or_update_base_delay(%__MODULE__{} = st, delay, now_ms),
    do: do_update_base_delay(st, delay, now_ms)
  def update_cwnd_and_rto(st, bytes_acked, in_flight, rtt_sample),
    do: do_update_cwnd_and_rto(st, bytes_acked, in_flight, rtt_sample)
  defp empty_sample?(rtt_sample), do: is_nil(rtt_sample)
  defp zeroed_rtt?(rtt), do: rtt == 0
  defp rotate_history?(elapsed), do: elapsed >= protocol_to_ms()
  defp clamp(val, min_val, max_val), do: max(min_val, min(val, max_val))
  defp safe_current_delay(_delay, :infinity), do: 0
  defp safe_current_delay(delay, base), do: max(0, delay - base)
  def do_update_cwnd_and_rto(st, bytes_acked, in_flight, rtt_sample) do
    updated_st = do_update_cwnd(st, bytes_acked, in_flight)
    case empty_sample?(rtt_sample) do
      true -> updated_st
      false -> do_update_rto_rfc_6298(updated_st, rtt_sample)
    end
  end
  defp do_update_cwnd(%{cwnd: cwnd, ssthresh: ssthresh} = st, bytes_acked, flight_size) do
    cwnd_bytes = cwnd >>> gain_shift()
    off_target = @target_delay_micro - st.current_delay
    slow_start? = cwnd < ssthresh
    congested? = off_target < 0
    window_utilized? = flight_size >= div(cwnd_bytes, 2)
    cond do
      slow_start? and not congested? ->
        increment = min(bytes_acked, effective_mtu()) <<< gain_shift()
        new_cwnd = min(cwnd + increment, @max_cwnd_size <<< gain_shift())
        %{st | cwnd: new_cwnd}
      congested? ->
        st
        |> maybe_exit_slow_start(slow_start?)
        |> apply_ledbat(bytes_acked, flight_size, off_target)
      window_utilized? ->
        apply_ledbat(st, bytes_acked, flight_size, off_target)
      true ->
        st
    end
  end
  defp apply_ledbat(%{cwnd: cwnd} = st, bytes_acked, flight_size, off_target) do
    cwnd_bytes = cwnd >>> gain_shift()
    acked = min(bytes_acked, min(max(flight_size, 1), @max_pkt_size_acked))
    clamped = clamp(off_target, -@target_delay_micro, @target_delay_micro)
    numerator = clamped * acked * @max_cw_increase
    denominator = @target_delay_micro * max(cwnd_bytes, 1)
    increment_unshifted = div(numerator, denominator)
    increment = increment_unshifted <<< gain_shift()
    new_cwnd = max(shifted_mtu(), cwnd + increment)
    %{st | cwnd: new_cwnd}
  end
  defp do_update_rto_rfc_6298(%{rtt: rtt, rtt_var: rtt_var} = st, rtt_sample_micro) do
    rtt_ms = div(rtt_sample_micro, 1_000)
    {new_rtt, new_var} =
      case zeroed_rtt?(rtt) do
        true ->
          {rtt_ms, div(rtt_ms, 2)}
        false ->
          delta = rtt - rtt_ms
          next_rtt = rtt - div(delta, @rto_alpha_denom)
          next_var = rtt_var + div(abs(delta) - rtt_var, @rto_beta_denom)
          {next_rtt, next_var}
      end
    new_rto = max(@rto_clock_ms, new_rtt + new_var * @rto_k_factor)
    %{st | rtt: new_rtt, rtt_var: new_var, rto_ms: new_rto}
  end
  defp do_update_base_delay(st, delay, _now_ms)
       when delay < 0 or delay > @max_ledbat_micro do
    st
  end
  defp do_update_base_delay(%{base_delay: :infinity} = st, delay, now_ms) do
    %{
      st
      | base_delay: delay,
        current_min_candidate: delay,
        base_history: [delay],
        last_history_update: now_ms,
        current_delay: 0
    }
  end
  defp do_update_base_delay(%{base_delay: base} = st, delay, now_ms)
       when is_integer(base) do
    spike? = delay > base * @spike_multiplier
    case spike? do
      true -> st
      false -> update_logic(st, delay, now_ms)
    end
  end
  defp update_logic(st, delay, now_ms) do
    current_candidate = min(st.current_min_candidate, delay)
    base_delay = min(st.base_delay, delay)
    elapsed = wrap_sub_32(now_ms, st.last_history_update)
    case rotate_history?(elapsed) do
      false ->
        %{
          st
          | current_min_candidate: current_candidate,
            base_delay: base_delay,
            current_delay: safe_current_delay(delay, base_delay)
        }
      true ->
        new_hist =
          [current_candidate | st.base_history]
          |> Enum.take(@history_buckets)
        new_base_delay = Enum.min(new_hist)
        %{
          st
          | base_history: new_hist,
            base_delay: new_base_delay,
            last_history_update: now_ms,
            current_min_candidate: :infinity,
            current_delay: safe_current_delay(delay, new_base_delay)
        }
    end
  end
  defp maybe_exit_slow_start(st, true = _was_slow_start) do
    %{st | ssthresh: max(st.cwnd, shifted_mtu())}
  end
  defp maybe_exit_slow_start(st, false), do: st
end
defmodule SimpleUTP.Packet do
  import Bitwise
  import SimpleUTP.Protocol
  alias SimpleUTP.{Math}
  defmodule UTPPacketParams do
    import SimpleUTP.Protocol
    @enforce_keys packet_params()
    defstruct @enforce_keys
  end
  @compile {:inline, [construct: 9, extract_conn_id: 1, encode_mask: 1, safe_reply_delay: 2]}
  @ext_sack 1
  def make(%UTPPacketParams{} = p, type, abs_seq, conn_id, payload, now_micro) do
    last_recv_abs = max(0, p.abs_recv_next - 1)
    wire_seq = abs_seq &&& 0xFFFF
    wire_ack = last_recv_abs &&& 0xFFFF
    reply_delay = safe_reply_delay(now_micro, p.last_recv_micro)
    {ext_type, ext_payload} = generate_payload(last_recv_abs, p.future_buffer)
    used_buffer = p.unread_bytes + p.future_buffer_bytes
    av_wnd = max(0, max_delivery_queue_size() - used_buffer)
    header =
      <<type::4, 1::4, ext_type::8, conn_id::16, now_micro::32, reply_delay::32, av_wnd::32,
        wire_seq::16, wire_ack::16>>
    case ext_type do
      0 ->
        [header, payload]
      _non_zero_ext_type ->
        len = :erlang.iolist_size(ext_payload)
        [header, <<0::8, len::8>>, ext_payload, payload]
    end
  end
  def probe_syn(conn_id),
    do: construct(4, 1, 0, conn_id, mono_micro(), 0, 65535, Math.rand_utp_bytes(), 0)
  def reset(conn_id), do: construct(3, 1, 0, conn_id, 0, 0, 0, 0, 0)
  def extract_conn_id(
        <<_type::4, _ver::4, _ext::8, conn_id::16, _ts::32, _ts_diff::32, _wnd::32, _seq_nr::16,
          _ack_nr::16, _rest::binary>>
      ),
      do: conn_id
  defp generate_payload(_abs_ack, fut_buf) when map_size(fut_buf) == 0, do: {0, <<>>}
  defp generate_payload(abs_ack, fut_buf) do
    bitmask =
      Enum.reduce(fut_buf, 0, fn {abs_seq, _payload}, acc ->
        dist = abs_seq - abs_ack - 2
        good_dist? = dist >= 0 and dist < max_sack_bits()
        case good_dist? do
          false -> acc
          true -> acc ||| 1 <<< dist
        end
      end)
    case bitmask != 0 do
      false -> {0, <<>>}
      true -> {@ext_sack, encode_mask(bitmask)}
    end
  end
  defp encode_mask(bitmask) do
    bin = :binary.encode_unsigned(bitmask, :little)
    len = byte_size(bin)
    padded_len = max(4, bsl(bsr(len + 3, 2), 2))
    case padded_len != len do
      false -> bin
      true -> <<bin::binary, 0::size((padded_len - len) * 8)>>
    end
  end
  defp construct(type, ver, ext, conn_id, ts, ts_diff, wnd, seq_nr, ack_nr) do
    <<type::4, ver::4, ext::8, conn_id::16, ts::32, ts_diff::32, wnd::32, seq_nr::16, ack_nr::16>>
  end
  defp safe_reply_delay(_now, last_recv_micro) when last_recv_micro == 0, do: 0
  defp safe_reply_delay(now, last_recv_micro), do: wrap_sub_32(now, last_recv_micro)
end
defmodule SimpleUTP.SACK do
  import Bitwise
  import SimpleUTP.Protocol
  def maybe_apply([], tree, tree_bytes, _abs_ack), do: {tree, tree_bytes, 0}
  def maybe_apply(exts, tree, tree_bytes, abs_ack) do
    Enum.reduce(exts, {tree, tree_bytes, 0}, fn
      {:sack, mask}, {acc_tree, acc_tb, acc_removed} ->
        safe_mask = binary_part(mask, 0, min(byte_size(mask), max_sack_bytes()))
        {new_tree, new_tb, removed} = apply_mask(acc_tree, acc_tb, abs_ack, safe_mask)
        {new_tree, new_tb, acc_removed + removed}
      _other, acc ->
        acc
    end)
  end
  defp apply_mask(tree, tree_bytes, nr, mask),
    do: process_bytes(mask, 0, nr, tree, tree_bytes, 0)
  defp process_bytes(<<byte::8, rest::binary>>, by_idx, nr, tree, tb, rem) do
    {new_tree, new_tb, new_rem} = process_bits(byte, 0, by_idx, nr, tree, tb, rem)
    process_bytes(rest, by_idx + 1, nr, new_tree, new_tb, new_rem)
  end
  defp process_bytes(<<>>, _by_idx, _nr, tree, tb, rem), do: {tree, tb, rem}
  defp process_bits(0, _bi_idx, _by_idx, _nr, tree, tb, rem), do: {tree, tb, rem}
  defp process_bits(byte, bi_idx, by_idx, nr, tree, tb, rem) when bi_idx < 8 do
    find_cond? = (byte &&& 1 <<< bi_idx) != 0
    case find_cond? do
      false ->
        process_bits(byte, bi_idx + 1, by_idx, nr, tree, tb, rem)
      true ->
        target_abs = nr + 2 + by_idx * 8 + bi_idx
        case :gb_trees.lookup(target_abs, tree) do
          {:value, {_type, data, _last_ms, _count}} ->
            new_tree = :gb_trees.delete(target_abs, tree)
            new_tb = tb - byte_size(data)
            new_rem = rem + byte_size(data)
            process_bits(byte, bi_idx + 1, by_idx, nr, new_tree, new_tb, new_rem)
          :none ->
            process_bits(byte, bi_idx + 1, by_idx, nr, tree, tb, rem)
        end
    end
  end
  defp process_bits(_byte, 8, _by_idx, _nr, tree, tb, rem), do: {tree, tb, rem}
end
defmodule SimpleUTP.Core do
  import Bitwise
  import SimpleUTP.Protocol
  require Logger
  alias SimpleUTP.{Math, Packet, SACK, LEDBAT}
  @compile {:inline,
            [
              extract_packet_params: 1,
              parse_header: 1,
              valid_conn_id?: 4,
              valid_handshake?: 4,
              inc_seq: 1,
              rand_conn_id: 0
            ]}
  @ext_sack 1
  @st_data 0
  @st_fin 1
  @st_st 2
  @st_reset 3
  @st_syn 4
  @min_pacing_micro 500
  @max_pacing_micro 100_000
  @probe_tick_micro 500_000
  @packet_timeout 60_000
  @max_probe_count 6
  defstruct [
    :send_conn_id,
    :recv_conn_id,
    :peer_fin_seq,
    :send_buffer,
    abs_seq_nr: 0,
    abs_recv_next: 0,
    last_acked_abs: 0,
    state: :closed,
    delivery_queue: [],
    delivery_queue_bytes: 0,
    future_buffer: %{},
    future_buffer_bytes: 0,
    unread_bytes: 0,
    send_buffer_bytes: 0,
    out_buffer: [],
    ledbat: %LEDBAT{},
    flight_size: 0,
    peer_wnd: 65535,
    ack_at: nil,
    ack_count: 0,
    dup_ack_count: 0,
    fast_recovery: false,
    recovery_point: 0,
    last_recv_micro: 0,
    probe_count: 0,
    probe_to_micro: nil
  ]
  defp empty_send_buffer(), do: :gb_trees.empty()
  defguardp closed?(c_s) when c_s in [:fin_sent, :closing, :last_ack, :closed]
  def rand_conn_id(), do: Math.rand_utp_bytes()
  def get_conn_id(syn_packet), do: Packet.extract_conn_id(syn_packet)
  @doc "Initialize a state for an outgoing connection and return the SYN packet."
  def connect(conn_id) do
    now_micro = mono_micro()
    recv_on_x = conn_id
    send_on_x_plus = wrap_add(conn_id, 1)
    init_seq = Math.rand_utp_bytes()
    st = %__MODULE__{
      state: :syn_sent,
      recv_conn_id: recv_on_x,
      send_conn_id: send_on_x_plus,
      abs_seq_nr: init_seq,
      last_acked_abs: init_seq - 1,
      send_buffer: empty_send_buffer()
    }
    syn_pkt = make_pkt(st, @st_syn, init_seq, recv_on_x, <<>>, now_micro)
    new_st =
      st
      |> buffer_outgoing(@st_syn, init_seq, <<>>, 0, now_micro)
      |> inc_seq()
    {[{:send_pkt, syn_pkt}], new_st}
  end
  def receive(%__MODULE__{} = st, packet_bin) do
    case parse_header(packet_bin) do
      {:ok, h, rest} -> process_received_packet(st, h, rest)
      :error -> log_error(st)
    end
  end
  def accept(syn_packet) do
    case parse_header(syn_packet) do
      {:ok, %{type: @st_syn, conn_id: h_conn_id, seq: h_seq} = _header, _rest} ->
        send_on_x = h_conn_id
        recv_on_x_plus = wrap_add(send_on_x, 1)
        abs_seq = Math.rand_utp_bytes()
        abs_h_seq = Math.to_abs(h_seq, 0)
        st = %__MODULE__{
          state: :connected,
          send_conn_id: send_on_x,
          recv_conn_id: recv_on_x_plus,
          abs_seq_nr: abs_seq,
          abs_recv_next: abs_h_seq + 1,
          last_acked_abs: 0,
          send_buffer: empty_send_buffer()
        }
        syn_ack_pkt = make_pkt(st, @st_st, abs_seq, send_on_x, <<>>, mono_micro())
        {[{:send_pkt, syn_ack_pkt}], st}
      {:ok, %{type: h_t} = _h, _r} when h_t in [@st_data, @st_fin, @st_st, @st_reset] ->
        log_error(nil)
      :error ->
        log_error(nil)
    end
  end
  def read_data(%__MODULE__{delivery_queue_bytes: bytes} = st, len) when bytes >= len do
    ordered_buffer = Enum.reverse(st.delivery_queue)
    {data, remaining, new_bytes} = take_bytes(ordered_buffer, len, [], st.delivery_queue_bytes)
    {:ok, data, %{st | delivery_queue: Enum.reverse(remaining), delivery_queue_bytes: new_bytes}}
  end
  def read_data(_st, _len), do: {:error, :empty}
  def send_data(%__MODULE__{state: :fin_sent} = st, _d), do: {:error, :closing, st}
  def send_data(%__MODULE__{state: :close_wait} = st, _d), do: {:error, :peer_closing, st}
  def send_data(%__MODULE__{state: :closed} = st, _d), do: {:error, :closed, st}
  def send_data(%__MODULE__{state: :syn_sent} = st, data) do
    new_out_buf = [st.out_buffer, data]
    {:ok, [], %{st | out_buffer: new_out_buf}}
  end
  def send_data(
        %__MODULE__{state: :connected, out_buffer: out_buf, send_buffer_bytes: send_buf_size} = st,
        data
      ) do
    total_send =
      send_buf_size +
        :erlang.iolist_size(out_buf) +
        :erlang.iolist_size(data)
    busy? = total_send >= max_send_buffer_bytes()
    case busy? do
      true ->
        {:error, :busy, st}
      false ->
        new_out_buf = [out_buf, data]
        {actions, next_st, rem} = pop_outbound(st, new_out_buf, [], burst_pkt_cnt())
        next_st = %{next_st | out_buffer: rem}
        pacing_acts = get_pacing_acts(next_st)
        {:ok, actions ++ pacing_acts, next_st}
    end
  end
  def set_unread_bytes(%__MODULE__{} = st, bytes), do: %{st | unread_bytes: bytes}
  def get_pacing_interval(%__MODULE__{} = st) do
    mtu = effective_mtu()
    cwnd_bytes = st.ledbat.cwnd >>> gain_shift()
    rtt_micro = st.ledbat.rtt * 1_000
    actual_cwnd = max(cwnd_bytes, mtu)
    interval_micro = div(rtt_micro * mtu, actual_cwnd)
    too_fast? = interval_micro < @min_pacing_micro
    case too_fast? do
      true -> 0
      false -> min(interval_micro, @max_pacing_micro)
    end
  end
  def get_pacing_acts(%__MODULE__{} = st) do
    interval_micro = get_pacing_interval(st)
    has_data? = :erlang.iolist_size(st.out_buffer) > 0
    cwnd_bytes = st.ledbat.cwnd >>> gain_shift()
    available_window = max(min(cwnd_bytes, st.peer_wnd) - st.flight_size, 0)
    has_window? = available_window >= min_window_size_bytes()
    pacing_scenario =
      cond do
        not has_data? or not has_window? -> :stop_pacing
        interval_micro < 1_000 -> :fast_network
        true -> :pace
      end
    case pacing_scenario do
      s when s in [:stop_pacing, :fast_network] -> [:stop_pacer]
      :pace -> [{:start_pacer, max(1, div(interval_micro, 1_000))}]
    end
  end
  def pop_paced_pkt(%__MODULE__{} = st) do
    case pop_single_packet(st, st.out_buffer) do
      {:ok, pkt, new_st, rem} -> {:ok, [{:send_pkt, pkt}], %{new_st | out_buffer: rem}}
      :empty -> {:empty, st}
    end
  end
  def pop_single_packet(st, bin_data) do
    case pop_outbound(st, bin_data, [], 1) do
      {[{:send_pkt, pkt}], new_st, rest} -> {:ok, pkt, new_st, rest}
      {[], _st, []} -> :empty
    end
  end
  def tick(%__MODULE__{} = st) do
    now_micro = mono_micro()
    {retransmit_acts, st} = process_timeouts(st, now_micro)
    {probe_acts, st} = maybe_send_probe(st, now_micro)
    ack_pkt = make_st_pkt(st, now_micro)
    ack_acts = [{:send_pkt, ack_pkt}]
    {:ok, retransmit_acts ++ probe_acts ++ ack_acts, st}
  end
  def close(%__MODULE__{state: :connected} = st), do: do_send_fin(st, :fin_sent)
  def close(%__MODULE__{state: :close_wait} = st), do: do_send_fin(st, :last_ack)
  def close(%__MODULE__{state: state} = st) when closed?(state), do: {:ok, [], st}
  defp empty_buffer?(gb_tree), do: :gb_trees.is_empty(gb_tree)
  defp make_pkt(st, type, seq, conn_id, payload, now_micro) do
    Packet.make(
      extract_packet_params(st),
      type,
      seq,
      conn_id,
      payload,
      now_micro
    )
  end
  defp make_st_pkt(%{abs_seq_nr: seq, send_conn_id: conn_id} = st, now_micro),
    do: make_pkt(st, @st_st, seq, conn_id, <<>>, now_micro)
  defp process_received_packet(
         %{
           abs_seq_nr: abs_seq,
           state: core_st,
           abs_recv_next: recv_next,
           recv_conn_id: recv_id,
           send_conn_id: send_id,
           last_acked_abs: last_ack
         } = st,
         %{seq: h_seq, ack_nr: h_ack, type: h_t, conn_id: h_id} = h,
         rest
       ) do
    ack_ref =
      case core_st == :syn_sent do
        true -> abs_seq
        false -> max(last_ack, abs_seq - 1)
      end
    abs_h_ack = Math.to_abs(h_ack, ack_ref)
    cond do
      not valid_conn_id?(recv_id, send_id, h_id, h_t) ->
        log_invalid_id(st, recv_id, send_id, h_id, h_t)
      not valid_handshake?(core_st, abs_seq, abs_h_ack, h_t) ->
        log_invalid_hs(st, core_st, abs_h_ack, abs_seq)
      true ->
        seq_ref =
          case recv_next do
            0 -> h_seq &&& 0xFFFF
            n -> max(n - 1, 0)
          end
        abs_h_seq = Math.to_abs(h_seq, seq_ref)
        new_h = Map.merge(h, %{ack_nr: abs_h_ack, seq: abs_h_seq})
        handle_handshake(st, new_h, mono_micro(), mono_ms(), rest)
    end
  end
  defp handle_handshake(st, h, recv_m, recv_ms, rest) do
    case {st.state, h.type} do
      {:syn_sent, @st_fin} ->
        {[:close_socket], %{st | state: :closed}}
      {:syn_sent, @st_reset} ->
        {[:close_socket], %{st | state: :closed}}
      _all_other_st ->
        st = %{st | last_recv_micro: recv_m}
        process_content(st, h, rest, h.ts_diff, recv_m, recv_ms)
    end
  end
  defp process_content(st, h, payload, delay_micro, recv_m, recv_ms) do
    {exts, data} = parse_chain(h.ext, payload)
    size = byte_size(data)
    data? = size > 0
    new_ledbat = LEDBAT.init_or_update_base_delay(st.ledbat, delay_micro, recv_ms)
    st = %{st | ledbat: new_ledbat, peer_wnd: h.wnd}
    {retransmit_acts, st} = handle_ack_and_sack(st, h.ack_nr, exts, recv_m)
    {send_acts, st} = get_send_acts(st)
    pacing_acts = get_pacing_acts(st)
    main_acts = main_acts(retransmit_acts, send_acts, pacing_acts)
    case {st.state, h.type} do
      {:closed, h_type} when h_type in [@st_data, @st_fin, @st_syn] ->
        reset_pkt = Packet.reset(st.send_conn_id)
        {[{:send_pkt, reset_pkt}], st}
      {:closed, _other_type} ->
        {[], st}
      {:syn_sent, @st_st} ->
        {n_acts, ack_pkt, new_st} = get_syn_acts(st, h, data, size, recv_m, data?)
        merge_and_send(new_st, main_acts, ack_pkt, n_acts)
      {:syn_sent, @st_data} ->
        {n_acts, ack_pkt, new_st} = get_syn_acts(st, h, data, size, recv_m, data?)
        merge_and_send(new_st, main_acts, ack_pkt, n_acts)
      {curr_st, @st_data} when curr_st in [:connected, :close_wait] ->
        {next_st, pkt, delv_acts} = pr_data(st, h, data, size, recv_m, data?, true)
        merge_and_send(next_st, main_acts, pkt, delv_acts)
      {curr_st, @st_syn} when curr_st in [:connected, :close_wait] ->
        ack_pkt = make_st_pkt(st, recv_m)
        merge_and_send(st, main_acts, ack_pkt, [])
      {curr_st, @st_st} when curr_st in [:connected, :close_wait] and not data? ->
        {main_acts, st}
      {curr_st, @st_st} when curr_st in [:connected, :close_wait] ->
        {next_st, pkt, delv_acts} = pr_data(st, h, data, size, recv_m, data?, false)
        merge_and_send(next_st, main_acts, pkt, delv_acts)
      {:syn_sent, @st_fin} ->
        {[:close_socket], %{st | state: :closed}}
      {:fin_sent, @st_fin} ->
        pkt = make_st_pkt(st, recv_m)
        {retransmit_acts ++ send_acts ++ [{:send_pkt, pkt}], %{st | state: :closing}}
      {curr_st, @st_st} when curr_st in [:last_ack, :closing] ->
        fin_acts(st, retransmit_acts)
      {curr_st, @st_fin} when curr_st in [:connected, :close_wait] ->
        st = %{st | state: :close_wait, peer_fin_seq: h.seq}
        pkt = make_st_pkt(st, recv_m)
        {retransmit_acts ++ send_acts ++ [{:send_pkt, pkt}, :peer_closed], st}
      {_any_state, @st_reset} ->
        {[:close_socket], %{st | state: :closed}}
      {_any_state, h_type} when h_type in [@st_st, @st_syn] ->
        {main_acts, st}
      other ->
        log_other(other)
        {main_acts, st}
    end
  end
  defp get_send_acts(%{state: :syn_sent} = st), do: {[], st}
  defp get_send_acts(%{out_buffer: out_buf} = st) do
    {acts, next_st, rem} = pop_outbound(st, out_buf, [], burst_pkt_cnt())
    {acts, %{next_st | out_buffer: rem}}
  end
  defp main_acts(r_acts, s_acts, p_acts), do: r_acts ++ s_acts ++ p_acts
  defp merge_and_send(st, m_a, pkt, new_a), do: {new_a ++ [{:send_pkt, pkt}] ++ m_a, st}
  defp get_syn_acts(
         %{send_buffer: s_buf} = st,
         %{seq: h_seq, ack_nr: h_ack} = _h,
         data,
         size,
         recv_micro,
         has_data?
       ) do
    {new_tree, _rem_bytes, _rtt} = prune_buffer(s_buf, h_ack, 0, nil)
    connected_st = %{
      st
      | state: :connected,
        send_buffer: new_tree,
        abs_recv_next: h_seq,
        last_acked_abs: h_ack
    }
    connected_st =
      case has_data? do
        false -> connected_st
        true -> handle_incoming_data(connected_st, h_seq, data, size, has_data?)
      end
    {connected_st, deliver_acts} =
      case connected_st.delivery_queue != [] do
        false -> {connected_st, []}
        true -> flush_deliveries(connected_st)
      end
    ack_pkt = make_st_pkt(connected_st, recv_micro)
    {flush_acts, flushed_st, _buf} =
      pop_outbound(connected_st, connected_st.out_buffer, [], burst_pkt_cnt())
    flushed_st = %{flushed_st | out_buffer: []}
    {deliver_acts ++ flush_acts, ack_pkt, flushed_st}
  end
  defp fin_acts(%{send_buffer: s_buf} = st, retransmit_acts) do
    fin_acked? = :gb_trees.is_empty(s_buf)
    case fin_acked? do
      true -> {retransmit_acts ++ [:close_socket], %{st | state: :closed}}
      false -> {retransmit_acts, st}
    end
  end
  defp pr_data(st, h, data, size, recv_micro, has_data?, reset_ack_cnt?) do
    st = handle_incoming_data(st, h.seq, data, size, has_data?)
    ack_pkt = make_st_pkt(st, recv_micro)
    st =
      case reset_ack_cnt? do
        false -> st
        true -> %{st | ack_count: 0, ack_at: nil}
      end
    {processed_st, delv_acts} = flush_deliveries(st)
    {processed_st, ack_pkt, delv_acts}
  end
  defp do_send_fin(%{abs_seq_nr: seq, send_conn_id: conn_id} = st, next_core_st) do
    now_micro = mono_micro()
    fin_pkt = make_pkt(st, @st_fin, seq, conn_id, <<>>, now_micro)
    new_st =
      st
      |> buffer_outgoing(@st_fin, seq, <<>>, 0, now_micro)
      |> inc_seq()
      |> Map.put(:state, next_core_st)
    {:ok, [{:send_pkt, fin_pkt}], new_st}
  end
  defp parse_chain(type, data), do: do_parse_chain(type, data, [])
  defp do_parse_chain(0, data, acc), do: {Enum.reverse(acc), data}
  defp do_parse_chain(type, <<next_type::8, len::8, rest::binary>>, acc) do
    good_len? = byte_size(rest) >= len
    case good_len? do
      false ->
        {Enum.reverse(acc), rest}
      true ->
        <<ext_data::binary-size(len), remaining_payload::binary>> = rest
        current =
          case type do
            @ext_sack -> {:sack, ext_data}
            _other -> {:unknown, type}
          end
        do_parse_chain(next_type, remaining_payload, [current | acc])
    end
  end
  defp do_parse_chain(_type, data, acc), do: {Enum.reverse(acc), data}
  defp take_bytes([bin | rest], len, acc, total) when byte_size(bin) <= len do
    take_bytes(rest, len - byte_size(bin), [bin | acc], total - byte_size(bin))
  end
  defp take_bytes([bin | rest], len, acc, total) do
    <<part::binary-size(len), remaining::binary>> = bin
    data = :erlang.iolist_to_binary(Enum.reverse([part | acc]))
    {data, [remaining | rest], total - len}
  end
  defp take_bytes([], _len, acc, total),
    do: {:erlang.iolist_to_binary(Enum.reverse(acc)), [], total}
  defp valid_conn_id?(_recv_id, _send_id, _conn_id, @st_reset), do: true
  defp valid_conn_id?(r, s, conn_id, _other_st), do: conn_id == r or conn_id == s
  defp valid_handshake?(:syn_sent, _seq, _ack, @st_reset), do: true
  defp valid_handshake?(:syn_sent, _seq, _ack, @st_fin), do: true
  defp valid_handshake?(:syn_sent, seq, ack, @st_st), do: ack == seq or ack == seq - 1
  defp valid_handshake?(_other_st, _seq, _ack, _type), do: true
  defp maybe_send_probe(
         %__MODULE__{peer_wnd: 0, flight_size: 0, probe_to_micro: nil} = st,
         now_micro
       ) do
    send_probe(st, now_micro)
  end
  defp maybe_send_probe(
         %__MODULE__{peer_wnd: 0, flight_size: 0, probe_to_micro: to_micro} = st,
         now_micro
       ) do
    probe_timed_out? = now_micro >= to_micro
    if probe_timed_out?, do: send_probe(st, now_micro), else: {[], st}
  end
  defp maybe_send_probe(st, _now), do: {[], %{st | probe_to_micro: nil, probe_count: 0}}
  defp flush_deliveries(%{delivery_queue: []} = st), do: {st, []}
  defp flush_deliveries(st) do
    {%{st | delivery_queue: [], delivery_queue_bytes: 0},
     [{:deliver, Enum.reverse(st.delivery_queue)}]}
  end
  defp send_probe(st, now_micro) do
    shift = min(st.probe_count, @max_probe_count)
    backoff_micro = min(protocol_to_micro(), @probe_tick_micro <<< shift)
    new_probe_count = min(st.probe_count + 1, @max_probe_count)
    ack_pkt = make_st_pkt(st, now_micro)
    new_st =
      %{st | probe_to_micro: now_micro + backoff_micro, probe_count: new_probe_count}
    {[{:send_pkt, ack_pkt}], new_st}
  end
  defp process_timeouts(%{send_buffer: s_buf} = st, now_micro) do
    case empty_buffer?(s_buf) do
      true -> {[], st}
      false -> do_retransmit_loop(st, now_micro, [], false)
    end
  end
  defp do_retransmit_loop(%{send_conn_id: conn_id} = st, now_micro, acc, cwnd_slashed?) do
    case maybe_get_expired_packet(st, now_micro) do
      :none_expired ->
        {Enum.reverse(acc), st}
      {:expired, seq, type, data, resend_count} ->
        updated_entry = {type, data, now_micro, resend_count + 1}
        new_tree = :gb_trees.update(seq, updated_entry, st.send_buffer)
        next_st =
          case cwnd_slashed? do
            false -> apply_timeout_penalty(st, new_tree)
            true -> %{st | send_buffer: new_tree}
          end
        pkt = make_pkt(st, type, seq, conn_id, data, now_micro)
        new_acc = [{:send_pkt, pkt} | acc]
        do_retransmit_loop(next_st, now_micro, new_acc, true)
    end
  end
  defp maybe_get_expired_packet(%{send_buffer: s_buf} = st, now_micro) do
    case empty_buffer?(s_buf) do
      true ->
        :none_expired
      false ->
        {seq, {type, data, sent_micro, count}} = :gb_trees.smallest(s_buf)
        timeout_micro = get_packet_timeout(st.ledbat.rto_ms, count) * 1_000
        expired? = now_micro > sent_micro + timeout_micro
        case expired? do
          true -> {:expired, seq, type, data, count}
          false -> :none_expired
        end
    end
  end
  defp apply_timeout_penalty(st, new_tree) do
    new_cwnd = shifted_mtu()
    min_thresh = shifted_mtu() * 2
    new_ssthresh = max(min_thresh, div(st.ledbat.cwnd, 2))
    %{
      st
      | send_buffer: new_tree,
        ledbat: %{st.ledbat | cwnd: new_cwnd, ssthresh: new_ssthresh},
        fast_recovery: false
    }
  end
  defp prune_buffer(tree, abs_ack, rem_bytes, rtt) do
    now = mono_micro()
    loop_karn_algo(tree, abs_ack, rem_bytes, rtt, now)
  end
  defp loop_karn_algo(tree, abs_ack, rem_bytes, rtt, now) do
    case empty_buffer?(tree) do
      true ->
        {tree, rem_bytes, rtt}
      false ->
        {seq, {_type, data, sent_micro, count}, r_tree} = :gb_trees.take_smallest(tree)
        case pkt_acked?(seq, abs_ack) do
          false ->
            {tree, rem_bytes, rtt}
          true ->
            new_rtt = karn_rtt_recalc(rtt, now, count, sent_micro)
            loop_karn_algo(r_tree, abs_ack, rem_bytes + byte_size(data), new_rtt, now)
        end
    end
  end
  defp pkt_acked?(seq, abs_ack), do: seq <= abs_ack
  defp retransmitted_pkt?(count), do: count > 0
  defp karn_rtt_recalc(rtt, now, count, sent_micro) do
    case retransmitted_pkt?(count) do
      true ->
        rtt
      false ->
        rtt_sample = wrap_sub_32(now, sent_micro)
        case invalid_rtt_sample?(rtt_sample) do
          true -> rtt
          false -> rtt_sample
        end
    end
  end
  defp invalid_rtt_sample?(rtt_sample) do
    rtt_sample <= 0 or
      rtt_sample > 0x7FFFFFFF or
      rtt_sample > protocol_to_micro()
  end
  defp get_packet_timeout(rto_ms, resend_count) do
    backoff = 1 <<< min(resend_count, 6)
    min(rto_ms * backoff, @packet_timeout)
  end
  defp pop_outbound(st, list_data, acc_acts, limit) when is_list(list_data) do
    pop_outbound(st, IO.iodata_to_binary(list_data), acc_acts, limit)
  end
  defp pop_outbound(st, <<>>, acc_act, _lim), do: {Enum.reverse(acc_act), st, []}
  defp pop_outbound(st, bin_data, acc_act, limit) when limit <= 0,
    do: {Enum.reverse(acc_act), st, bin_data}
  defp pop_outbound(
         %{flight_size: in_flight, abs_seq_nr: seq, send_conn_id: conn_id, peer_wnd: peer_wnd} =
           st,
         bin_data,
         acc_acts,
         limit
       ) do
    size = byte_size(bin_data)
    mtu = effective_mtu()
    cwnd_bytes = st.ledbat.cwnd >>> gain_shift()
    available = max(min(cwnd_bytes, peer_wnd) - in_flight, 0)
    chunk_len = min(size, min(available, mtu))
    pipe_scenario =
      case {chunk_len, size, in_flight} do
        {0, s, 0} when s > 0 -> :pipe_empty
        {0, _s, _in} -> :no_data
        {cl, _s, _in} when cl >= mtu -> :full_pipe
        {cl, s, _in} when cl == s -> :buffer_cleared
        {_cl, _s, 0} -> :pipe_empty
        _other -> :data_to_send
      end
    case pipe_scenario do
      s when s in [:no_data] ->
        {Enum.reverse(acc_acts), st, bin_data}
      s when s in [:full_pipe, :buffer_cleared, :pipe_empty, :data_to_send] ->
        now_micro = mono_micro()
        actual_len = min(chunk_len, size)
        <<chunk::binary-size(actual_len), rest::binary>> = bin_data
        pkt = make_pkt(st, @st_data, seq, conn_id, chunk, now_micro)
        new_st =
          st
          |> Map.update!(:flight_size, &(&1 + actual_len))
          |> buffer_outgoing(@st_data, seq, chunk, actual_len, now_micro)
          |> inc_seq()
        new_acc = [{:send_pkt, pkt} | acc_acts]
        pop_outbound(new_st, rest, new_acc, limit - 1)
    end
  end
  defp handle_ack_and_sack(
         %{
           flight_size: in_flight,
           last_acked_abs: prev_ack,
           ledbat: ledbat,
           send_buffer: send_buf,
           send_buffer_bytes: send_buf_b
         } = st,
         abs_ack,
         exts,
         recv_micro
       ) do
    {pruned_tree, pruned_bytes, rtt_sample} = prune_buffer(send_buf, abs_ack, 0, nil)
    tree_bytes = send_buf_b - pruned_bytes
    {s_tree, s_buffer, s_rem} = SACK.maybe_apply(exts, pruned_tree, tree_bytes, abs_ack)
    total_removed = pruned_bytes + s_rem
    new_ledbat = LEDBAT.update_cwnd_and_rto(ledbat, total_removed, in_flight, rtt_sample)
    st = %{
      st
      | send_buffer: s_tree,
        send_buffer_bytes: max(0, s_buffer),
        flight_size: max(0, in_flight - total_removed),
        last_acked_abs: abs_ack,
        ledbat: new_ledbat
    }
    maybe_fast_rt_reno(st, prev_ack, pruned_bytes, recv_micro)
  end
  defp maybe_fast_rt_reno(%{last_acked_abs: last_abs} = st, prev_ack, pruned_bytes, recv_micro) do
    ack_scenario =
      cond do
        last_abs > prev_ack -> :new_ack
        last_abs == prev_ack and pruned_bytes == 0 -> :dup_ack
        true -> :same_ack_with_progress
      end
    case ack_scenario do
      :new_ack -> {[], new_fast_rec_st(st)}
      :dup_ack -> handle_dup_ack(st, recv_micro)
      :same_ack_with_progress -> {[], %{st | dup_ack_count: 0}}
    end
  end
  defp new_fast_rec_st(%{fast_recovery: fr, last_acked_abs: last, recovery_point: rp} = st) do
    case fr and last > rp do
      false -> %{st | dup_ack_count: 0}
      true -> %{st | fast_recovery: false, dup_ack_count: 0}
    end
  end
  defp handle_dup_ack(%{dup_ack_count: dup_cnt, fast_recovery: fr} = st, recv_micro) do
    new_dup = dup_cnt + 1
    st = %{st | dup_ack_count: new_dup}
    case new_dup >= 3 and not fr do
      false -> {[], st}
      true -> trigger_fast_retransmit(st, recv_micro)
    end
  end
  defp trigger_fast_retransmit(
         %{send_buffer: send_buffer, send_conn_id: conn_id} = st,
         recv_micro
       ) do
    case empty_buffer?(send_buffer) do
      true ->
        {[], st}
      false ->
        {seq, {type, data, _last_micro, _count}} = :gb_trees.smallest(st.send_buffer)
        new_cwnd = max(div(st.ledbat.cwnd, 2), shifted_mtu())
        st = %{
          st
          | fast_recovery: true,
            recovery_point: max(st.last_acked_abs, st.abs_seq_nr - 1),
            ledbat: %{st.ledbat | cwnd: new_cwnd}
        }
        pkt = make_pkt(st, type, seq, conn_id, data, recv_micro)
        {[{:send_pkt, pkt}], st}
    end
  end
  defp handle_incoming_data(
         %{
           future_buffer: fbuf,
           future_buffer_bytes: fbuf_size,
           peer_fin_seq: fin_seq,
           abs_recv_next: recv_next,
           delivery_queue: delv_q,
           delivery_queue_bytes: delv_q_size
         } = st,
         abs_seq,
         payload,
         size,
         has_data?
       ) do
    diff = abs_seq - recv_next
    new_data_scenario =
      cond do
        diff == 0 -> :in_order
        diff < 0 -> :old_packet
        diff > max_sack_bits() -> :too_far_ahead
        map_size(fbuf) >= max_buffer_map_size() -> :too_many_holes
        Map.has_key?(fbuf, abs_seq) -> :duplicate
        fin_seq != nil and abs_seq >= fin_seq -> :after_fin
        fbuf_size + size > max_delivery_queue_size() -> :buffer_full
        true -> :out_of_order
      end
    if MathSync.rolled?(1, 3000) and
         new_data_scenario not in [:in_order, :old_packet, :out_of_order],
       do: Logger.warning("[SimpleUTP] DATA scenario: #{new_data_scenario}")
    case new_data_scenario do
      :in_order ->
        queue_st =
          case has_data? do
            false ->
              st
            true ->
              %{
                st
                | delivery_queue: [payload | delv_q],
                  delivery_queue_bytes: delv_q_size + size
              }
          end
        new_st = %{queue_st | abs_recv_next: abs_seq + 1}
        check_future_buffer(new_st, size)
      :out_of_order ->
        %{
          st
          | future_buffer: Map.put(fbuf, abs_seq, payload),
            future_buffer_bytes: fbuf_size + size
        }
      s
      when s in [
             :old_packet,
             :too_far_ahead,
             :buffer_full,
             :too_many_holes,
             :duplicate,
             :after_fin
           ] ->
        st
    end
  end
  defp check_future_buffer(
         %{
           abs_recv_next: recv_next,
           future_buffer: fbuf,
           delivery_queue: delv_q,
           delivery_queue_bytes: delv_q_size
         } = st,
         size
       ) do
    case Map.pop(fbuf, recv_next) do
      {nil, _buffer} ->
        st
      {payload, new_fb} ->
        new_st = %{
          st
          | delivery_queue: [payload | delv_q],
            delivery_queue_bytes: delv_q_size + size,
            future_buffer_bytes: delv_q_size - size,
            abs_recv_next: recv_next + 1,
            future_buffer: new_fb
        }
        check_future_buffer(new_st, size)
    end
  end
  defp buffer_outgoing(
         %{send_buffer_bytes: send_size, send_buffer: send_buf} = st,
         type,
         abs_seq,
         data,
         size,
         now_micro
       ) do
    entry = {type, data, now_micro, 0}
    new_tree = :gb_trees.enter(abs_seq, entry, send_buf)
    %{
      st
      | send_buffer: new_tree,
        send_buffer_bytes: send_size + size
    }
  end
  defp inc_seq(%{abs_seq_nr: seq} = st), do: %{st | abs_seq_nr: seq + 1}
  defp parse_header(
         <<t::4, utp_version()::4, e::8, c::16, ts::32, td::32, w::32, s::16, a::16, r::binary>>
       ) do
    {:ok, %{type: t, ext: e, conn_id: c, ts: ts, ts_diff: td, wnd: w, seq: s, ack_nr: a}, r}
  end
  defp parse_header(_malfored_or_unsupported), do: :error
  defp log_error(st) do
    Logger.debug("[SimpleUTP] Header parse error")
    {[], st}
  end
  defp log_invalid_id(st, recv_id, send_id, h_id, h_t) do
    Logger.debug(
      "[SimpleUTP] ID mismatch: recv=#{recv_id} send=#{send_id} pkt=#{h_id} type=#{h_t}"
    )
    {[], st}
  end
  defp log_invalid_hs(st, core_st, abs_h_ack, abs_seq) do
    Logger.debug(
      "[SimpleUTP] Invalid Handshake: state=#{core_st} ack=#{abs_h_ack} exp=#{abs_seq - 1}"
    )
    {[], st}
  end
  defp log_other(other) do
    Logger.debug(fn ->
      "[SimpleUTP] unhandled state/type: #{inspect(other, limit: 50)}"
    end)
  end
  defp extract_packet_params(st) do
    %Packet.UTPPacketParams{
      abs_recv_next: st.abs_recv_next,
      last_recv_micro: st.last_recv_micro,
      future_buffer: st.future_buffer,
      future_buffer_bytes: st.future_buffer_bytes,
      unread_bytes: st.unread_bytes
    }
  end
end