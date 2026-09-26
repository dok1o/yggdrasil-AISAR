defmodule Stop do
  def app_stop(reason), do: {:stop, reason}
end