defmodule Conn.Error do
  @compile {:inline, [normalize: 1]}
  @type connect_error ::
          :econnrefused
          | :ehostunreach
          | :enetunreach
          | :econnreset
          | :eaddrnotavail
          | :enetdown
  @type timeout_error ::
          :timeout
          | :stale
          | :closed
          | :handshake_timeout
          | :all_attempts_failed
          | :all_prot_failed
          | :invalid_handshake
          | :not_connected
          | :enoprotoopt
  @type runtime_error ::
          :buffer_overflow
          | :peer_closed
          | :busy
          | :deadline_exceeded
          | :einval
  @type utp_error ::
          :max_retransmits
          | :waiters_timed_out
  @type lifecycle_error ::
          :orphaned
          | :owner_died
          | :killed
          | :noproc
  @type crawler_error ::
          :utm_not_supported
          | :http_not_peer
  @type data_error ::
          :extensions_not_supported
          | :vc_not_found
          | :unexpected_message_type
          | :info_hash_mismatch
          | :metadata_timeout
          | :peer_has_no_metadata
          | :max_piece_retries
          | :too_many_unknown_messages
          | :unknown_protocol
  @type firewall_error ::
          :transport_conn_limit
          | :global_conn_limit
          | :ip_cooldown
          | :peer_busy_by_other_worker
          | :rejected_blocked_ip
          | :rejected_blocked_subnet
          | :subnet_limit
          | :ip_limit
          | :half_open_limit
  @type common_error ::
          :peer_closing
          | :low_peer_ext_score
          | :orphan_unused
          | :orphan_unclaimed
          | :normal
          | :shutdown
          | :unknown
  @type t ::
          connect_error()
          | timeout_error()
          | runtime_error()
          | utp_error()
          | lifecycle_error()
          | crawler_error()
          | data_error()
          | firewall_error()
          | common_error()
  @crawler_errors :crawler_errors
  @timeout_errors :timeout_errors
  @data_errors :data_errors
  @firewall_errors :firewall_errors
  @common_errors :common_errors
  @connect_errors :connect_errors
  def normalize(err), do: do_normalize(err)
  def get_error_type(error) do
    error
    |> normalize()
    |> utm_fetch_error()
  end
  def do_normalize({:shutdown, reason}) when is_atom(reason), do: reason
  def do_normalize({:shutdown, {reason, _st}}), do: reason
  def do_normalize(:normal), do: :closed
  def do_normalize(:killed), do: :killed
  def do_normalize(:noproc), do: :noproc
  def do_normalize({:noproc, _reason}), do: :noproc
  def do_normalize(other) when is_atom(other), do: other
  def do_normalize(_other), do: :unknown
  defp utm_fetch_error(error)
       when error in [
              :econnrefused,
              :ehostunreach,
              :enetunreach,
              :econnreset,
              :eaddrnotavail,
              :enetdown
            ],
       do: @connect_errors
  defp utm_fetch_error(error)
       when error in [
              :timeout,
              :stale,
              :closed,
              :handshake_timeout,
              :all_attempts_failed,
              :all_prot_failed,
              :invalid_handshake,
              :not_connected,
              :enoprotoopt
            ],
       do: @timeout_errors
  defp utm_fetch_error(error)
       when error in [
              :max_retransmits,
              :waiters_timed_out
            ],
       do: @timeout_errors
  defp utm_fetch_error(error)
       when error in [
              :utm_not_supported,
              :http_not_peer
            ],
       do: @crawler_errors
  defp utm_fetch_error(error)
       when error in [
              :extensions_not_supported,
              :vc_not_found,
              :unexpected_message_type,
              :info_hash_mismatch,
              :metadata_timeout,
              :peer_has_no_metadata,
              :max_piece_retries,
              :too_many_unknown_messages,
              :unknown_protocol
            ],
       do: @data_errors
  defp utm_fetch_error(error)
       when error in [
              :transport_conn_limit,
              :global_conn_limit,
              :ip_cooldown,
              :peer_busy_by_other_worker,
              :rejected_blocked_ip,
              :rejected_blocked_subnet,
              :subnet_limit,
              :ip_limit,
              :half_open_limit
            ],
       do: @firewall_errors
  defp utm_fetch_error(error)
       when error in [
              :peer_closing,
              :low_peer_ext_score,
              :deadline_exceeded,
              :busy,
              :buffer_overflow,
              :owner_died,
              :orphaned,
              :orphan_unused,
              :orphan_unclaimed,
              :einval,
              :killed,
              :noproc,
              :normal,
              :shutdown,
              :unknown
            ],
       do: @common_errors
  defp utm_fetch_error(_error), do: @common_errors
end