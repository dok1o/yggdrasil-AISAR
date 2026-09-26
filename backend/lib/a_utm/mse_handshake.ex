defmodule MSEHandshake do
  @moduledoc "MSE handshake state machine (BEP 8)"
  require Logger
  @vc <<0::64>>
  @vc_step 8
  @mse_pubkey_size 96
  @crypto_plain 0x01
  @crypto_rc4 0x02
  @crypto_provide 0x03
  @max_pad 512
  @double_max_pad @max_pad * 2
  @vc_search_limit @max_pad + @vc_step
  @timeout 4_000
  def initiate(conn, ih, payload) do
    {x, ya} = MSESync.generate_keypair()
    pad_a = :crypto.strong_rand_bytes(:rand.uniform(@max_pad))
    result =
      with {:ok, conn} <- Transport.send(conn, [ya, pad_a]),
           {:ok, yb, conn} <- recv_public_key(conn),
           secret = MSESync.compute_secret(yb, x),
           {:ok, enc_state, dec_state, conn} <- send_crypto_provide(conn, secret, ih, payload),
           {:ok, sel, dec_state, conn, leftover} <- recv_crypto_stream(conn, dec_state) do
        case sel do
          @crypto_plain ->
            {:ok, SecureTransport.wrap(conn, nil, leftover)}
          @crypto_rc4 ->
            {:ok, SecureTransport.wrap(conn, {enc_state, dec_state}, leftover)}
          other ->
            Logger.warning("[MSE] Unknown crypto: 0x#{Integer.to_string(other, 16)}")
            {:error, :unsupported_crypto}
        end
      end
    case result do
      {:ok, _hs_conn} ->
        result
      {:error, _reason} ->
        result
    end
  end
  defp recv_public_key(conn) do
    case Transport.recv_exact(conn, @mse_pubkey_size, @timeout) do
      {:ok, <<_key_bytes::binary-96>> = yb, conn} ->
        {:ok, yb, conn}
      {:ok, <<"HTTP", _rest::binary>>, _conn} ->
        {:error, :http_server_not_peer}
      {:ok, <<"GET ", _rest::binary>>, _conn} ->
        {:error, :http_server_not_peer}
      {:ok, <<"POST", _rest::binary>>, _conn} ->
        {:error, :http_server_not_peer}
      {:ok, <<"HEAD", _rest::binary>>, _conn} ->
        {:error, :http_server_not_peer}
      {:ok, unexpected, _conn} ->
        Logger.debug(
          "[MSE] Invalid handshake, data: #{Base.encode16(binary_part(unexpected, 0, min(32, byte_size(unexpected))))}"
        )
        {:error, :invalid_handshake}
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp send_crypto_provide(conn, secret, skey, bth) do
    req1 = :crypto.hash(:sha, ["req1", secret])
    req2 = :crypto.hash(:sha, ["req2", skey])
    req3 = :crypto.hash(:sha, ["req3", secret])
    req23 = :crypto.exor(req2, req3)
    {enc_state, dec_state} = MSESync.init_crypto(secret, skey, :initiator)
    ia_len = byte_size(bth)
    payload = <<@vc::binary, @crypto_provide::32-big, 0::16, ia_len::16-big, bth::binary>>
    {enc_payload, enc_state} = RC4Sync.crypt(enc_state, payload)
    case Transport.send(conn, [req1, req23, enc_payload]) do
      {:ok, conn} -> {:ok, enc_state, dec_state, conn}
      err -> err
    end
  end
  defp recv_crypto_stream(conn, dec_state) do
    {expd_enc_vc, _enc_st} = RC4Sync.crypt(dec_state, <<0::64>>)
    with {:ok, dec_state, conn, buf} <- find_vc(conn, dec_state, expd_enc_vc, <<>>, 0),
         {:ok, header, dec_state, conn, buf} <- recv_and_dec_bufd(conn, dec_state, 6, buf),
         <<crypto_select::32-big, pad_len::16-big>> = header,
         :ok <- validate_pad_len(pad_len),
         {:ok, _padD, dec_state, conn, leftover} <-
           recv_and_dec_bufd(conn, dec_state, pad_len, buf) do
      {:ok, crypto_select, dec_state, conn, leftover}
    end
  end
  defp scan_limit?(scanned), do: scanned > @double_max_pad
  defp validate_pad_len(len) when len <= @vc_search_limit, do: :ok
  defp validate_pad_len(_), do: {:error, :invalid_pad_length}
  defp find_vc(conn, dec_state, _expected_vc, buffer, scanned) do
    case try_sync_vc(buffer, dec_state) do
      {:ok, next_dec_state, leftover} ->
        {:ok, next_dec_state, conn, leftover}
      :not_found ->
        if scan_limit?(scanned) do
          {:error, :vc_not_found}
        else
          case Transport.recv_any(conn, @double_max_pad, @timeout) do
            {:ok, chunk, next_conn} ->
              find_vc(next_conn, dec_state, nil, buffer <> chunk, scanned + byte_size(chunk))
            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end
  defp try_sync_vc(buffer, _dec_state) when byte_size(buffer) < @vc_step, do: :not_found
  defp try_sync_vc(buffer, dec_state) do
    <<potential_vc_cipher::binary-8, _rest::binary>> = buffer
    {plaintext, updated_state} = RC4Sync.crypt(dec_state, potential_vc_cipher)
    if plaintext == @vc do
      <<_prev::binary-8, leftover::binary>> = buffer
      {:ok, updated_state, leftover}
    else
      <<_prev::binary-1, rest_buffer::binary>> = buffer
      try_sync_vc(rest_buffer, dec_state)
    end
  end
  defp recv_and_dec_bufd(conn, dec_state, n, buffer) do
    cond do
      n == 0 ->
        {:ok, <<>>, dec_state, conn, buffer}
      byte_size(buffer) >= n ->
        <<ciphertext::binary-size(n), rest::binary>> = buffer
        {plaintext, next_dec_state} = RC4Sync.crypt(dec_state, ciphertext)
        {:ok, plaintext, next_dec_state, conn, rest}
      true ->
        needed = n - byte_size(buffer)
        case Transport.recv_exact(conn, needed, @timeout) do
          {:ok, chunk, new_conn} -> recv_and_dec_bufd(new_conn, dec_state, n, buffer <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end
end