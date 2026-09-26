defmodule Ygg.Tree do
  @moduledoc """
  Pure port of ironwood's spanning tree (`network/router.go`), wire compatible with the real
  Yggdrasil network. No processes, no timers, no clock: the caller passes `now` (monotonic ms)
  and gets `{tree, effects}` back, `effects = [{:send, link_ref, Ygg.Frames.frame()}]` in the
  order Go would write them. Bloom filters, pathfinder and signature *verification* live
  elsewhere (`peers.go:329,347` verify before `router.handle*` is called); we only sign our own
  SigRes / self info. Link refs are opaque (pids in the router); several links may share a key.
  API (router.go line ranges):
      new(Identity.t(), now, opts) :: t()                       init + first _doMaintenance, 65-100
        opts: nonce_fun: (-> 0..2^64-1)   default 8 random bytes BE (_newReq, 381-388)
      add_link(t, ref, peer_key, port, prio, now) :: {t, effects}                 addPeer, 117-145
      remove_link(t, ref, now) :: {t, effects}                                 removePeer, 147-173
      handle_sig_req(t, ref, %{seq, nonce}) :: {t, effects}               _handleRequest, 409-416
      handle_sig_res(t, ref, %{seq, nonce, port, psig}, rtt_ns, now) :: {t, effects}   424-443
      handle_announce(t, ref, announce, now) :: {t, effects}    _update + _handleAnnounce, 472-575
      tick(t, now) :: {t, effects}          timers (511-535) + _doMaintenance minus bloom, 89-100
      root_and_path(t, key) :: {root, [port]}   ports root-first; loop/dead end {key, []}, 630-659
      coords(t, key) :: [port]
      dist([port], [port]) :: non_neg_integer                            |A|+|B|-2*LCP, 661-683
      key_dist(t, dest_path, key) :: non_neg_integer                               _getDist
      lookup(t, dest_path, watermark) :: {:forward, ref, new_watermark} | :none  _lookup, 685-758
      parent(t) / root(t) :: key;  depth(t) :: non_neg_integer
      peers(t) :: [%{ref, key, port, prio, order, lag_ns, cost}]      sorted by order; cost 221-228
      infos(t) :: %{key => info};  on_tree_keys(t) :: MapSet  (bloomfilter.go _fixOnTree 144-173)
      check_announce(ann) :: boolean                                  routerAnnounce.check, 929-935
      check_sig_res(res, node_key, parent_key) :: boolean               routerSigRes.check, 858-861
  `info = %{parent, seq, nonce, port, psig, sig, expires_at}`; for foreign keys `expires_at` is
  the routerTimeout deadline (deleted on the first `tick` at or after it), for our own key it is
  the routerRefresh deadline (sets `refresh`, then `nil` until our info is replaced).
  Choices where Go is nondeterministic (map iteration): responses in `_fix`, peers in
  `_sendReqs`/`_sendAnnounces` are walked in key order; `_lookup` candidates and the links of a
  key in `order` order. Lags and `rtt_ns` are nanoseconds like Go's `time.Duration`; `rtt_ns = nil`
  (no SigReq written on that link yet) keeps the response but leaves the lag alone. Products (`dist × cost`) wrap at 2^64 like Go's `uint64`.
  `doRoot1/doRoot2` stay booleans flipped once per tick, exactly as in `_doMaintenance`/`_fix`.
  """
  import Bitwise
  alias Ygg.{Frames, Identity}
  @u64 0xFFFF_FFFF_FFFF_FFFF
  @unknown_latency 0xFFFF_FFFF
  @router_refresh_ms 4 * 60_000
  @router_timeout_ms 5 * 60_000
  @tick_ms 1_000
  defstruct [
    :id,
    :key,
    :now,
    :nonce_fun,
    infos: %{},
    links: %{},
    peers: %{},
    sent: %{},
    requests: %{},
    responses: %{},
    responded: MapSet.new(),
    refresh: false,
    do_root1: false,
    do_root2: true,
    order: 0
  ]
  @type key :: <<_::256>>
  @type link_ref :: term()
  @type effect :: {:send, link_ref(), Frames.frame()}
  @type info :: %{
          parent: key(),
          seq: non_neg_integer(),
          nonce: non_neg_integer(),
          port: non_neg_integer(),
          psig: binary(),
          sig: binary(),
          expires_at: integer() | nil
        }
  @type t :: %__MODULE__{}
  def unknown_latency_ns, do: @unknown_latency
  def router_refresh_ms, do: @router_refresh_ms
  def router_timeout_ms, do: @router_timeout_ms
  def tick_ms, do: @tick_ms
  @doc "router.init: doRoot2 = true and an immediate _doMaintenance, so we start as root, seq 1."
  @spec new(Identity.t(), integer(), keyword()) :: t()
  def new(%Identity{pub: pub} = id, now, opts \\ []) do
    t = %__MODULE__{
      id: id,
      key: pub,
      now: now,
      nonce_fun: Keyword.get(opts, :nonce_fun, &random_nonce/0)
    }
    {t, []} = tick(t, now)
    t
  end
  @doc "addPeer (router.go:117-145): replay `sent[key]` to a further link, one SigReq per key."
  @spec add_link(t(), link_ref(), key(), non_neg_integer(), non_neg_integer(), integer()) ::
          {t(), [effect()]}
  def add_link(%__MODULE__{} = t, ref, peer_key, port, prio, now) do
    {t, _} = if Map.has_key?(t.links, ref), do: remove_link(t, ref, now), else: {t, []}
    t = %{t | now: now}
    {t, replay} =
      case t.sent do
        %{^peer_key => sent} ->
          {t, for(k <- sent, Map.has_key?(t.infos, k), do: {:send, ref, announce(k, t.infos[k])})}
        _ ->
          {%{
             t
             | peers: Map.put(t.peers, peer_key, MapSet.new()),
               sent: Map.put(t.sent, peer_key, MapSet.new())
           }, []}
      end
    link = %{key: peer_key, port: port, prio: prio, order: t.order, lag: @unknown_latency}
    t = %{
      t
      | peers: Map.update!(t.peers, peer_key, &MapSet.put(&1, ref)),
        links: Map.put(t.links, ref, link),
        order: t.order + 1,
        responded: MapSet.delete(t.responded, ref)
    }
    req = Map.get_lazy(t.requests, peer_key, fn -> new_req(t) end)
    t = %{t | requests: Map.put(t.requests, peer_key, req)}
    {t, replay ++ [{:send, ref, {:sig_req, req}}]}
  end
  @doc "removePeer (router.go:147-173); the bloom resend to remaining links is the router's job."
  @spec remove_link(t(), link_ref(), integer()) :: {t(), [effect()]}
  def remove_link(%__MODULE__{} = t, ref, now) do
    case Map.pop(t.links, ref) do
      {nil, _} ->
        {%{t | now: now}, []}
      {%{key: pk}, links} ->
        ps = MapSet.delete(t.peers[pk], ref)
        t = %{t | now: now, links: links, responded: MapSet.delete(t.responded, ref)}
        if MapSet.size(ps) == 0 do
          {%{
             t
             | peers: Map.delete(t.peers, pk),
               sent: Map.delete(t.sent, pk),
               requests: Map.delete(t.requests, pk),
               responses: Map.delete(t.responses, pk)
           }, []}
        else
          {%{t | peers: Map.put(t.peers, pk, ps)}, []}
        end
    end
  end
  @doc "_handleRequest (router.go:409-416): psig over bytesForSig(peer, us) with the link's port."
  @spec handle_sig_req(t(), link_ref(), %{seq: non_neg_integer(), nonce: non_neg_integer()}) ::
          {t(), [effect()]}
  def handle_sig_req(%__MODULE__{} = t, ref, %{seq: seq, nonce: nonce}) do
    case t.links do
      %{^ref => %{key: pk, port: port}} ->
        psig = Identity.sign(t.id, Frames.bytes_for_sig(pk, t.key, seq, nonce, port))
        {t, [{:send, ref, {:sig_res, %{seq: seq, nonce: nonce, port: port, psig: psig}}}]}
      _ ->
        {t, []}
    end
  end
  @doc """
  _handleResponse (router.go:424-443): only a response matching `requests[key]` counts; the
  first one per key is kept, and each link updates its lag once per request:
  unknown → `rtt*2`, else `lag*7/8 + min(rtt, 2*lag)/8` (ns). Go measures `rtt` from a zero
  `srst` when the link never wrote a SigReq (`peers.go:318-334`), a meaningless huge value;
  here that is `rtt_ns = nil`: the response counts for the tree, the lag is not touched.
  """
  @spec handle_sig_res(t(), link_ref(), map(), non_neg_integer() | nil, integer()) ::
          {t(), [effect()]}
  def handle_sig_res(%__MODULE__{} = t, ref, %{seq: seq, nonce: nonce} = res, rtt_ns, now) do
    t = %{t | now: now}
    with %{^ref => %{key: pk, lag: lag} = link} <- t.links,
         %{^pk => %{seq: ^seq, nonce: ^nonce}} <- t.requests do
      t =
        if Map.has_key?(t.responses, pk),
          do: t,
          else: %{
            t
            | responses: Map.put(t.responses, pk, Map.take(res, [:seq, :nonce, :port, :psig]))
          }
      if rtt_ns == nil or MapSet.member?(t.responded, ref) do
        {t, []}
      else
        rtt = max(rtt_ns, 0)
        lag =
          if lag == @unknown_latency,
            do: rtt * 2,
            else: div(lag * 7, 8) + div(min(rtt, lag * 2), 8)
        {%{
           t
           | responded: MapSet.put(t.responded, ref),
             links: Map.put(t.links, ref, %{link | lag: lag})
         }, []}
      end
    else
      _ -> {t, []}
    end
  end
  @doc """
  _handleAnnounce (router.go:544-575). Accepted: refresh if it is about us, mark sent to that
  peer. Rejected but different from ours: reply with what we know on that link only.
  """
  @spec handle_announce(t(), link_ref(), map(), integer()) :: {t(), [effect()]}
  def handle_announce(%__MODULE__{} = t, ref, %{key: k} = ann, now) do
    t = %{t | now: now}
    case t.links do
      %{^ref => %{key: pk}} ->
        case update(t, ann) do
          {:ok, t} ->
            t = if k == t.key, do: %{t | refresh: true}, else: t
            {mark_sent(t, pk, k), []}
          :stale ->
            old = t.infos[k]
            t = mark_sent(t, pk, k)
            if same_info?(old, ann),
              do: {t, []},
              else: {t, [{:send, ref, announce(k, old)}]}
        end
      _ ->
        {t, []}
    end
  end
  @doc "Timers (router.go:511-535) then _doMaintenance (89-100) without bloom: _fix, _sendAnnounces."
  @spec tick(t(), integer()) :: {t(), [effect()]}
  def tick(%__MODULE__{} = t, now) do
    t = expire(%{t | now: now})
    t = %{t | do_root2: t.do_root2 or t.do_root1}
    {t, acc} = fix(t, [])
    {t, acc} = send_announces(t, acc)
    {t, Enum.reverse(acc)}
  end
  @doc "_getRootAndPath (router.go:630-659): ports root-first; loop or dead end → `{key, []}`."
  @spec root_and_path(t(), key()) :: {key(), [non_neg_integer()]}
  def root_and_path(%__MODULE__{infos: infos}, key), do: rap(infos, key, MapSet.new(), [], key)
  defp rap(infos, next, visited, ports, dest) do
    if MapSet.member?(visited, next),
      do: {dest, []},
      else: rap_step(infos, Map.get(infos, next), next, visited, ports, dest)
  end
  defp rap_step(_infos, nil, _next, _visited, _ports, dest), do: {dest, []}
  defp rap_step(_infos, %{parent: next}, next, _visited, ports, _dest), do: {next, ports}
  defp rap_step(infos, %{parent: p, port: port}, next, visited, ports, dest),
    do: rap(infos, p, MapSet.put(visited, next), [port | ports], dest)
  @spec coords(t(), key()) :: [non_neg_integer()]
  def coords(t, key), do: t |> root_and_path(key) |> elem(1)
  @doc "Tree distance of two coordinate paths (router.go:670-682)."
  @spec dist([non_neg_integer()], [non_neg_integer()]) :: non_neg_integer()
  def dist(a, b), do: length(a) + length(b) - 2 * lcp(a, b, 0)
  defp lcp([x | a], [x | b], n), do: lcp(a, b, n + 1)
  defp lcp(_, _, n), do: n
  @doc "_getDist (router.go:661-683): distance from `dest_path` to the coords of `key`."
  @spec key_dist(t(), [non_neg_integer()], key()) :: non_neg_integer()
  def key_dist(t, dest_path, key), do: dist(dest_path, coords(t, key))
  @doc """
  _lookup (router.go:685-758): refuse unless our distance < watermark (which becomes the new
  watermark); candidates are links of keys strictly closer than us; best by cost·dist, dist,
  cost, order, and within one key the lowest prio wins.
  """
  @spec lookup(t(), [non_neg_integer()], non_neg_integer()) ::
          {:forward, link_ref(), non_neg_integer()} | :none
  def lookup(%__MODULE__{} = t, path, watermark) do
    self_d = key_dist(t, path, t.key)
    if self_d >= watermark do
      :none
    else
      best =
        for(
          {pk, refs} <- t.peers,
          (d = key_dist(t, path, pk)) < self_d,
          ref <- refs,
          do: {ref, t.links[ref], d}
        )
        |> Enum.sort_by(fn {_, l, _} -> l.order end)
        |> Enum.reduce(nil, &pick/2)
      case best do
        nil -> :none
        {ref, _, _, _} -> {:forward, ref, self_d}
      end
    end
  end
  defp pick({ref, l, d}, nil), do: {ref, l, d, cost(l)}
  defp pick({ref, l, d}, {_, bl, bd, bc} = best) do
    c = cost(l)
    new = {ref, l, d, c}
    cond do
      l.key == bl.key and l.prio < bl.prio -> new
      l.key == bl.key and l.prio > bl.prio -> best
      mul(c, d) < mul(bc, bd) -> new
      mul(c, d) > mul(bc, bd) -> best
      d < bd -> new
      d > bd -> best
      c < bc -> new
      c > bc -> best
      l.order < bl.order -> new
      true -> best
    end
  end
  @spec parent(t()) :: key()
  def parent(%__MODULE__{infos: infos, key: me}), do: infos[me].parent
  @spec root(t()) :: key()
  def root(%__MODULE__{key: me} = t), do: t |> root_and_path(me) |> elem(0)
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{key: me} = t), do: length(coords(t, me))
  @spec infos(t()) :: %{key() => info()}
  def infos(%__MODULE__{infos: infos}), do: infos
  @doc "Per link: key, port, prio, order, lag (ns) and _getCost (ms, ≥ 1), sorted by order."
  @spec peers(t()) :: [map()]
  def peers(%__MODULE__{links: links}) do
    links
    |> Enum.map(fn {ref, l} ->
      %{
        ref: ref,
        key: l.key,
        port: l.port,
        prio: l.prio,
        order: l.order,
        lag_ns: l.lag,
        cost: cost(l)
      }
    end)
    |> Enum.sort_by(& &1.order)
  end
  @doc "Peer keys on the tree with us: our parent, or peers whose info names us as parent."
  @spec on_tree_keys(t()) :: MapSet.t(key())
  def on_tree_keys(%__MODULE__{key: me, infos: infos, peers: peers}) do
    my_parent = infos[me].parent
    for pk <- Map.keys(peers),
        pk == my_parent or match?(%{parent: ^me}, infos[pk]),
        into: MapSet.new(),
        do: pk
  end
  @doc "routerAnnounce.check (router.go:929-935): both signatures over the same bytes."
  @spec check_announce(map()) :: boolean()
  def check_announce(%{key: k, parent: p, port: port} = a) do
    bs = Frames.bytes_for_sig(k, p, a.seq, a.nonce, port)
    (port != 0 or k == p) and Identity.verify(k, bs, a.sig) and Identity.verify(p, bs, a.psig)
  end
  @doc "routerSigRes.check (router.go:858-861), called as `check(self, peer)` (peers.go:329)."
  @spec check_sig_res(map(), key(), key()) :: boolean()
  def check_sig_res(%{seq: s, nonce: n, port: port, psig: psig}, node, parent),
    do: Identity.verify(parent, Frames.bytes_for_sig(node, parent, s, n, port), psig)
  defp update(t, %{key: k} = ann) do
    if accept?(t.infos[k], ann) do
      ttl = if k == t.key, do: @router_refresh_ms, else: @router_timeout_ms
      info =
        ann
        |> Map.take([:parent, :seq, :nonce, :port, :psig, :sig])
        |> Map.put(:expires_at, t.now + ttl)
      sent = Map.new(t.sent, fn {pk, s} -> {pk, MapSet.delete(s, k)} end)
      {:ok, %{t | infos: Map.put(t.infos, k, info), sent: sent}}
    else
      :stale
    end
  end
  defp accept?(nil, _ann), do: true
  defp accept?(info, ann) do
    cond do
      info.seq > ann.seq -> false
      info.seq < ann.seq -> true
      info.parent < ann.parent -> false
      ann.parent < info.parent -> true
      ann.nonce < info.nonce -> true
      true -> false
    end
  end
  defp same_info?(old, ann),
    do:
      Map.take(old, [:parent, :seq, :nonce, :port, :psig, :sig]) ==
        Map.take(ann, [:parent, :seq, :nonce, :port, :psig, :sig])
  defp mark_sent(t, pk, k), do: %{t | sent: Map.update!(t.sent, pk, &MapSet.put(&1, k))}
  defp announce(k, info),
    do:
      {:announce,
       %{
         key: k,
         parent: info.parent,
         seq: info.seq,
         nonce: info.nonce,
         port: info.port,
         psig: info.psig,
         sig: info.sig
       }}
  defp expire(%{now: now, key: me} = t) do
    Enum.reduce(t.infos, t, fn
      {^me, %{expires_at: e} = info}, t when e != nil and now >= e ->
        %{t | refresh: true, infos: Map.put(t.infos, me, %{info | expires_at: nil})}
      {^me, _}, t ->
        t
      {k, %{expires_at: e}}, t when now >= e ->
        %{
          t
          | infos: Map.delete(t.infos, k),
            sent: Map.new(t.sent, fn {pk, s} -> {pk, MapSet.delete(s, k)} end)
        }
      _, t ->
        t
    end)
  end
  defp fix(%{key: me} = t, acc) do
    self_parent = get_in(t.infos, [me, :parent])
    best =
      with true <- Map.has_key?(t.peers, self_parent),
           {root, dists} <- root_and_dists(t, me),
           true <- root < me do
        {root, self_parent, min_cost(t, self_parent, dists[root])}
      else
        _ -> {me, me, @u64}
      end
    {best_root, best_parent, _} =
      t.responses
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(best, fn pk, {br, bp, bc} = best ->
        with true <- Map.has_key?(t.infos, pk),
             {proot, pdists} <- root_and_dists(t, pk),
             false <- Map.has_key?(pdists, me) do
          cost = min_cost(t, pk, pdists[proot])
          {br, bp, bc, go} =
            cond do
              proot < br -> {proot, pk, cost, true}
              proot != br -> {br, bp, bc, false}
              true -> {br, bp, bc, true}
            end
          if go and
               ((t.refresh and band(cost * 2, @u64) < bc) or
                  (bp != self_parent and cost < bc)),
             do: {proot, pk, cost},
             else: {br, bp, bc}
        else
          _ -> best
        end
      end)
    if t.refresh or t.do_root1 or t.do_root2 or self_parent != best_parent do
      used =
        with %{^best_parent => res} <- t.responses,
             true <- best_root != me do
          use_response(t, best_parent, res)
        else
          _ -> :stale
        end
      case used do
        {:ok, t} ->
          send_reqs(%{t | refresh: false, do_root1: false, do_root2: false}, acc)
        :stale ->
          cond do
            t.do_root2 ->
              {:ok, t} = become_root(t)
              send_reqs(%{t | refresh: false, do_root1: false, do_root2: false}, acc)
            not t.do_root1 ->
              {%{t | do_root1: true}, acc}
            true ->
              {t, acc}
          end
      end
    else
      {t, acc}
    end
  end
  defp min_cost(t, pk, dist) do
    t.peers
    |> Map.get(pk, [])
    |> Enum.reduce(@u64, fn ref, c -> min(c, mul(dist, cost(t.links[ref]))) end)
  end
  defp cost(%{lag: lag}), do: max(div(lag, 1_000_000), 1)
  defp mul(a, b), do: band(a * b, @u64)
  defp root_and_dists(t, dest), do: rad(t.infos, dest, 0, nil, %{})
  defp rad(infos, next, d, root, dists) do
    case {Map.has_key?(dists, next), Map.get(infos, next)} do
      {false, %{parent: p}} -> rad(infos, p, d + 1, next, Map.put(dists, next, d))
      _ -> {root, dists}
    end
  end
  defp ancestry(infos, key), do: anc(infos, key, [])
  defp anc(infos, here, acc) do
    case {here in acc, Map.get(infos, here)} do
      {false, %{parent: p}} -> anc(infos, p, [here | acc])
      _ -> acc
    end
  end
  defp use_response(%{key: me} = t, pk, res) do
    sig = Identity.sign(t.id, Frames.bytes_for_sig(me, pk, res.seq, res.nonce, res.port))
    update(t, %{
      key: me,
      parent: pk,
      seq: res.seq,
      nonce: res.nonce,
      port: res.port,
      psig: res.psig,
      sig: sig
    })
  end
  defp become_root(%{key: me} = t) do
    %{seq: seq, nonce: nonce} = new_req(t)
    psig = Identity.sign(t.id, Frames.bytes_for_sig(me, me, seq, nonce, 0))
    update(t, %{key: me, parent: me, seq: seq, nonce: nonce, port: 0, psig: psig, sig: psig})
  end
  defp new_req(t) do
    seq =
      case t.infos[t.key] do
        %{seq: s} -> s
        nil -> 0
      end
    %{seq: band(seq + 1, @u64), nonce: t.nonce_fun.()}
  end
  defp random_nonce do
    <<n::unsigned-big-64>> = :crypto.strong_rand_bytes(8)
    n
  end
  defp send_reqs(t, acc) do
    t.peers
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{t | requests: %{}, responses: %{}}, acc}, fn {pk, refs}, {t, acc} ->
      req = new_req(t)
      refs = sort_refs(t, refs)
      {%{
         t
         | requests: Map.put(t.requests, pk, req),
           responded: Enum.reduce(refs, t.responded, &MapSet.delete(&2, &1))
       }, Enum.reduce(refs, acc, &[{:send, &1, {:sig_req, req}} | &2])}
    end)
  end
  defp send_announces(t, acc) do
    self_anc = ancestry(t.infos, t.key)
    t.sent
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({t, acc}, fn {pk, sent}, {t, acc} ->
      {to_send, sent} =
        Enum.reduce(self_anc ++ ancestry(t.infos, pk), {[], sent}, fn k, {ts, s} ->
          if MapSet.member?(s, k), do: {ts, s}, else: {[k | ts], MapSet.put(s, k)}
        end)
      anns = to_send |> Enum.reverse() |> Enum.map(&announce(&1, t.infos[&1]))
      acc =
        for ref <- sort_refs(t, t.peers[pk]), ann <- anns, reduce: acc do
          acc -> [{:send, ref, ann} | acc]
        end
      {%{t | sent: Map.put(t.sent, pk, sent)}, acc}
    end)
  end
  defp sort_refs(t, refs), do: Enum.sort_by(refs, &t.links[&1].order)
end