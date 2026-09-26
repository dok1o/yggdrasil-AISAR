defmodule UAddrChkSync do
  @dht_router_ignorelist MapSet.new([
                           <<87, 98, 162, 88>>,
                           <<185, 157, 221, 247>>,
                           <<167, 86, 102, 121>>,
                           <<67, 215, 246, 10>>,
                           <<82, 221, 103, 244>>,
                           <<212, 129, 33, 59>>
                         ])
  @type octet :: <<_::8>>
  @type ipv4 :: {octet(), octet(), octet(), octet()}
  @typedoc "IPv4 node: 4 bytes for IPv4 address, 2 bytes for port as <<a,b,c,d,port::16>>"
  @type nodev4 :: <<_::48>>
  @type source :: nodev4()
  def valid_ip?({a, b, c, d} = _source_ipv4), do: valid_public_ip?(a, b, c, d)
  def valid_ip?(_malformed), do: false
  def good?(<<_ipv4::binary-4, 0x0000::16>>), do: false
  def good?(<<a, b, c, d, _port::16>> = unpacked_nodev4) do
    valid_public_ip?(a, b, c, d) and
      not known_router?(unpacked_nodev4) and
      not own_ip?(unpacked_nodev4)
  end
  defp known_router?(<<ipv4::binary-4, _port::16>>) do
    MapSet.member?(@dht_router_ignorelist, ipv4)
  end
  defp own_ip?(<<ipv4::binary-4, _port::16>>) do
    :persistent_term.get({KeyStorageSync, :own_ip}, nil) == ipv4
  end
  defp reserved_ipv4_reason(0, _b, _c, _d), do: :current_network
  defp reserved_ipv4_reason(10, _b, _c, _d), do: :private
  defp reserved_ipv4_reason(100, b, _c, _d) when b in 64..127, do: :carrier_grade_nat
  defp reserved_ipv4_reason(127, _b, _c, _d), do: :loopback
  defp reserved_ipv4_reason(169, 254, _c, _d), do: :link_local
  defp reserved_ipv4_reason(172, b, _c, _d) when b in 16..31, do: :private
  defp reserved_ipv4_reason(192, 0, _c, _d), do: :several_purposes_and_test_net_1
  defp reserved_ipv4_reason(192, 31, 196, _d), do: :as112_project
  defp reserved_ipv4_reason(192, 52, 193, _d), do: :automatic_multicast_tunneling
  defp reserved_ipv4_reason(192, 88, 99, _d), do: :six_to_four_relay
  defp reserved_ipv4_reason(192, 168, _c, _d), do: :private
  defp reserved_ipv4_reason(192, 175, 48, _d), do: :as112_project
  defp reserved_ipv4_reason(198, b, _c, _d) when b in 18..19, do: :benchmarking
  defp reserved_ipv4_reason(198, 51, 100, _d), do: :test_net_2
  defp reserved_ipv4_reason(203, 0, 113, _d), do: :test_net_3
  defp reserved_ipv4_reason(a, _b, _c, _d) when a in 224..239, do: :multicast
  defp reserved_ipv4_reason(a, _b, _c, _d) when a >= 240, do: :reserved
  defp reserved_ipv4_reason(_a, _b, _c, _d), do: :viable_public
  defp valid_public_ip?(a, b, c, d) do
    reserved_ipv4_reason(a, b, c, d) == :viable_public
  end
end