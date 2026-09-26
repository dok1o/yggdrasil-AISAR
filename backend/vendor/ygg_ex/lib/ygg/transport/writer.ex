defmodule Ygg.Transport.Writer do
  @moduledoc """
  Write side of one link: ironwood's `peerWriter` actor (`network/peers.go:180-226`), which
  writes frames to the connection in its own goroutine so that the reader (`peer.handler`,
  :228-266) never waits for a write. One per `Ygg.Peer`, started with
  `Ygg.Transport.start_writer/1` and linked to it.
  It calls `send/2` of the carrier module (`:gen_tcp.send/2` or `:ssl.send/2`) directly on the
  socket owned by `Ygg.Transport.Conn`; both allow any process to send (`prim_inet:send/3`
  monitors the port, `:ssl.send/2` goes through the connection's `tls_sender` process), so
  the conn keeps reading while a write blocks. Each written frame adds its length to the
  conn's TX `:counters` slot (the `linkConn.tx` atomic, `reference/yggdrasil-go/src/core/link.go:787-795`) and is
  acknowledged to the owner with `{:written, type, t}` (`t` = `System.monotonic_time(:nanosecond)`
  right after the carrier accepted the bytes), which drives the owner's packet queue (the
  `w.Act(nil, p.pop)` of `_write`, :193-197) and the SigReq send time (`sendSigReq` `done`,
  :318-322).
  A failed or timed out send (`send_timeout` of the carrier) stops the writer with
  `{:shutdown, {:send, reason}}`; the link carries that exit to the owner, which dies with it and
  takes the conn down (Go: the write error surfaces as the read loop failing on the closed
  connection).
  """
  use GenServer, restart: :temporary
  @tx 2
  defstruct [:mod, :sock, :counters, :owner]
  @doc "Starts a writer linked to the caller; `owner` gets the `{:written, type, t}` acks."
  @spec start_link(module(), term(), :counters.counters_ref(), pid()) :: GenServer.on_start()
  def start_link(mod, sock, counters, owner),
    do:
      GenServer.start_link(__MODULE__, %__MODULE__{
        mod: mod,
        sock: sock,
        counters: counters,
        owner: owner
      })
  @doc "Hands one full wire frame of type byte `type` to the writer (never blocks)."
  @spec write(pid(), iodata(), byte()) :: :ok
  def write(pid, frame, type) do
    send(pid, {:write, frame, type})
    :ok
  end
  @impl true
  def init(st), do: {:ok, st}
  @impl true
  def handle_info({:write, frame, type}, %{mod: mod, sock: sock} = st) do
    case mod.send(sock, frame) do
      :ok ->
        :counters.add(st.counters, @tx, IO.iodata_length(frame))
        send(st.owner, {:written, type, System.monotonic_time(:nanosecond)})
        {:noreply, st}
      {:error, reason} ->
        {:stop, {:shutdown, {:send, reason}}, st}
    end
  end
  def handle_info(_msg, st), do: {:noreply, st}
end