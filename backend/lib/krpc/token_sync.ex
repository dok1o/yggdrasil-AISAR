defmodule TokenSync do
  @compile {:inline, [create_trunc8_hmac: 2]}
  @ets_secrets :prefixes_secrets
  def make(ipv4, nid) do
    secret = safe_get_secret(nid)
    create_trunc8_hmac(ipv4, secret)
  end
  def verify?(token, ipv4, nid) do
    secret = safe_get_secret(nid)
    token == create_trunc8_hmac(ipv4, secret)
  end
  defp safe_get_secret(nid) do
    prefix = WorkerIDSync.prefix_from_binary(nid)
    :ets.lookup_element(@ets_secrets, prefix, 2)
  rescue
    ArgumentError -> rand_dht_token()
  end
  defp create_trunc8_hmac(ipv4, secret) do
    <<trunc8::binary-size(8), _rest::binary>> = :crypto.mac(:hmac, :sha256, secret, ipv4)
    trunc8
  end
  defp rand_dht_token(), do: :crypto.strong_rand_bytes(8)
end