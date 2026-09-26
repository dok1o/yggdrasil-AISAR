defmodule PFMaskSync do
  import Bitwise
  @type target :: <<_::160>>
  @type fid :: target()
  @prefix_bits 8
  @checksum_bits 16
  @middle_bits 128
  @affix_bits 8
  @fold_bitsize 16
  @in_byte_rev Map.new(0..255, fn byte ->
                 <<b7::1, b6::1, b5::1, b4::1, b3::1, b2::1, b1::1, b0::1>> = <<byte>>
                 {byte,
                  <<b0::1, b1::1, b2::1, b3::1, b4::1, b5::1, b6::1, b7::1>>
                  |> :binary.decode_unsigned()}
               end)
  def generate_fid(target) do
    reversed = reverse_bits(target)
    {prefix, middle, affix} = extract(reversed)
    checksum = xor_checksum(middle)
    construct(prefix, checksum, middle, affix)
  end
  def valid_fid?(
        <<_prefix::size(@prefix_bits), checksum::size(@checksum_bits),
          middle::bits-size(@middle_bits), _affix::size(@affix_bits)>>
      ) do
    xor_checksum(middle) == checksum
  end
  def valid_fid?(_node_id), do: false
  defp extract(
         <<prefix::size(@prefix_bits), _discard::size(@checksum_bits),
           middle::bits-size(@middle_bits), affix::size(@affix_bits)>>
       ) do
    {prefix, middle, affix}
  end
  defp construct(prefix, checksum, middle, affix) do
    <<
      prefix::size(@prefix_bits),
      checksum::size(@checksum_bits),
      middle::bits-size(@middle_bits),
      affix::size(@affix_bits)
    >>
  end
  defp xor_checksum(bits), do: band(fold(bits, 0), (1 <<< @checksum_bits) - 1)
  defp fold(<<ch::size(@fold_bitsize), rest::bits>>, acc), do: fold(rest, bxor(acc, ch))
  defp fold(<<>>, acc), do: acc
  defp reverse_bits(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map(&Map.get(@in_byte_rev, &1))
    |> :binary.list_to_bin()
  end
end