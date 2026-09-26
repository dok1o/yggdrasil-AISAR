defmodule Ygg.PacketQueue do
  @moduledoc """
  Per-peer send queue for the frames ironwood queues instead of writing directly (PathLookup,
  PathNotify, PathBroken, Traffic; `bloomfilter.go:328`, `peers.go:389-446`); SigReq/SigRes/
  Announce/Bloom bypass it (`sendDirect`). A packet is queued only while the writer
  is busy; after a push the queue is trimmed until its byte total is at most the cap
  (`for p.queue.size > peerMaxMessageSize { drop }`, `peers.go:444-446`), the cap being
  Yggdrasil's `peerMaxMessageSize` = 131070 (`reference/yggdrasil-go/src/core/core.go:102`).
  Simplification (allowed by PLAN_STAGE2 §4): Go's `packetQueue` (`packetqueue.go`) is a two-level
  heap, per destination and per source, that pops the globally oldest head and drops the oldest
  packet of the largest source of the largest destination, for fairness between flows under
  overload. Here it is one FIFO per peer that drops the oldest packet. On the wire this is
  invisible: frame bytes are identical, the order of any single flow is preserved either way,
  and only the choice of which packet is lost during overload differs, which the protocol
  already tolerates (lossy datagrams, lookups/notifies are retried).
  Each packet is accounted with the size given to `push/3`: `Ygg.Peer` pushes full wire frames
  with their body size (declared length minus the type byte), which is Go's `packet.size()`
  (`packetqueue.go:93`, summed by `peers.go:444`), so the cap is byte-exact and a frame of the
  maximum declared length still fits. `push/2` measures the iodata itself. A single packet
  larger than the cap is dropped on push and leaves the queue untouched (Go's writer would drop
  it anyway, `peers.go:202-205`).
  """
  @peer_max_message_size 131_070
  defstruct q: :queue.new(), size: 0, bytes: 0, cap: @peer_max_message_size
  @type t :: %__MODULE__{
          q: :queue.queue({iodata(), non_neg_integer()}),
          size: non_neg_integer(),
          bytes: non_neg_integer(),
          cap: non_neg_integer()
        }
  @spec new(non_neg_integer()) :: t()
  def new(cap_bytes \\ @peer_max_message_size) when is_integer(cap_bytes) and cap_bytes >= 0,
    do: %__MODULE__{cap: cap_bytes}
  @doc """
  Appends `pkt` counted as `len` bytes (default: its iodata length); returns the queue and how
  many packets were dropped to stay within the cap.
  """
  @spec push(t(), iodata(), non_neg_integer()) :: {t(), non_neg_integer()}
  def push(q, pkt, len \\ nil)
  def push(q, pkt, nil), do: push(q, pkt, IO.iodata_length(pkt))
  def push(%__MODULE__{cap: cap} = q, pkt, len) when is_integer(len) and len >= 0 do
    if len > cap,
      do: {q, 1},
      else: trim(%{q | q: :queue.in({pkt, len}, q.q), size: q.size + 1, bytes: q.bytes + len}, 0)
  end
  @spec pop(t()) :: {:ok, iodata(), t()} | :empty
  def pop(%__MODULE__{q: inner} = q) do
    case :queue.out(inner) do
      {{:value, {pkt, len}}, inner} ->
        {:ok, pkt, %{q | q: inner, size: q.size - 1, bytes: q.bytes - len}}
      {:empty, _} ->
        :empty
    end
  end
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: n}), do: n
  @spec bytes(t()) :: non_neg_integer()
  def bytes(%__MODULE__{bytes: b}), do: b
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: n}), do: n == 0
  defp trim(%{bytes: b, cap: cap} = q, dropped) when b <= cap, do: {q, dropped}
  defp trim(q, dropped) do
    {:ok, _pkt, q} = pop(q)
    trim(q, dropped + 1)
  end
end