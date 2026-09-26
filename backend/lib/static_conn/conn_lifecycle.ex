defmodule Conn.Lifecycle do
  @moduledoc """
  Handles common monitor/link logic for Connection GenServers.
  Requires the state struct to have:
  - :owner_pid - the owner pid (linked)
  - :peer_pid - the peer pid (monitored during handshake)
  - :connected - boolean indicating if handshake is complete
  waiter - a conjoined channel with a peer into one GenServer, managed by WaiterQueue
  """
  @compile {:inline, []}
  def setup_monitors(owner_pid, peer_pid) do
    owner_ref = if owner_pid, do: Process.monitor(owner_pid)
    peer_pid_ref =
      if peer_pid && peer_pid != owner_pid do
        Process.monitor(peer_pid)
      end
    {:ok, owner_ref, peer_pid_ref}
  end
  def handle_exit(pid, _reason, st) do
    %{owner_pid: owner_pid, connected: connected} = st
    cond do
      pid == owner_pid and not connected -> :stop
      pid == owner_pid -> {:clear_owner, nil}
      true -> :ignore
    end
  end
  def handle_down(ref, _pid, st, waiters) do
    %{owner_ref: o_ref, peer_pid_ref: p_ref, connected: connected?} = st
    is_waiter? = is_waiter_ref?(ref, waiters)
    ref_type =
      case ref do
        ^o_ref -> :owner
        ^p_ref -> :peer
        _pid when is_waiter? -> :waiter
        _pid -> :unknown
      end
    case {ref_type, connected?, st} do
      {:owner, false, _st} -> :stop
      {:owner, true, %{peer_pid: nil} = _st} -> :stop
      {:owner, true, _st} -> :clear_owner
      {:peer, false, _st} -> :stop
      {:peer, true, %{owner_pid: nil} = _st} -> :stop
      {:peer, true, _st} -> :clear_peer_pid
      {:waiter, _connected?, _st} -> {:remove_waiter, ref}
      {:unknown, _connected?, _st} -> :ignore
    end
  end
  defp is_waiter_ref?(ref, queue) do
    :queue.any(fn {_from, _req, r} -> r == ref end, queue)
  end
end