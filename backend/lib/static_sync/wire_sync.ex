defmodule WireSync do
  @compile {:inline, [valid_args?: 2, ihv?: 1]}
  @typedoc "20b SHA-1 base value: remote node_id, infohash, other"
  @type target :: <<_::160>>
  @type nid :: target()
  @type rid :: target()
  @type tid :: <<_::16>>
  @type trunc8_hmac_token :: <<_::64>>
  @node_id "id"
  @ihv "target"
  @ih "info_hash"
  @pq "ping"
  @fnq "find_node"
  @gpq "get_peers"
  @apq "announce_peer"
  @port "port"
  @impl_port "implied_port"
  @hmac_token "token"
  @nodes "nodes"
  @values "values"
  @hpq "holepunch"
  @target "target"
  @requester "requester"
  @smq "sample_infohashes"
  @samples "samples"
  @num "num"
  @interval "interval"
  @dht_bits 160
  @zeroed_tid <<0, 0>>
  def ihv?(<<0::@dht_bits>>), do: false
  def ihv?(<<_target::@dht_bits>>), do: true
  def ihv?(_non_sha1), do: false
  def recv(data) do
    case SimpleBencodeSync.decode(data) do
      {:ok, %{"y" => "q", "q" => q, "a" => a, "t" => t}} when is_binary(q) and is_map(a) ->
        case valid_args?(q, a) do
          true -> {:query, q, norm_args(a), t}
          false -> {:error, :non_sha1_args, {q, a, t}}
        end
      {:ok, %{"y" => "q", "q" => q, "a" => a}} when is_binary(q) and is_map(a) ->
        case valid_args?(q, a) do
          true -> {:query, q, norm_args(a), @zeroed_tid}
          false -> {:error, :non_sha1_args, {q, a, @zeroed_tid}}
        end
      {:ok, %{"y" => "r", "r" => r, "t" => t}} when is_map(r) ->
        {:reply, norm_args(r), t}
      {:ok, %{"y" => "r", "r" => r}} when is_map(r) ->
        {:reply, norm_args(r), @zeroed_tid}
      {:ok, %{"y" => "r", "e" => [code, msg], "t" => t}} ->
        {:error, code, msg, t}
      {:ok, %{"y" => "r", "e" => [code, msg]}} ->
        {:error, code, msg, @zeroed_tid}
      {:ok, %{"y" => "e", "e" => [code, msg], "t" => t}} ->
        {:error, code, msg, t}
      {:ok, %{"y" => "e", "e" => [code, msg]}} ->
        {:error, code, msg, @zeroed_tid}
      {:ok, %{"y" => "e"} = map} ->
        {:error, :malformed_map, map}
      {:ok, %{"v" => _v}} ->
        {:error, :libtorrent_keepalive}
      {:ok, map} when is_map(map) ->
        {:error, :malformed_map, map}
      {:ok, malformed} ->
        {:error, :malformed_map, malformed}
      {:error, _reason} ->
        {:error, :malformed_map, nil}
    end
  end
  def ping(nid, tid),
    do: encode_query(@pq, %{@node_id => nid}, tid)
  def find_node(nid, rid, tid),
    do: encode_query(@fnq, %{@node_id => nid, @ihv => rid}, tid)
  def get_peers(nid, ih, tid),
    do: encode_query(@gpq, %{@node_id => nid, @ih => ih}, tid)
  def announce_peer(nid, ih, token, port, tid) do
    args = %{
      @node_id => nid,
      @ih => ih,
      @hmac_token => token,
      @port => port,
      @impl_port => 0
    }
    encode_query(@apq, args, tid)
  end
  def holepunch(nid, target, requester_peer, tid) do
    args = %{
      @node_id => nid,
      @target => target,
      @requester => requester_peer
    }
    encode_query(@hpq, args, tid)
  end
  def sample_infohashes(nid, target, tid) do
    args = %{@node_id => nid, @target => target}
    encode_query(@smq, args, tid)
  end
  def ping_reply(nid, tid),
    do: encode_reply(%{@node_id => nid}, tid)
  def find_node_reply(nid, packed_nodes, tid),
    do: encode_reply(%{@node_id => nid, @nodes => packed_nodes}, tid)
  def get_peers_reply_values(nid, token, values_list, ih, tid),
    do:
      encode_reply(
        %{@node_id => nid, @hmac_token => token, @values => values_list, @ih => ih},
        tid
      )
  def get_peers_reply_nodes(nid, token, packed_nodes_bin, tid),
    do: encode_reply(%{@node_id => nid, @hmac_token => token, @nodes => packed_nodes_bin}, tid)
  def announce_peer_reply(nid, tid),
    do: encode_reply(%{@node_id => nid}, tid)
  def holepunch_reply(nid, tid) do
    encode_reply(%{@node_id => nid}, tid)
  end
  def sample_infohashes_reply(nid, tid, num, samples, interval \\ 0) do
    data = %{
      @node_id => nid,
      @num => num,
      @samples => samples,
      @interval => interval
    }
    encode_reply(data, tid)
  end
  defp encode_query(name, args, tid),
    do: encode_outgoing(%{"y" => "q", "q" => name, "a" => args, "t" => tid})
  defp encode_reply(data, tid),
    do: encode_outgoing(%{"y" => "r", "r" => data, "t" => tid})
  defp encode_outgoing(map) do
    try do
      SimpleBencodeSync.encode(map)
    rescue
      _malformed ->
        <<>>
    end
  end
  defp valid_args?(@fnq, %{@ihv => t}), do: ihv?(t)
  defp valid_args?(@smq, %{@target => t}), do: ihv?(t)
  defp valid_args?(@gpq, %{@ih => ih}), do: ihv?(ih)
  defp valid_args?(@apq, %{@ih => ih}), do: ihv?(ih)
  defp valid_args?(@hpq, %{@target => t, @requester => r}) do
    UAddrChkSync.good?(t) and UAddrChkSync.good?(r)
  end
  defp valid_args?(@hpq, %{@target => t}), do: ihv?(t)
  defp valid_args?(_query, _args), do: true
  @pf_magic "f"
  @f_syn 0
  def ping_x(nid, tid),
    do: encode_query(@pq, %{@node_id => nid, @pf_magic => @f_syn}, tid)
  defp norm_args(args), do: {normalize_ihv(args[@node_id]), args}
  defp normalize_ihv(<<0::@dht_bits>>), do: IdGenSync.rand_id()
  defp normalize_ihv(<<_target::@dht_bits>> = raw_rid), do: raw_rid
  defp normalize_ihv(_malformed), do: IdGenSync.rand_id()
end