defmodule TelemetrySync do
  def nat_chk_telemetry(packet, ipv4, port) do
    :telemetry.execute([:gens, :udp, :packet], %{size: byte_size(packet)}, %{
      packet: packet,
      ip: ipv4,
      port: port
    })
  end
end