defmodule GenS.IHWorkerRouter do
  use GenServer
  def start_link(o \\ []), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  @compile {:inline, []}
  @type target :: <<_::160>>
  @type ih :: target()
  @type nodev4 :: <<_::48>>
  @type peer :: nodev4()
  @type source :: nodev4()
  @type peer_type :: :announce | :pex | :values
  @ext_ets_launched_ihs :launched_ihs
  @ext_ets_fetched_ihs :fetched_ihs
  def find(_ih, <<>>, _type, _source), do: :noop
  def find(ih, raw_peers, source, type) do
    GenServer.cast(__MODULE__, {:find, ih, raw_peers, source, type})
  end
  defp fetched?(ih), do: TryETS.member?(@ext_ets_fetched_ihs, ih)
  def init(_opts) do
    st = %{}
    {:ok, st}
  end
  def handle_cast({:find, ih, raw_peers, type, source}, st) do
    peers = UnpackSync.peers(raw_peers)
    send_or_record(ih, peers, source, type)
    {:noreply, st}
  end
  defp send_or_record(_ih, [], _source, _type), do: :noop
  defp send_or_record(ih, peers, source, type) do
    unless fetched?(ih) do
      case TryETS.lookup(@ext_ets_launched_ihs, ih) do
        [{^ih, pid, _ts}] when is_pid(pid) -> send(pid, {:new_peers, peers, type})
        [] -> GenS.PeerManager.record_unv_peers(ih, peers, source)
      end
    end
  end
end