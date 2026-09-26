defmodule GetTorrent do
  import TimeSync
  require Logger
  @compile {:inline, [download: 4, utm_status: 1]}
  @requested_piece_size 16_384
  @mse_likely_reasons [
    :closed,
    :econnreset,
    :invalid_handshake
  ]
  @task_budget_ms 12_500
  @tcp_hs_timeout 3_000
  @utp_hs_timeout 9_000
  def download(ih, peer, own_ip, nid), do: attempt_download(ih, peer, own_ip, nid)
  defp attempt_download(ih, peer, own_ip, nid) do
    dl = set_deadline(@task_budget_ms)
    case plain_or_encrypted(nid, peer, ih, dl, own_ip, true) do
      {:ok, {conn_type, utm}} ->
        {:ok, {conn_type, utm}}
      {:error, reason} when reason in @mse_likely_reasons ->
        plain_or_encrypted(nid, peer, ih, deadline_in(dl), own_ip, false)
      err ->
        err
    end
  end
  defp plain_or_encrypted(nid, peer, ih, to, own_ip, use_mse?) do
    use_utp? = true
    ConnFactory.connect_to_peer(peer, use_utp?, use_mse?, fn conn ->
      with_selected_conn_download_utm(conn, nid, peer, ih, to, own_ip, use_mse?)
    end)
  end
  defp with_selected_conn_download_utm(conn, nid, peer, ih, dl, own_ip, use_mse?) do
    now = mono_ms()
    hs_timeout = min(hs_timeout_for(conn, dl), dl - now)
    case utm_hs(conn, ih, peer, nid, hs_timeout, own_ip, use_mse?) do
      {:ok, pe_id, oe_id, size, sec_tr, peer_ext} ->
        result = perform_download_and_validate(sec_tr, ih, peer, pe_id, oe_id, size, dl)
        status = utm_status(result)
        GenS.ExtSaver.save_ext(peer, ih, use_mse?, peer_ext, status)
        result
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp hs_timeout_for({:utp, _}, dl), do: min(@utp_hs_timeout, deadline_in(dl))
  defp hs_timeout_for({:tcp, _}, dl), do: min(@tcp_hs_timeout, deadline_in(dl))
  defp perform_download_and_validate(sec_tr, ih, peer, pe_id, oe_id, size, dl) do
    with {:ok, utm} <- utm_pieces(sec_tr, ih, peer, pe_id, oe_id, size, dl),
         :ok <- validate_utm(ih, utm) do
      {:ok, utm}
    end
  end
  defp utm_hs(conn, ih, peer, nid, hs_timeout, own_ip, use_mse?),
    do: TorrHandshake.perform(conn, ih, peer, nid, hs_timeout, own_ip, use_mse?)
  defp utm_pieces(sec_tr, ih, peer, peer_ext_id, own_ext_id, size, deadline) do
    PieceProcessor.collect(
      sec_tr,
      ih,
      peer,
      peer_ext_id,
      own_ext_id,
      size,
      deadline,
      @requested_piece_size
    )
  end
  defp validate_utm(ih, utm) do
    MetadataCache.clear(ih)
    case MathSync.sha1?(ih, utm) do
      true -> :ok
      false -> {:error, :info_hash_mismatch}
    end
  end
  defp utm_status({:ok, _utm}), do: :utm_dwld
  defp utm_status({:error, _reason}), do: :utm_not_dwld
end