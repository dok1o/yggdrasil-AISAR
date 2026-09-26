defmodule Conn.WaiterQueue do
  alias Conn.Buffer
  @compile {:inline, [satisfy_while: 2]}
  def new, do: :queue.new()
  def empty?(queue), do: :queue.is_empty(queue)
  def satisfy_while(queue, buffer), do: do_satisfy_while(queue, buffer)
  def reply_all(queue, reply) do
    :queue.fold(
      fn {from, _bytes, ref}, _ ->
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, reply)
      end,
      nil,
      queue
    )
  end
  def enqueue(queue, from, request) do
    {pid, _} = from
    ref = Process.monitor(pid)
    :queue.in({from, request, ref}, queue)
  end
  def remove_by_ref(queue, ref) do
    :queue.filter(fn {_, _, r} -> r != ref end, queue)
  end
  defp reply_and_demonitor({from, _request, ref}, reply) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, reply)
  end
  defp do_satisfy_while(queue, buffer) do
    case :queue.out(queue) do
      {:empty, _rest_queue} ->
        {queue, buffer}
      {{:value, {_from, request, _ref} = waiter}, rest_queue} ->
        case Buffer.try_satisfy(buffer, request) do
          {:ok, data, new_buffer} ->
            reply_and_demonitor(waiter, {:ok, data})
            do_satisfy_while(rest_queue, new_buffer)
          {:error, reason} ->
            reply_and_demonitor(waiter, {:error, reason})
            do_satisfy_while(rest_queue, buffer)
          :insufficient ->
            new_queue = :queue.in_r(waiter, rest_queue)
            {new_queue, buffer}
        end
    end
  end
end