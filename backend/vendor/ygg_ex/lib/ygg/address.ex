defmodule Ygg.Address do
  @moduledoc """
  IPv6 address / subnet derived from an ed25519 public key.
  Ports `reference/yggdrasil-go/src/address/address.go` completely: `GetPrefix` (0x02), `AddrForKey`, `SubnetForKey`,
  `Address.IsValid`, `Subnet.IsValid`, `Address.GetKey`, `Subnet.GetKey`.
  Layout (address.go:51-94): prefix byte, then one byte = number of leading 1 bits in the
  bitwise inverse of the key, then the inverse with those 1s and the first 0 stripped,
  copied whole bytes only, truncated to 128 bits total (zero padded when shorter).
  Subnet = first 8 bytes of the address with the low bit of the prefix set (0x03).
  """
  import Bitwise
  @compile {:inline, [addr_for_key: 1, subnet_for_key: 1, addr_valid?: 1, subnet_valid?: 1]}
  @prefix 0x02
  @addr_body 14
  @subnet_body 6
  @key_bits 256
  @type addr :: <<_::128>>
  @type subnet :: <<_::64>>
  @type key :: <<_::256>>
  def prefix, do: @prefix
  @spec addr_for_key(key()) :: addr() | nil
  def addr_for_key(<<key::binary-size(32)>>) do
    inv = :crypto.exor(key, :binary.copy(<<0xFF>>, 32))
    ones = leading_ones(inv, 0)
    body = strip(inv, ones)
    <<@prefix, ones &&& 0xFF, fit(body, @addr_body)::binary>>
  end
  def addr_for_key(_key), do: nil
  @spec subnet_for_key(key()) :: subnet() | nil
  def subnet_for_key(<<_::binary-size(32)>> = key) do
    <<p, ones, body::binary-size(@subnet_body), _::binary>> = addr_for_key(key)
    <<p ||| 0x01, ones, body::binary>>
  end
  def subnet_for_key(_key), do: nil
  @spec addr_valid?(binary()) :: boolean()
  def addr_valid?(<<@prefix, _::binary-size(15)>>), do: true
  def addr_valid?(_addr), do: false
  @spec subnet_valid?(binary()) :: boolean()
  def subnet_valid?(<<0x03, _::binary-size(7)>>), do: true
  def subnet_valid?(_subnet), do: false
  @doc "Partial public key recovered from an address (address.go:116-142); unknown bits are 1."
  @spec addr_get_key(addr()) :: key()
  def addr_get_key(<<_prefix, ones, tail::bitstring>>) do
    lead = <<(1 <<< ones) - 1::size(ones), 0::1>>
    bits = fit_bits(<<lead::bitstring, tail::bitstring>>, @key_bits)
    :crypto.exor(bits, :binary.copy(<<0xFF>>, 32))
  end
  @spec subnet_get_key(subnet()) :: key()
  def subnet_get_key(<<_::binary-size(8)>> = subnet),
    do: addr_get_key(<<subnet::binary, 0::size(64)>>)
  @spec format(addr() | subnet()) :: String.t()
  def format(<<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>),
    do: List.to_string(:inet.ntoa({a, b, c, d, e, f, g, h}))
  def format(<<_::binary-size(8)>> = subnet), do: format(<<subnet::binary, 0::64>>) <> "/64"
  defp leading_ones(<<1::1, rest::bitstring>>, n), do: leading_ones(rest, n + 1)
  defp leading_ones(_bits, n), do: n
  defp strip(_inv, @key_bits), do: <<>>
  defp strip(inv, ones) do
    <<_::size(ones), _zero::1, rest::bitstring>> = inv
    whole = div(bit_size(rest), 8) * 8
    <<body::bitstring-size(whole), _::bitstring>> = rest
    body
  end
  defp fit(body, n) when byte_size(body) >= n, do: binary_part(body, 0, n)
  defp fit(body, n), do: <<body::binary, 0::size((n - byte_size(body)) * 8)>>
  defp fit_bits(bits, n) when bit_size(bits) >= n do
    <<head::bitstring-size(n), _::bitstring>> = bits
    head
  end
  defp fit_bits(bits, n), do: <<bits::bitstring, 0::size(n - bit_size(bits))>>
end