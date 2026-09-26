defmodule UDPChk do
  def ready?() do
    match?([{_pid, _socket}], Registry.lookup(Reg.UDPShardRegistry, {:shard, 1}))
  end
  def select_random_shard() do
    Registry.select(Reg.UDPShardRegistry, [
      {
        {{:shard, :_}, :"$1", :_},
        [],
        [:"$1"]
      }
    ])
    |> case do
      [] -> nil
      pids -> Enum.random(pids)
    end
  end
end