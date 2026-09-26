defmodule Ygg.Transport.WaiterQueue do
  @moduledoc """
  FIFO of pending receive requests inside `Ygg.Transport.Conn`.
  Adapted from `context/!_conn_waiter_queue.ex`. Differences: no monitor per waiter (the
  conn keeps one monitor on its reader instead, two monitor calls per frame were waste), and
  `from` may be a real `GenServer.call` tuple or a synthetic `{pid, ref}` for the asynchronous
  `recv_frame`; `GenServer.reply/2` delivers `{ref, result}` to `pid` in both cases.
  A `{:error, _}` from `Ygg.Transport.Buffer` is fatal for the link, so `satisfy_while/2`
  stops there and reports it instead of dropping the buffer like the original did.
  """
  alias Ygg.Transport.Buffer
  @compile {:inline, [satisfy_while: 2, enqueue: 3, empty?: 1]}
  @type from :: GenServer.from()
  @type request :: pos_integer() | {:frame, pos_integer()}
  @type t :: :queue.queue({from(), request()})
  def new, do: :queue.new()
  def empty?(queue), do: :queue.is_empty(queue)
  @spec enqueue(t(), from(), request()) :: t()
  def enqueue(queue, from, request), do: :queue.in({from, request}, queue)
  @doc "Answers every waiter with `reply` (used when the conn stops)."
  def reply_all(queue, reply) do
    :queue.fold(fn {from, _req}, _ -> GenServer.reply(from, reply) end, nil, queue)
    :ok
  end
  @doc "Serves waiters in order while the buffer has enough data."
  @spec satisfy_while(t(), binary()) :: {:ok, t(), binary()} | {:error, term(), t(), binary()}
  def satisfy_while(queue, buffer) do
    case :queue.out(queue) do
      {:empty, _rest} ->
        {:ok, queue, buffer}
      {{:value, {from, request}}, rest} ->
        case Buffer.try_satisfy(buffer, request) do
          {:ok, data, new_buffer} ->
            GenServer.reply(from, {:ok, data})
            satisfy_while(rest, new_buffer)
          :insufficient ->
            {:ok, queue, buffer}
          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            {:error, reason, rest, buffer}
        end
    end
  end
end