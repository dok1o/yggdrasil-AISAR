defmodule Ygg.Pathfinder do
  @moduledoc """
  Pure port of the ironwood pathfinder (`network/pathfinder.go`) plus the traffic entry points
  of the router (`router.go:583-605` `sendTraffic`/`handleTraffic`) and `PacketConn.WriteTo`/
  `SendLookup` (`packetconn.go:72-95, 288-294`). No processes, no timers: every call takes the
  state and an `env`, and returns `{pf, effects}`; Go timers become `expires_at` fields swept by
  `tick/2` (`pathTimeout` 60 s, `pathThrottle` 1 s, `config.go:469-470`).
  Tree lookup, bloom multicast and on-tree gating come from the caller (`env`), so this module
  does not depend on `Ygg.Tree`/`Ygg.Bloom`:
      env :: %{
        now: integer(),                 # monotonic ms (timers)
        unix: non_neg_integer(),        # unix seconds, PathNotify info.seq (pathfinder.go:72)
        coords: [pos_integer()],        # our ports root-first (_getRootAndPath(self))
        route: ([port], wm -> {:forward, link, new_wm} | :none),   # router._lookup
        multicast: (x_key, link | nil -> [link]),                   # blooms._sendMulticast
        on_tree?: (link -> boolean())                               # blooms._isOnTree
      }
  Effects, in emission order: `{:send, link, frame, :queued}` (every pathfinder/traffic send
  is `sendQueued` in Go, `peers.go:389-419`, `bloomfilter.go:328`), `{:deliver, source_key,
  payload}` (`pconn.handleTraffic`), `{:path_notify_event, key}` (`config.pathNotify`).
  Frames: `{:path_lookup, %{source, dest, from}}`, `{:path_notify, %{path, watermark, source,
  dest, info: %{seq, path, sig}}}`, `{:path_broken, %{path, watermark, source, dest}}`,
  `{:traffic, %{path, from, source, dest, watermark, payload}}`.
  API:
      new(identity: Identity.t()) :: t()                    # also :path_timeout, :path_throttle
      send_traffic(t, dest_key, payload, env) :: {t, [effect]} | {:error, :bad_address | :oversized_message}
      handle_traffic(t, from_link, traffic_map, env) :: {t, [effect]}
      handle_lookup(t, from_link, lookup_map, env) :: {t, [effect]}
      handle_notify(t, from_link, notify_map, env) :: {t, [effect]}
      handle_broken(t, from_link, broken_map, env) :: {t, [effect]}
      lookup(t, key_or_partial_key, env) :: {t, [effect]}   # PacketConn.SendLookup
      tick(t, now) :: t()                                   # sweep expired paths/rumors
      paths(t) :: %{key => %{path, seq, broken, expires_at}}
      x_key(key) :: key ;  mtu() :: 130_993
  Go details kept on purpose: the notify signature covers `uvarint(seq) ‖ path ‖ 0`
  (`bytesForSig`, 375-380); our info is re-signed only when `{seq, path}` changes (76-82); a
  known path accepts a notify only with a higher seq *and* a different path (105-119); an unknown
  path needs a rumor for `xKey(source)` (121-124); the last packet sent on a known path is cached
  and re-sent after a path update (196-208, 153-159); `reqTime` is set when a path is created and
  never refreshed, so `_sendLookup` throttles only within 1 s of that (28-33); a throttled rumor
  send does not extend the rumor (166-169); `_doBroken` = `{tr.from, 2^64-1, tr.source, tr.dest}`
  (226-234); a delivered packet extends its source's path unless broken (259-266).
  """
  alias Ygg.{Address, Identity, Wire}
  @max_wm 0xFFFF_FFFF_FFFF_FFFF
  @path_timeout 60_000
  @path_throttle 1_000
  @mtu Wire.peer_max_message_size() - (2 + 64 + byte_size(Wire.encode_uvarint(@max_wm)) + 1)
  defstruct [
    :self_key,
    :self_xkey,
    :identity,
    :info,
    paths: %{},
    rumors: %{},
    timeout: @path_timeout,
    throttle: @path_throttle
  ]
  @type key :: <<_::256>>
  @type link :: term()
  @type effect ::
          {:send, link(), {atom(), map()}, :queued}
          | {:deliver, key(), binary()}
          | {:path_notify_event, key()}
  @type t :: %__MODULE__{}
  def max_watermark, do: @max_wm
  def mtu, do: @mtu
  @spec x_key(key()) :: key()
  def x_key(key), do: Address.subnet_get_key(Address.subnet_for_key(key))
  @spec new(keyword()) :: t()
  def new(opts) do
    %Identity{pub: pub} = id = Keyword.fetch!(opts, :identity)
    %__MODULE__{
      self_key: pub,
      self_xkey: x_key(pub),
      identity: id,
      info: signed_info(id, 0, []),
      timeout: Keyword.get(opts, :path_timeout, @path_timeout),
      throttle: Keyword.get(opts, :path_throttle, @path_throttle)
    }
  end
  @spec send_traffic(t(), key(), binary(), map()) ::
          {t(), [effect()]} | {:error, :bad_address | :oversized_message}
  def send_traffic(_pf, dest, _payload, _env) when byte_size(dest) != 32,
    do: {:error, :bad_address}
  def send_traffic(_pf, _dest, payload, _env) when byte_size(payload) > @mtu,
    do: {:error, :oversized_message}
  def send_traffic(pf, dest, payload, env) do
    tr = %{
      path: [],
      from: [],
      source: pf.self_key,
      dest: dest,
      watermark: @max_wm,
      payload: payload
    }
    done(pf_traffic(pf, [], tr, env))
  end
  @spec handle_traffic(t(), link(), map(), map()) :: {t(), [effect()]}
  def handle_traffic(pf, _from, tr, env), do: done(route_traffic(pf, [], tr, env))
  @spec handle_lookup(t(), link(), map(), map()) :: {t(), [effect()]}
  def handle_lookup(pf, from, lookup, env) do
    if env.on_tree?.(from), do: done(do_lookup(pf, [], from, lookup, env)), else: {pf, []}
  end
  @spec handle_notify(t(), link(), map(), map()) :: {t(), [effect()]}
  def handle_notify(pf, _from, notify, env), do: done(do_notify(pf, [], notify, env))
  @spec handle_broken(t(), link(), map(), map()) :: {t(), [effect()]}
  def handle_broken(pf, _from, broken, env), do: done(do_broken(pf, [], broken, env))
  @spec lookup(t(), key(), map()) :: {t(), [effect()]}
  def lookup(pf, key, env), do: done(rumor_send_lookup(pf, [], key, env))
  @spec tick(t(), integer()) :: t()
  def tick(pf, now) do
    alive = fn {_k, v} -> now < v.expires_at end
    %{pf | paths: Map.filter(pf.paths, alive), rumors: Map.filter(pf.rumors, alive)}
  end
  @spec paths(t()) :: %{key() => map()}
  def paths(pf), do: Map.new(pf.paths, fn {k, i} -> {k, Map.drop(i, [:traffic, :req_at])} end)
  defp done({pf, acc}), do: {pf, Enum.reverse(acc)}
  defp emit(acc, link, frame), do: [{:send, link, frame, :queued} | acc]
  defp pf_traffic(pf, acc, %{dest: dest} = tr, env) do
    case pf.paths do
      %{^dest => info} ->
        tr = %{tr | path: info.path, from: env.coords}
        pf = %{pf | paths: %{pf.paths | dest => %{info | traffic: copy(tr)}}}
        route_traffic(pf, acc, tr, env)
      _ ->
        {pf, acc} = rumor_send_lookup(pf, acc, dest, env)
        x = x_key(dest)
        {pf |> Map.update!(:rumors, &Map.update!(&1, x, fn r -> %{r | traffic: copy(tr)} end)),
         acc}
    end
  end
  defp copy(tr), do: %{tr | payload: :binary.copy(tr.payload)}
  defp route_traffic(pf, acc, tr, env) do
    case env.route.(tr.path, tr.watermark) do
      {:forward, link, wm} ->
        {pf, emit(acc, link, {:traffic, %{tr | watermark: wm}})}
      :none when tr.dest == pf.self_key ->
        {reset_timeout(pf, tr.source, env.now), [{:deliver, tr.source, tr.payload} | acc]}
      :none ->
        broken = %{path: tr.from, watermark: @max_wm, source: tr.source, dest: tr.dest}
        do_broken(pf, acc, broken, env)
    end
  end
  defp reset_timeout(pf, key, now) do
    case pf.paths do
      %{^key => %{broken: false} = i} ->
        %{pf | paths: %{pf.paths | key => %{i | expires_at: now + pf.timeout}}}
      _ ->
        pf
    end
  end
  defp do_broken(pf, acc, %{dest: dest} = b, env) do
    case env.route.(b.path, b.watermark) do
      {:forward, link, wm} ->
        {pf, emit(acc, link, {:path_broken, %{b | watermark: wm}})}
      :none when b.source != pf.self_key ->
        {pf, acc}
      :none ->
        case pf.paths do
          %{^dest => i} ->
            send_lookup(%{pf | paths: %{pf.paths | dest => %{i | broken: true}}}, acc, dest, env)
          _ ->
            {pf, acc}
        end
    end
  end
  defp rumor_send_lookup(pf, acc, dest, env) do
    x = x_key(dest)
    fresh = %{traffic: nil, send_at: env.now, expires_at: env.now + pf.timeout}
    case pf.rumors do
      %{^x => %{send_at: t}} when env.now - t < pf.throttle ->
        {pf, acc}
      %{^x => r} ->
        send_lookup(
          %{pf | rumors: %{pf.rumors | x => %{fresh | traffic: r.traffic}}},
          acc,
          dest,
          env
        )
      _ ->
        send_lookup(%{pf | rumors: Map.put(pf.rumors, x, fresh)}, acc, dest, env)
    end
  end
  defp send_lookup(pf, acc, dest, env) do
    case pf.paths do
      %{^dest => %{req_at: t}} when env.now - t < pf.throttle ->
        {pf, acc}
      _ ->
        do_lookup(pf, acc, nil, %{source: pf.self_key, dest: dest, from: env.coords}, env)
    end
  end
  defp do_lookup(pf, acc, from, lookup, env) do
    dx = x_key(lookup.dest)
    acc = Enum.reduce(env.multicast.(dx, from), acc, &emit(&2, &1, {:path_lookup, lookup}))
    if dx == pf.self_xkey do
      pf =
        if pf.info.seq == env.unix and pf.info.path == env.coords,
          do: pf,
          else: %{pf | info: signed_info(pf.identity, env.unix, env.coords)}
      notify = %{
        path: lookup.from,
        watermark: @max_wm,
        source: pf.self_key,
        dest: lookup.source,
        info: pf.info
      }
      do_notify(pf, acc, notify, env)
    else
      {pf, acc}
    end
  end
  defp do_notify(pf, acc, n, env) do
    case env.route.(n.path, n.watermark) do
      {:forward, link, wm} -> {pf, emit(acc, link, {:path_notify, %{n | watermark: wm}})}
      :none when n.dest != pf.self_key -> {pf, acc}
      :none -> accept_notify(pf, acc, n, env)
    end
  end
  defp accept_notify(pf, acc, %{source: src, info: %{seq: seq, path: path}} = n, env) do
    case pf.paths do
      %{^src => i} ->
        if seq > i.seq and path != i.path and check(n),
          do: store(pf, acc, n, %{i | expires_at: env.now + pf.timeout}, env),
          else: {pf, acc}
      _ ->
        x = x_key(src)
        with %{^x => rumor} <- pf.rumors, true <- check(n) do
          {tr, rumors} =
            case rumor.traffic do
              %{dest: ^src} = tr -> {tr, %{pf.rumors | x => %{rumor | traffic: nil}}}
              _ -> {nil, pf.rumors}
            end
          i = %{
            path: [],
            seq: 0,
            req_at: env.now,
            expires_at: env.now + pf.timeout,
            traffic: tr,
            broken: false
          }
          store(%{pf | rumors: rumors}, acc, n, i, env)
        else
          _ -> {pf, acc}
        end
    end
  end
  defp store(pf, acc, %{source: src, info: nfo}, %{traffic: tr} = i, env) do
    i = %{i | path: nfo.path, seq: nfo.seq, broken: false, traffic: nil}
    pf = %{pf | paths: Map.put(pf.paths, src, i)}
    acc = [{:path_notify_event, src} | acc]
    if tr, do: pf_traffic(pf, acc, tr, env), else: {pf, acc}
  end
  defp sig_bytes(seq, path), do: [Wire.encode_uvarint(seq), Wire.encode_path(path)]
  defp signed_info(id, seq, path),
    do: %{seq: seq, path: path, sig: Identity.sign(id, sig_bytes(seq, path))}
  defp check(%{source: src, info: %{seq: seq, path: path, sig: sig}}),
    do: Identity.verify(src, sig_bytes(seq, path), sig)
end