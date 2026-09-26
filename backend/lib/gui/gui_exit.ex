defmodule GenS.GUIExit do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: :gui_exit)
  def init(:ok), do: {:ok, %{}}
  def shutdown(reason), do: GenServer.cast(:gui_exit, {:shutdown, reason})
  def handle_cast({:shutdown, _reason}, st) do
    :init.stop()
    {:noreply, st}
  end
end