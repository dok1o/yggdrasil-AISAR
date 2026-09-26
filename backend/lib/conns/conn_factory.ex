defmodule ConnFactory do
  import TimeSync
  alias Conn.Error
  @compile {:inline, [connect_to_peer: 4]}
  @type conn :: {:tcp | :utp, pid()}
  @tcp_fallback_conn [:econnrefused, :timeout, :ehostunreach, :enetunreach, :econnreset]
  @tcp_fallback_runt [:stale, :closed, :peer_closed]
  @tcp_connect_timeout 3_500
  @conn_establ_timeout 7_000
  def connect_to_peer(peer, use_utp?, continuation?, torr_hs_func),
    do: do_connect_to_peer(peer, use_utp?, continuation?, torr_hs_func)
  def do_connect_to_peer(peer, use_utp?, cont?, fun) do
    protocols =
      case use_utp? do
        true -> [:tcp, :utp]
        false -> [:tcp]
      end
    do_connect_loop(protocols, peer, mono_ms(), self(), cont?, fun)
  end
  defp do_connect_loop(protocols, peer, start_ms, owner_pid, continuation?, torr_hs_fun)
  defp do_connect_loop([], _p, _st, _pid, _cont, _fun), do: {:error, :all_prot_failed}
  defp do_connect_loop([proto | rest], peer, start_ms, o_pid, cont?, fun) do
    timeout = remaining_ms(start_ms, @conn_establ_timeout)
    case try_protocol(proto, peer, timeout, o_pid, cont?, fun) do
      {:ok, _hs_conn} = ok ->
        ok
      {:error, reason} ->
        case can_fallback?(proto, reason, rest) do
          :fast_fallback -> do_connect_loop(rest, peer, start_ms, o_pid, cont?, fun)
          r when r in [:all_protocols_tried, :unreachable_peer] -> {:error, reason}
        end
    end
  end
  defp can_fallback?(_proto, _reason, []), do: :all_protocols_tried
  defp can_fallback?(:tcp, r, _next)
       when r in @tcp_fallback_conn or r in @tcp_fallback_runt do
    :fast_fallback
  end
  defp can_fallback?(_other, _reason, _next), do: :unreachable_peer
  defp try_protocol(proto, peer, timeout, o_pid, cont?, fun) do
    dial_timeout = min(timeout, @tcp_connect_timeout)
    case dial(proto, peer, dial_timeout, o_pid, cont?) do
      {:ok, conn} -> execute_with_conn(conn, fun)
      {:error, reason} -> {:error, reason}
    end
  end
  defp execute_with_conn({type, pid} = conn, fun) do
    try do
      case fun.(conn) do
        {:ok, utm} -> {:ok, {type, utm}}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, reason -> {:error, Error.normalize(reason)}
    after
      Transport.close({type, pid})
    end
  end
  defp dial(type, peer, timeout, owner_pid, cont?) do
    case Spv.ConnSup.start_connection(type, {peer, owner_pid, self(), cont?}) do
      {:ok, pid} ->
        wait_for_connected(pid, type, timeout)
      {:error, {:already_started, pid}} ->
        case Process.alive?(pid) do
          false ->
            Spv.ConnSup.stop_connection(pid)
            dial(type, peer, timeout, owner_pid, cont?)
          true ->
            connected? = GenServer.call(pid, :check_connected)
            case connected? do
              true -> {:ok, {type, pid}}
              false -> wait_for_connected(pid, type, timeout)
            end
        end
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp wait_for_connected(pid, type, timeout) do
    ref = Process.monitor(pid)
    result =
      receive do
        {:connected, {^type, ^pid}} -> {:ok, {type, pid}}
        {:DOWN, ^ref, :process, ^pid, reason} -> {:error, Error.normalize(reason)}
      after
        timeout ->
          Spv.ConnSup.stop_connection(pid)
          {:error, :timeout}
      end
    Process.demonitor(ref, [:flush])
    result
  end
end