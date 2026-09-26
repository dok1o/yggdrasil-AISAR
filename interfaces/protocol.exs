# /interfaces/protocol.exs
defmodule PFProtocol do
  @wnd_10min 10 * 60

  def generate_salt_mask(window_seconds \\ @wnd_10min) do
    window_index = div(System.system_time(:second), window_seconds)

    <<salt::binary-size(20), _rest::binary>> =
      :crypto.hash(:sha256, Integer.to_string(window_index))

    salt
  end
end
