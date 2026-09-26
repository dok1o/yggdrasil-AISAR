defmodule TorrHandshake do
  @moduledoc """
  BitTorrent + Extension Protocol handshake (BEP 3, BEP 10, BEP 9).
  """
  import Bitwise
  import MagnetSorter.Const
  import TimeSync
  require Logger
  @typedoc "20b SHA-1 base value: remote node_id, ih, other"
  @type ihv :: <<_::160>>
  @type nid :: ihv()
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @type peer :: nodev4()
  @protocol "BitTorrent protocol"
  @protocol_len 19
  @handshake_size 68
  @reserved_ext <<0, 0, 0, 0, 0, 0x10, 0, 0x01>>
  @ext_handshake_id 0
  @ut_metadata_id 2
  @msg_choke 0
  @msg_unchoke 1
  @msg_interested 2
  @msg_not_interested 3
  @msg_have 4
  @msg_bitfield 5
  @msg_extended 20
  @port udp_port()
  @m "m"
  @base_payload %{
    @m => %{
      "ut_metadata" => @ut_metadata_id,
      "ut_pex" => 1,
      "p" => @port
    }
  }
  @keepalive <<>>
  @only_utm_skip_list [
    @msg_choke,
    @msg_unchoke,
    @msg_have,
    @msg_bitfield,
    @msg_interested,
    @msg_not_interested
  ]
  @m_key "m"
  @ut_metadata_key "ut_metadata"
  @metadata_size_key "metadata_size"
  @max_ext_loops 16
  def perform(conn, ih, peer, nid, timeout, own_ip, use_mse?),
    do: do_perform(conn, ih, peer, nid, timeout, own_ip, use_mse?)
  defp do_perform(conn, ih, peer, nid, timeout, _own_ip, use_mse?) do
    deadline = mono_ms() + timeout
    <<_peer_ipv4::binary-4, _port::16>> = peer
    result =
      case use_mse? do
        true ->
          bth = build_bt_handshake(ih, nid)
          MSEHandshake.initiate(conn, ih, bth)
        false ->
          {:ok, SecureTransport.wrap(conn)}
      end
    case result do
      {:ok, st} ->
        run_handshake_flow(st, ih, peer, nid, deadline, @base_payload, use_mse?)
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp run_handshake_flow(st, ih, _peer, nid, deadline, payload, use_mse?) do
    with {:ok, st} <- maybe_send_plain_bth(st, ih, nid, use_mse?),
         {:ok, reserved, st} <- recv_bt_handshake(st, ih, deadline),
         :ok <- validate_extensions(reserved),
         {:ok, st} <- send_ext_handshake(st, payload),
         {:ok, peer_ext, st} <- recv_ext_handshake(st, deadline),
         {:ok, size, peer_id, own_id, st} <- extract_metadata_info(peer_ext, st),
         {:ok, st} <- send_interested(st) do
      {:ok, peer_id, own_id, size, st, peer_ext}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp build_bt_handshake(<<ih::binary-20>>, nid) do
    peer_id = make_peer_id(nid)
    <<@protocol_len, @protocol::binary, @reserved_ext::binary, ih::binary, peer_id::binary>>
  end
  defp make_peer_id(nid) when is_integer(nid) do
    <<hash::binary-12, _::binary>> = :crypto.hash(:sha, <<nid::32>>)
    :crypto.strong_rand_bytes(8) <> hash
  end
  defp make_peer_id(<<peer_id::binary-20>>), do: peer_id
  defp maybe_send_plain_bth(st, _ih, _nid, true = _mse_used), do: {:ok, st}
  defp maybe_send_plain_bth(st, ih, nid, false = _mse_used),
    do: SecureTransport.send(st, build_bt_handshake(ih, nid))
  defp recv_bt_handshake(st, expected_ih, deadline) do
    case SecureTransport.recv_exact(st, @handshake_size, deadline_in(deadline)) do
      {:ok, handshake, st} -> parse_bt_handshake(handshake, expected_ih, st)
      {:error, :timeout} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end
  defp parse_bt_handshake(
         <<@protocol_len, @protocol::binary, reserved::binary-8, ih::binary-20,
           _peer_id::binary-20>>,
         expected_ih,
         st
       ) do
    case ih do
      ^expected_ih -> {:ok, reserved, st}
      _ -> {:error, :info_hash_mismatch}
    end
  end
  defp parse_bt_handshake(<<@protocol_len, other::binary-19, _::binary>>, _, _)
       when other != @protocol do
    {:error, :unknown_protocol}
  end
  defp parse_bt_handshake(<<"HTTP", _::binary>>, _, _), do: {:error, :http_not_peer}
  defp parse_bt_handshake(<<"GET ", _::binary>>, _, _), do: {:error, :http_not_peer}
  defp parse_bt_handshake(<<"POST", _::binary>>, _, _), do: {:error, :http_not_peer}
  defp parse_bt_handshake(<<len, _::binary>>, _, _) when len != @protocol_len do
    {:error, :invalid_handshake}
  end
  defp parse_bt_handshake(_malf1, _malf2, _malf3), do: {:error, :invalid_handshake}
  defp validate_extensions(<<_::5-bytes, byte5, _::2-bytes>>) do
    ext_bit = band(byte5, 0x10)
    case ext_bit != 0 do
      true -> :ok
      false -> {:error, :extensions_not_supported}
    end
  end
  defp send_ext_handshake(st, payload) do
    bencode = SimpleBencodeSync.encode(payload)
    msg = <<byte_size(bencode) + 2::32, @msg_extended, @ext_handshake_id, bencode::binary>>
    SecureTransport.send(st, msg)
  end
  defp recv_ext_handshake(st, deadline),
    do: recv_ext_handshake_loop(st, deadline_in(deadline), 0)
  defp recv_ext_handshake_loop(_st, _timeout, loops) when loops >= @max_ext_loops do
    {:error, :too_many_messages}
  end
  defp recv_ext_handshake_loop(st, timeout, loops) do
    case SecureTransport.recv_stream(st, timeout) do
      {:ok, <<@msg_extended, @ext_handshake_id, bencode::binary>>, st} ->
        decode_ext_handshake(bencode, st)
      {:ok, <<@msg_extended, _ext_id, _::binary>>, st} ->
        recv_ext_handshake_loop(st, timeout, loops + 1)
      {:ok, @keepalive, st} ->
        recv_ext_handshake_loop(st, timeout, loops + 1)
      {:ok, <<msg_type>>, st} when msg_type in @only_utm_skip_list ->
        recv_ext_handshake_loop(st, timeout, loops + 1)
      {:ok, <<msg_type, _other_id::binary>>, st} when msg_type in 0..9 ->
        recv_ext_handshake_loop(st, timeout, loops + 1)
      {:ok, <<msg_type, _fe_msg::binary>>, st} when msg_type in 0x0D..0x11 ->
        recv_ext_handshake_loop(st, timeout, loops + 1)
      {:ok, <<msg_type, _unknown::binary>>, _st} ->
        Logger.debug("[TorrHS] Unexpected_message_type: #{inspect(msg_type)}")
        {:error, :unexpected_message_type}
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp decode_ext_handshake(bencode, st) do
    case SimpleBencodeSync.decode(bencode) do
      {:ok, peer_ext_dict} ->
        {:ok, peer_ext_dict, st}
      {:error, reason} ->
        Logger.debug("[TorrHS] Bencode error in ext handshake: #{inspect(reason)}")
        {:error, reason}
    end
  end
  defp extract_metadata_info(ext_dict, ts) do
    with {:ok, m_dict} <- Map.fetch(ext_dict, @m_key),
         {:ok, peer_ut_id} <- Map.fetch(m_dict, @ut_metadata_key),
         {:ok, size} <- get_metadata_size(ext_dict) do
      {:ok, size, peer_ut_id, @ut_metadata_id, ts}
    else
      :error ->
        {:error, :utm_not_supported}
      {:error, :no_metadata} ->
        {:error, :peer_has_no_metadata}
    end
  end
  defp get_metadata_size(ext_dict) do
    case Map.get(ext_dict, @metadata_size_key) do
      nil -> {:error, :no_metadata}
      0 -> {:error, :no_metadata}
      size when is_integer(size) and size > 0 -> {:ok, size}
      _ -> {:error, :no_metadata}
    end
  end
  defp send_interested(st) do
    case SecureTransport.send(st, <<1::32, @msg_interested>>) do
      {:ok, st} -> {:ok, st}
      err -> err
    end
  end
end