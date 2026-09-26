defmodule Ygg.Session do
  @moduledoc """
  Pure port of one ironwood `encrypted` session (`encrypted/session.go:193-579`,
  `sessionInfo`, `sessionInit`, `sessionAck`) and its wire formats. No processes, no timers:
  `Ygg.Sessions` owns the table (`sessionManager`, 36-191) and calls these functions with an
  `env`; the Go `time.AfterFunc` timers are `expires_at` fields it sweeps.
      env :: %{
        identity: Ygg.Identity.t(),   # our ed25519 key (edSign)
        group: binary(),              # Ygg.Crypto.group_secret(password), <<>> = no group auth
        now: integer(),               # monotonic ms: timeout (60 s) and rotation throttle (60 s)
        unix: non_neg_integer(),      # unix seconds: sessionInit.seq (newSessionInit, 474-481)
        keypair: (-> {pub, priv})     # optional, defaults to Ygg.Crypto.Box.keypair/0 (newBoxKeys)
      }
  Wire (`session.go:19-25`, 483-567, 299-364):
  * Init (type 1) / Ack (type 2), 193 bytes: `type ‖ ephPub(32) ‖ box(nonce 0)` over
    `sig(64) ‖ current(32) ‖ next(32) ‖ BE64 keySeq ‖ BE64 seq`, box key = X25519(eph, toBox(to))
    and `sig = ed25519([group ‖] ephPub ‖ current ‖ next ‖ keySeq ‖ seq)` (`edSign`, crypto.go:47-55).
  * Traffic (type 3): `3 ‖ uvarint localKeySeq ‖ uvarint remoteKeySeq ‖ uvarint nonce ‖
    box(0^16 ‖ BE64 nonce, sendShared)` over `nextPub ‖ payload`; overhead 52..79 bytes.
  Shared keys are kept as their HSalsa20 subkeys (`Ygg.Crypto.Box.subkey/1`): ironwood nonces
  start with 16 zero bytes, so the XSalsa20 subkey is fixed per shared key. `box.Precompute` on a
  low-order point gives `HSalsa20(0^32, 0^16)` in Go (the DH output is all zeros and it carries
  on); `shared/2` reproduces that instead of failing.
  Kept from Go on purpose: `newSession` sets `seq = init.seq - 1` (wrapping, 229); an Init/Ack
  with `seq <= info.seq` is ignored (263-281), so two handshakes in one second collapse into one;
  `_handleUpdate` advances our keys and keeps `sendNonce` (284-297); `doSend` advances the nonce
  first and rotates on its uint64 overflow (299-332); `doRecv` (334-450) has exactly the three accepted
  (remoteKeySeq, localKeySeq) cases with strictly increasing, per-key nonces and no window, a
  rotation at most once per minute (`time.Since(rotated) > time.Minute`, 383, 409), and re-Init on
  an unknown key-seq pair or a failed open (425-430, 441-449).
  """
  import Bitwise
  alias Ygg.Crypto.{Box, Ed2Curve, Salsa}
  alias Ygg.{Identity, Wire}
  @compile {:inline, [shared_sub: 2, reset_timer: 2, u64: 1]}
  @type_init 1
  @type_ack 2
  @type_traffic 3
  @timeout_ms 60_000
  @rotate_ms 60_000
  @u64 0xFFFF_FFFF_FFFF_FFFF
  @overhead_min 1 + 1 + 1 + 1 + 16 + 32
  @overhead @overhead_min + 9 + 9 + 9
  @init_size 1 + 32 + 16 + 64 + 32 + 32 + 8 + 8
  @derive {Inspect,
           except: [
             :recv_priv,
             :send_priv,
             :next_priv,
             :recv_sub,
             :send_sub,
             :next_send_sub,
             :next_recv_sub
           ]}
  defstruct [
    :ed,
    :seq,
    :current,
    :next,
    :recv_pub,
    :recv_priv,
    :recv_sub,
    :send_pub,
    :send_priv,
    :send_sub,
    :next_pub,
    :next_priv,
    :next_send_sub,
    :next_recv_sub,
    :since,
    :rotated,
    :expires_at,
    remote_key_seq: 0,
    local_key_seq: 0,
    recv_nonce: 0,
    send_nonce: 0,
    next_send_nonce: 0,
    next_recv_nonce: 0,
    rx: 0,
    tx: 0
  ]
  @type key :: <<_::256>>
  @type keypair :: {key, key}
  @type init :: %{current: key, next: key, key_seq: non_neg_integer(), seq: non_neg_integer()}
  @type t :: %__MODULE__{}
  @type env :: %{
          required(:identity) => Identity.t(),
          required(:group) => binary(),
          required(:now) => integer(),
          required(:unix) => non_neg_integer(),
          optional(:keypair) => (-> keypair)
        }
  def overhead, do: @overhead
  def overhead_min, do: @overhead_min
  def init_size, do: @init_size
  def timeout_ms, do: @timeout_ms
  @doc "`getShared` as a subkey: `HSalsa20(box.Precompute(pub, priv), 0^16)` (Go semantics on low-order points)."
  @spec shared_sub(key, key) :: key
  def shared_sub(pub, priv), do: Box.subkey(shared(pub, priv))
  @doc "`box.Precompute`: all-zero DH output gives `HSalsa20(0^32, 0^16)` like Go."
  @spec shared(key, key) :: key
  def shared(pub, priv) do
    case Box.precompute(pub, priv) do
      {:ok, shared} -> shared
      :error -> Salsa.hsalsa20(<<0::256>>, <<0::128>>)
    end
  end
  defp keypair(env), do: Map.get(env, :keypair, &Box.keypair/0).()
  @doc "`newSessionInit` (474-481): `seq` = unix seconds."
  @spec new_init(key, key, non_neg_integer(), non_neg_integer()) :: init
  def new_init(current, next, key_seq, unix),
    do: %{current: current, next: next, key_seq: key_seq, seq: unix}
  @doc """
  `sessionInit.encrypt` (483-520) / `sessionAck.encrypt` (561-567): 193 bytes. `eph` is the
  ephemeral X25519 pair (`newBoxKeys` inside encrypt), injectable for vectors.
  """
  @spec encode_handshake(1 | 2, init, Identity.t(), key, binary(), keypair) ::
          {:ok, binary()} | :error
  def encode_handshake(
        type,
        init,
        %Identity{} = id,
        to_ed,
        group,
        {eph_pub, eph_priv} \\ Box.keypair()
      )
      when type in [@type_init, @type_ack] do
    with {:ok, to_box} <- Ed2Curve.pub(to_ed) do
      body = <<init.current::binary-32, init.next::binary-32, init.key_seq::64, init.seq::64>>
      sig = Identity.sign(id, [group, eph_pub | body])
      boxed = Box.seal(shared(to_box, eph_priv), Box.nonce(0), [sig, body])
      {:ok, <<type, eph_pub::binary-32, boxed::binary>>}
    end
  end
  @doc """
  `sessionInit.decrypt` (522-557), used for both Init and Ack: length must be 193, box opened
  with our X25519 key (`secretBox`), signature checked against the sender's ed25519 key with the
  group preimage. Returns the type byte too (the caller dispatches on it, as `handleData`).
  """
  @spec decode_handshake(binary(), key, key, binary()) :: {:ok, 1 | 2, init} | :error
  def decode_handshake(
        <<type, eph_pub::binary-32, boxed::binary>> = data,
        my_x_priv,
        from_ed,
        group
      )
      when byte_size(data) == @init_size do
    with {:ok, <<sig::binary-64, body::binary-80>>} <-
           Box.open(shared(eph_pub, my_x_priv), Box.nonce(0), boxed),
         true <- Identity.verify(from_ed, [group, eph_pub | body], sig) do
      <<current::binary-32, next::binary-32, key_seq::64, seq::64>> = body
      {:ok, type, %{current: current, next: next, key_seq: key_seq, seq: seq}}
    else
      _ -> :error
    end
  end
  def decode_handshake(_data, _my_x_priv, _from_ed, _group), do: :error
  @doc "Traffic packet: header, then `box(nonce, send_sub)` over `next_pub ‖ msg`."
  @spec encode_traffic(non_neg_integer(), non_neg_integer(), non_neg_integer(), key, key, iodata) ::
          binary()
  def encode_traffic(local_key_seq, remote_key_seq, nonce, send_sub, next_pub, msg) do
    boxed = Box.seal_with_subkey(send_sub, <<nonce::64>>, [next_pub, msg])
    IO.iodata_to_binary([
      @type_traffic,
      Wire.encode_uvarint(local_key_seq),
      Wire.encode_uvarint(remote_key_seq),
      Wire.encode_uvarint(nonce),
      boxed
    ])
  end
  @doc "Parse a traffic header: `{:ok, their_local_key_seq, their_view_of_ours, nonce, boxed}`."
  @spec decode_traffic(binary()) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer(), binary()} | :error
  def decode_traffic(<<@type_traffic, rest::binary>> = msg)
      when byte_size(msg) >= @overhead_min do
    with {:ok, rks, rest} <- Wire.decode_uvarint(rest),
         {:ok, lks, rest} <- Wire.decode_uvarint(rest),
         {:ok, nonce, boxed} <- Wire.decode_uvarint(rest),
         do: {:ok, rks, lks, nonce, boxed}
  end
  def decode_traffic(_msg), do: :error
  @doc """
  `newSession` (227-239): remote `current`/`next` from the Init/Ack, three fresh pairs of ours
  (`{recv, send, next}`, injectable), `seq = init.seq - 1` wrapping, `_fixShared(0, 0)` and the
  1-minute timer (`_resetTimer`, called by `_newSession`).
  """
  @spec new(key, key, key, non_neg_integer(), integer(), {keypair, keypair, keypair} | nil) :: t()
  def new(ed, current, next, seq, now, keys \\ nil) do
    {{rp, rk}, {sp, sk}, {np, nk}} =
      keys || {Box.keypair(), Box.keypair(), Box.keypair()}
    %__MODULE__{
      ed: ed,
      seq: u64(seq - 1),
      current: current,
      next: next,
      recv_pub: rp,
      recv_priv: rk,
      send_pub: sp,
      send_priv: sk,
      next_pub: np,
      next_priv: nk,
      since: now
    }
    |> fix_shared(0, 0)
    |> reset_timer(now)
  end
  @doc """
  `_sessionForInit` with a pending buffer (61-76): our Init already told the remote
  `current`/`next`, so they become our send/next keys.
  """
  @spec adopt(t(), keypair, keypair) :: t()
  def adopt(s, {cp, ck}, {np, nk}),
    do: fix_shared(%{s | send_pub: cp, send_priv: ck, next_pub: np, next_priv: nk}, 0, 0)
  @doc "`_fixShared` (241-248)."
  @spec fix_shared(t(), non_neg_integer(), non_neg_integer()) :: t()
  def fix_shared(s, recv_nonce, send_nonce) do
    %{
      s
      | recv_sub: shared_sub(s.current, s.recv_priv),
        send_sub: shared_sub(s.current, s.send_priv),
        next_send_sub: shared_sub(s.next, s.send_priv),
        next_recv_sub: shared_sub(s.next, s.recv_priv),
        next_send_nonce: 0,
        next_recv_nonce: 0,
        recv_nonce: recv_nonce,
        send_nonce: send_nonce
    }
  end
  defp reset_timer(s, now), do: %{s | expires_at: now + @timeout_ms}
  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: at}, now), do: now >= at
  @doc "`handleInit` (263-272): ignore `seq <= info.seq`, else update and answer with an Ack."
  @spec handle_init(t(), init, env) :: {t(), binary() | nil}
  def handle_init(s, %{seq: seq}, _env) when seq <= s.seq, do: {s, nil}
  def handle_init(s, init, env) do
    s = handle_update(s, init, env)
    {s, handshake(s, @type_ack, env)}
  end
  @doc "`handleAck` (274-281): like `handle_init/3` without the answer."
  @spec handle_ack(t(), init, env) :: t()
  def handle_ack(s, %{seq: seq}, _env) when seq <= s.seq, do: s
  def handle_ack(s, init, env), do: handle_update(s, init, env)
  defp handle_update(s, init, env) do
    {np, nk} = keypair(env)
    %{
      s
      | current: init.current,
        next: init.next,
        seq: init.seq,
        remote_key_seq: init.key_seq,
        recv_pub: s.send_pub,
        recv_priv: s.send_priv,
        send_pub: s.next_pub,
        send_priv: s.next_priv,
        next_pub: np,
        next_priv: nk,
        local_key_seq: u64(s.local_key_seq + 1)
    }
    |> fix_shared(0, s.send_nonce)
    |> reset_timer(env.now)
  end
  @doc "Init (`_sendInit`, 452-455) or Ack (`_sendAck`, 457-461) for our current keys."
  @spec handshake(t(), 1 | 2, env) :: binary() | nil
  def handshake(s, type, env) do
    init = new_init(s.send_pub, s.next_pub, s.local_key_seq, env.unix)
    case encode_handshake(type, init, env.identity, s.ed, env.group, keypair(env)) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end
  @doc "`doSend` (299-332): advance the nonce (rotate our keys on overflow), seal, count `tx`."
  @spec send(t(), iodata, env) :: {t(), binary()}
  def send(s, msg, env) do
    s =
      case u64(s.send_nonce + 1) do
        0 ->
          {np, nk} = keypair(env)
          %{
            s
            | recv_pub: s.send_pub,
              recv_priv: s.send_priv,
              send_pub: s.next_pub,
              send_priv: s.next_priv,
              next_pub: np,
              next_priv: nk,
              local_key_seq: u64(s.local_key_seq + 1)
          }
          |> fix_shared(0, 0)
        n ->
          %{s | send_nonce: n}
      end
    bin =
      encode_traffic(s.local_key_seq, s.remote_key_seq, s.send_nonce, s.send_sub, s.next_pub, msg)
    {reset_timer(%{s | tx: s.tx + IO.iodata_length(msg)}, env.now), bin}
  end
  @doc """
  `doRecv` (334-450). Results: `{:deliver, s, payload}`; `{:reinit, s, init_bytes, reason}`
  (`:key_seq` for an unknown key-seq pair, `:decrypt` for a failed open); `{:drop, s, reason}`
  (`:malformed`, `:old_nonce`).
  """
  @spec recv(t(), binary(), env) ::
          {:deliver, t(), binary()}
          | {:reinit, t(), binary() | nil, :key_seq | :decrypt}
          | {:drop, t(), :malformed | :old_nonce}
  def recv(s, msg, env) do
    case decode_traffic(msg) do
      {:ok, rks, lks, nonce, boxed} -> recv_case(s, rks, lks, nonce, boxed, env)
      :error -> {:drop, s, :malformed}
    end
  end
  defp recv_case(s, rks, lks, nonce, boxed, env) do
    from_current = rks == s.remote_key_seq
    from_next = rks == u64(s.remote_key_seq + 1)
    to_recv = u64(lks + 1) == s.local_key_seq
    to_send = lks == s.local_key_seq
    cond do
      from_current and to_recv ->
        if s.recv_nonce < nonce,
          do: open(s, boxed, nonce, s.recv_sub, :recv, env),
          else: {:drop, s, :old_nonce}
      from_next and to_send ->
        if s.next_send_nonce < nonce,
          do: open(s, boxed, nonce, s.next_send_sub, :next_send, env),
          else: {:drop, s, :old_nonce}
      from_next and to_recv ->
        if s.next_recv_nonce < nonce,
          do: open(s, boxed, nonce, s.next_recv_sub, :next_recv, env),
          else: {:drop, s, :old_nonce}
      true ->
        {:reinit, s, handshake(s, @type_init, env), :key_seq}
    end
  end
  defp open(s, boxed, nonce, sub, which, env) do
    case Box.open_with_subkey(sub, <<nonce::64>>, boxed) do
      {:ok, <<inner::binary-32, payload::binary>>} ->
        s = on_success(s, which, nonce, inner, env)
        {:deliver, reset_timer(%{s | rx: s.rx + byte_size(payload)}, env.now), payload}
      _ ->
        {:reinit, s, handshake(s, @type_init, env), :decrypt}
    end
  end
  defp on_success(s, :recv, nonce, _inner, _env), do: %{s | recv_nonce: nonce}
  defp on_success(s, which, nonce, inner, env) do
    s =
      if which == :next_send,
        do: %{s | next_send_nonce: nonce},
        else: %{s | next_recv_nonce: nonce}
    if s.rotated == nil or env.now - s.rotated > @rotate_ms do
      {np, nk} = keypair(env)
      %{
        s
        | current: s.next,
          next: inner,
          remote_key_seq: u64(s.remote_key_seq + 1),
          recv_pub: s.send_pub,
          recv_priv: s.send_priv,
          send_pub: s.next_pub,
          send_priv: s.next_priv,
          local_key_seq: u64(s.local_key_seq + 1),
          next_pub: np,
          next_priv: nk,
          rotated: env.now
      }
      |> fix_shared(nonce, 0)
    else
      s
    end
  end
  defp u64(n), do: n &&& @u64
end