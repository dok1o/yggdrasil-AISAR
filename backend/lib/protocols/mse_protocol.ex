defmodule MSESync do
  @moduledoc "Message Stream Encryption (BEP 8)"
  @p_hex "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A63A36210000000000090563"
  @p Base.decode16!(@p_hex)
     |> :binary.decode_unsigned()
  @g 2
  @dh_len 96
  @max_pad 512
  @discard @max_pad * 2
  def generate_keypair do
    x =
      :crypto.strong_rand_bytes(20)
      |> :binary.decode_unsigned()
    y =
      :crypto.mod_pow(@g, x, @p)
      |> pad_left(@dh_len)
    {x, y}
  end
  def compute_secret(peer_y, my_x) do
    peer_y_int = :binary.decode_unsigned(peer_y)
    :crypto.mod_pow(peer_y_int, my_x, @p)
    |> pad_left(@dh_len)
  end
  def init_crypto(secret, skey, role) do
    {enc_prefix, dec_prefix} =
      case role do
        :initiator -> {"keyA", "keyB"}
        :responder -> {"keyB", "keyA"}
      end
    enc_key = :crypto.hash(:sha, [enc_prefix, secret, skey])
    dec_key = :crypto.hash(:sha, [dec_prefix, secret, skey])
    enc_state =
      RC4Sync.init(enc_key)
      |> RC4Sync.discard(@discard)
    dec_state =
      RC4Sync.init(dec_key)
      |> RC4Sync.discard(@discard)
    {enc_state, dec_state}
  end
  def encrypt({enc, dec}, data) do
    {ciphertext, enc} = RC4Sync.crypt(enc, data)
    {ciphertext, {enc, dec}}
  end
  def decrypt({enc, dec}, data) do
    {plaintext, dec} = RC4Sync.crypt(dec, data)
    {plaintext, {enc, dec}}
  end
  defp pad_left(bin, len) do
    pad_size = len - byte_size(bin)
    if pad_size > 0 do
      <<0::size(pad_size)-unit(8), bin::binary>>
    else
      bin
    end
  end
end