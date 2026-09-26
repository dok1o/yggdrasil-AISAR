defmodule Ygg.Frames do
  @moduledoc """
  Codec for the link frames ironwood exchanges after the `meta` handshake
  (`core.HandleConn`, `reference/yggdrasil-go/src/core/core.go:98-104` hands the connection to ironwood).
  Frame = `uvarint(len)`, `uint8 type`, payload; `len` counts the type byte. Types are
  `wirePacketType` 0..9 (`ironwood/network/wire.go:7-18`); layouts checked field by field
  against the Go codecs (`path` = uvarint ports ended by a uvarint 0, `wire.go:80-114`):
      0 Dummy, 1 KeepAlive: any body, ignored             (peers.go:278-281)
      2 SigReq:      seq, nonce                           (router.go:813-846)
      3 SigRes:      seq, nonce, port, psig[64]           (router.go:876-916)
      4 Announce:    key[32], parent[32], seq, nonce, port, psig[64], sig[64]  (router.go:945-977)
      5 BloomFilter: decoded strictly by `Ygg.Bloom.decode/1` into a filter  (bloomfilter.go:53-116)
      6 PathLookup:  source[32], dest[32], from(path)      (pathfinder.go:308-336)
      7 PathNotify:  path, watermark, source[32], dest[32],
                     info{seq, path, sig[64]}             (pathfinder.go:393-479)
      8 PathBroken:  path, watermark, source[32], dest[32] (pathfinder.go:512-541)
      9 Traffic:     path, from(path), source[32], dest[32], watermark, payload(rest)  (traffic.go:36-70)
  Decoding is as strict as Go: unknown types are `:unrecognized`, short/long frames `:decode`;
  both must close the link like ironwood's `ErrUnrecognizedMessage`/`ErrDecode`. Like
  `wireDecodePath` (`wire.go:88-102`) a path ends at the first uvarint that *decodes* to 0, so a
  non-minimal zero (`0x80 0x00`) terminates it too.
  Signatures (`bytes_for_sig/5` = `routerSigReq.bytesForSig`, `router.go:799-805,863-867`):
  SigRes `psig` is by the responder over `bytes_for_sig(requester, responder, ...)`
  (`router.go:414`, checked at `peers.go:329`); an Announce carries `psig` by `parent` and `sig` by
  `key`, both over `bytes_for_sig(key, parent, ...)`, and `port == 0` only for `key == parent`
  (`router.go:929-935`). PathNotify `info.sig` is by `source` over `notify_sig_bytes/2`
  (`pathfinder.go:375-384,433-435`).
  """
  alias Ygg.{Identity, Wire}
  import Bitwise
  @compile {:inline, [decode: 1, frame: 2, encode_frame: 1]}
  @dummy 0
  @keepalive 1
  @sig_req 2
  @sig_res 3
  @announce 4
  @bloom 5
  @path_lookup 6
  @path_notify 7
  @path_broken 8
  @traffic 9
  @keepalive_frame <<1, @keepalive>>
  @max_u64 (1 <<< 64) - 1
  @type key :: <<_::256>>
  @type sig :: <<_::512>>
  @type path :: [pos_integer()]
  @type notify_info :: %{seq: non_neg_integer(), path: path(), sig: sig()}
  @type path_notify :: %{
          path: path(),
          watermark: non_neg_integer(),
          source: key(),
          dest: key(),
          info: notify_info()
        }
  @type frame ::
          {:dummy, nil}
          | {:keepalive, nil}
          | {:sig_req, %{seq: non_neg_integer(), nonce: non_neg_integer()}}
          | {:sig_res,
             %{
               seq: non_neg_integer(),
               nonce: non_neg_integer(),
               port: non_neg_integer(),
               psig: sig()
             }}
          | {:announce, map()}
          | {:bloom, Ygg.Bloom.t()}
          | {:path_lookup, %{source: key(), dest: key(), from: path()}}
          | {:path_notify, path_notify()}
          | {:path_broken,
             %{path: path(), watermark: non_neg_integer(), source: key(), dest: key()}}
          | {:traffic, map()}
  def type_names,
    do: %{
      @dummy => :dummy,
      @keepalive => :keepalive,
      @sig_req => :sig_req,
      @announce => :announce,
      @sig_res => :sig_res,
      @bloom => :bloom,
      @path_lookup => :path_lookup,
      @path_notify => :path_notify,
      @path_broken => :path_broken,
      @traffic => :traffic
    }
  def keepalive_frame, do: @keepalive_frame
  @doc "2^64 - 1: the watermark of a fresh Traffic (`WriteTo`) and of `_doBroken`."
  def max_watermark, do: @max_u64
  @doc "Wraps a payload with the uvarint length prefix and the type byte."
  @spec frame(byte(), iodata()) :: iodata()
  def frame(type, payload) do
    [Wire.encode_uvarint(1 + IO.iodata_length(payload)), type, payload]
  end
  @doc "Full wire frame (length prefix included) for a decoded-form term."
  @spec encode_frame(frame()) :: iodata()
  def encode_frame({:keepalive, _}), do: @keepalive_frame
  def encode_frame({name, body}), do: frame(type_of(name), encode(name, body))
  @spec decode(binary()) :: {:ok, frame()} | {:error, :decode | :unrecognized}
  def decode(<<@dummy, _::binary>>), do: {:ok, {:dummy, nil}}
  def decode(<<@keepalive, _::binary>>), do: {:ok, {:keepalive, nil}}
  def decode(<<@sig_req, rest::binary>>) do
    with {:ok, seq, rest} <- Wire.decode_uvarint(rest),
         {:ok, nonce, <<>>} <- Wire.decode_uvarint(rest) do
      {:ok, {:sig_req, %{seq: seq, nonce: nonce}}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<@sig_res, rest::binary>>) do
    with {:ok, seq, rest} <- Wire.decode_uvarint(rest),
         {:ok, nonce, rest} <- Wire.decode_uvarint(rest),
         {:ok, port, rest} <- Wire.decode_uvarint(rest),
         {:ok, psig, <<>>} <- Wire.take_sig(rest) do
      {:ok, {:sig_res, %{seq: seq, nonce: nonce, port: port, psig: psig}}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<@announce, rest::binary>>) do
    with {:ok, key, rest} <- Wire.take_key(rest),
         {:ok, parent, rest} <- Wire.take_key(rest),
         {:ok, seq, rest} <- Wire.decode_uvarint(rest),
         {:ok, nonce, rest} <- Wire.decode_uvarint(rest),
         {:ok, port, rest} <- Wire.decode_uvarint(rest),
         {:ok, psig, rest} <- Wire.take_sig(rest),
         {:ok, sig, <<>>} <- Wire.take_sig(rest) do
      body = %{key: key, parent: parent, seq: seq, nonce: nonce, port: port, psig: psig, sig: sig}
      {:ok, {:announce, body}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<@bloom, rest::binary>>) do
    case Ygg.Bloom.decode(rest) do
      {:ok, f} -> {:ok, {:bloom, f}}
      {:error, _} -> {:error, :decode}
    end
  end
  def decode(<<@path_lookup, rest::binary>>) do
    with {:ok, source, rest} <- Wire.take_key(rest),
         {:ok, dest, rest} <- Wire.take_key(rest),
         {:ok, from, <<>>} <- take_path(rest) do
      {:ok, {:path_lookup, %{source: source, dest: dest, from: from}}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<@path_notify, rest::binary>>) do
    with {:ok, path, rest} <- take_path(rest),
         {:ok, watermark, rest} <- Wire.decode_uvarint(rest),
         {:ok, source, rest} <- Wire.take_key(rest),
         {:ok, dest, rest} <- Wire.take_key(rest),
         {:ok, seq, rest} <- Wire.decode_uvarint(rest),
         {:ok, ipath, rest} <- take_path(rest),
         {:ok, sig, <<>>} <- Wire.take_sig(rest) do
      info = %{seq: seq, path: ipath, sig: sig}
      body = %{path: path, watermark: watermark, source: source, dest: dest, info: info}
      {:ok, {:path_notify, body}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<@path_broken, rest::binary>>) do
    with {:ok, path, rest} <- take_path(rest),
         {:ok, watermark, rest} <- Wire.decode_uvarint(rest),
         {:ok, source, rest} <- Wire.take_key(rest),
         {:ok, dest, <<>>} <- Wire.take_key(rest) do
      {:ok, {:path_broken, %{path: path, watermark: watermark, source: source, dest: dest}}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<@traffic, rest::binary>>) do
    with {:ok, path, rest} <- take_path(rest),
         {:ok, from, rest} <- take_path(rest),
         {:ok, source, rest} <- Wire.take_key(rest),
         {:ok, dest, rest} <- Wire.take_key(rest),
         {:ok, watermark, payload} <- Wire.decode_uvarint(rest) do
      body = %{
        path: path,
        from: from,
        source: source,
        dest: dest,
        watermark: watermark,
        payload: payload
      }
      {:ok, {:traffic, body}}
    else
      _ -> {:error, :decode}
    end
  end
  def decode(<<_type, _::binary>>), do: {:error, :unrecognized}
  def decode(<<>>), do: {:error, :decode}
  @doc """
  Payload (without length and type) for a decoded-form body. `:bloom` and `:path_notify` also
  accept an already encoded binary body (passed through as is).
  """
  @spec encode(atom(), term()) :: iodata()
  def encode(:dummy, _), do: <<>>
  def encode(:keepalive, _), do: <<>>
  def encode(:sig_req, %{seq: seq, nonce: nonce}),
    do: [Wire.encode_uvarint(seq), Wire.encode_uvarint(nonce)]
  def encode(:sig_res, %{seq: seq, nonce: nonce, port: port, psig: psig}),
    do: [Wire.encode_uvarint(seq), Wire.encode_uvarint(nonce), Wire.encode_uvarint(port), psig]
  def encode(:announce, %{
        key: k,
        parent: p,
        seq: seq,
        nonce: nonce,
        port: port,
        psig: psig,
        sig: sig
      }),
      do: [
        k,
        p,
        Wire.encode_uvarint(seq),
        Wire.encode_uvarint(nonce),
        Wire.encode_uvarint(port),
        psig,
        sig
      ]
  def encode(:bloom, f) when is_integer(f), do: Ygg.Bloom.encode(f)
  def encode(:bloom, bin) when is_binary(bin), do: bin
  def encode(:path_lookup, %{source: s, dest: d, from: from}), do: [s, d, Wire.encode_path(from)]
  def encode(:path_notify, bin) when is_binary(bin), do: bin
  def encode(:path_notify, %{path: path, watermark: wm, source: s, dest: d, info: info}) do
    %{seq: seq, path: ipath, sig: sig} = info
    [Wire.encode_path(path), Wire.encode_uvarint(wm), s, d, notify_sig_bytes(seq, ipath), sig]
  end
  def encode(:path_broken, %{path: path, watermark: wm, source: s, dest: d}),
    do: [Wire.encode_path(path), Wire.encode_uvarint(wm), s, d]
  def encode(:traffic, %{path: path, from: from, source: s, dest: d, watermark: wm, payload: pl}),
    do: [Wire.encode_path(path), Wire.encode_path(from), s, d, Wire.encode_uvarint(wm), pl]
  @doc """
  `routerSigReq/Res.bytesForSig(node, parent)` (`router.go:799-805,863-867`):
  `node ++ parent ++ uvarint(seq) ++ uvarint(nonce) ++ uvarint(port)`. For a SigRes `node` is the
  requester and `parent` the responder (the signer); for an Announce `node = key`.
  """
  @spec bytes_for_sig(key(), key(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          iodata()
  def bytes_for_sig(node_key, parent_key, seq, nonce, port),
    do: [
      node_key,
      parent_key,
      Wire.encode_uvarint(seq),
      Wire.encode_uvarint(nonce),
      Wire.encode_uvarint(port)
    ]
  @doc """
  `pathNotifyInfo.bytesForSig` (`pathfinder.go:375-380`): `uvarint(seq) ++ path ++ 0`, i.e. the
  info encoding without the signature; the path keeps its 0 terminator.
  """
  @spec notify_sig_bytes(non_neg_integer(), path()) :: iodata()
  def notify_sig_bytes(seq, path), do: [Wire.encode_uvarint(seq), Wire.encode_path(path)]
  @doc "`routerAnnounce.check` (`router.go:929-935`): `port 0 => key == parent`, `sig` by key, `psig` by parent."
  @spec verify_announce(map()) :: boolean()
  def verify_announce(%{key: key, parent: parent, port: 0}) when key != parent, do: false
  def verify_announce(%{key: k, parent: p, seq: seq, nonce: n, port: port, psig: psig, sig: sig}) do
    bytes = IO.iodata_to_binary(bytes_for_sig(k, p, seq, n, port))
    Identity.verify(k, bytes, sig) and Identity.verify(p, bytes, psig)
  end
  @doc "`routerSigRes.check(requester, responder)` (`router.go:858-861`, used at `peers.go:329`)."
  @spec verify_sig_res(map(), key(), key()) :: boolean()
  def verify_sig_res(%{seq: seq, nonce: nonce, port: port, psig: psig}, requester, responder),
    do: Identity.verify(responder, bytes_for_sig(requester, responder, seq, nonce, port), psig)
  @doc "`pathNotify.check` (`pathfinder.go:433-435`): `info.sig` by `source` over `notify_sig_bytes/2`."
  @spec verify_path_notify(path_notify()) :: boolean()
  def verify_path_notify(%{source: source, info: %{seq: seq, path: path, sig: sig}}),
    do: Identity.verify(source, notify_sig_bytes(seq, path), sig)
  @doc """
  PathBroken for Traffic we cannot forward and that is not for us, exactly as `_doBroken`
  (`pathfinder.go:226-234`): `path = traffic.from` (the sender's coords), `watermark = 2^64 - 1`,
  `source`/`dest` copied from the traffic (not our key). Go then routes it with `_lookup` on
  `path` towards the traffic's source. Go never answers a PathLookup with PathBroken.
  """
  @spec path_broken_for(%{from: path(), source: key(), dest: key()}) :: {:path_broken, map()}
  def path_broken_for(%{from: from, source: src, dest: dst}),
    do: {:path_broken, %{path: from, watermark: @max_u64, source: src, dest: dst}}
  defp take_path(bin, acc \\ []) do
    case Wire.decode_uvarint(bin) do
      {:ok, 0, rest} -> {:ok, Enum.reverse(acc), rest}
      {:ok, port, rest} -> take_path(rest, [port | acc])
      :error -> :error
    end
  end
  defp type_of(:dummy), do: @dummy
  defp type_of(:keepalive), do: @keepalive
  defp type_of(:sig_req), do: @sig_req
  defp type_of(:sig_res), do: @sig_res
  defp type_of(:announce), do: @announce
  defp type_of(:bloom), do: @bloom
  defp type_of(:path_lookup), do: @path_lookup
  defp type_of(:path_notify), do: @path_notify
  defp type_of(:path_broken), do: @path_broken
  defp type_of(:traffic), do: @traffic
end