defmodule GenS.ConnectionsOut do
  import MagnetSorter.Const
  import TimeSync
  @moduledoc """
  Unified outbound connection manager with per-IP/subnet rate limiting.
  Merges GenS.ConnectionsOut and GenS.Limiter into a single high-performance module.
  All hot-path operations use direct ETS counters for lock-free concurrent access.
  ## API
  - `acquire(:tcp | :utp, peer)` - acquire connection slot
  - `release(:tcp | :utp, peer)` - release connection slot
  - `utp_connected()` - signal uTP handshake complete
  ## Limits Checked on Acquire
  1. Global protocol limit (TCP/uTP)
  2. Total connection limit
  3. Half-open limit (uTP only)
  4. Per-IP limit
  5. Per-subnet (/24) limit
  6. Failure-based blacklist (via PeerManager integration)
  """
  use GenServer
  require Logger
  @compile {:inline,
            [
              ip_key: 1,
              subnet_key: 1,
              idx_for_type: 1,
              limit_for_type: 1,
              get_atomic: 1,
              get_ets_count: 2
            ]}
  @ets_per_ip :conn_out_per_ip
  @ets_per_subnet :conn_out_per_subnet
  @ets_fail_counts :conn_out_fail_counts
  @ets_blocked :conn_out_blocked
  @ets_ip_last_used :conn_out_ip_last_used
  @ets_peer_claimed :peer_claimed
  @ets_grace_periods :conn_out_grace_periods
  @ets_syns :utp_syns
  @half_open_key :utp_half_open_conns
  @ets_utp_connections :utp_connections
  @grace_per_good_peer_ms 30_000
  @max_grace_ms 600_000
  @per_ip_limit 64
  @per_subnet_limit @per_ip_limit * 8
  @ip_fail_thr 16
  @subnet_fail_thr @ip_fail_thr * 8
  @fail_window_ms 20_000
  @ip_block_duration_ms 60_000
  @subnet_block_duration_ms 10_000
  @cleanup_interval_ms 30_000
  @ip_cooldown_ms 1_000
  @claim_ttl_ms 10_000
  @idx_tcp 1
  @idx_utp 2
  @idx_half_open 3
  @idx_total 4
  @pt_counters {:conn_out, :counters}
  @syn_limit 3
  @syn_window_ms 5_000
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def acquire(:tcp, peer, continuation?), do: try_acquire(:tcp, peer, continuation?)
  def acquire(:utp, peer, continuation?) do
    case check_half_open_limit() do
      {:error, :half_open_limit} = err ->
        log_sampled(:half_open)
        err
      :ok ->
        case try_acquire(:utp, peer, continuation?) do
          :ok ->
            incr_atomic(@idx_half_open)
            :ok
          {:error, _reason} = err ->
            err
        end
    end
  end
  def release(type, peer) do
    release_peer_claim(peer)
    safe_decr_atomic(idx_for_type(type))
    safe_decr_atomic(@idx_total)
    safe_decr_ets(@ets_per_ip, ip_key(peer))
    safe_decr_ets(@ets_per_subnet, subnet_key(peer))
    update_ip_used_stamp(ip_key(peer))
    :ok
  end
  def utp_connected() do
    safe_decr_atomic(@idx_half_open)
    :ok
  end
  def trust_peer(peer) do
    ip = ip_key(peer)
    subnet = subnet_key(peer)
    now = mono_ms()
    add_grace({:ip, ip}, now)
    add_grace({:subnet, subnet}, now)
  end
  def record_failure(peer, _reason) do
    now = mono_ms()
    ip = ip_key(peer)
    subnet = subnet_key(peer)
    if in_grace_period?({:ip, ip}, now) or in_grace_period?({:subnet, subnet}, now) do
      log_sampled(:graced, ip, subnet)
      :ok
    else
      ip_count = incr_failure({:ip, ip}, now)
      subnet_count = incr_failure({:subnet, subnet}, now)
      case {ip_count >= @ip_fail_thr, subnet_count >= @subnet_fail_thr} do
        {true, _} ->
          block_key({:ip, ip}, now)
          log_sampled(:blocked_ip, ip, ip_count)
          {:blocked, :ip, ip}
        {_, true} ->
          block_key({:subnet, subnet}, now)
          log_sampled(:blocked_subnet, subnet, subnet_count)
          {:blocked, :subnet, subnet}
        {false, false} ->
          :ok
      end
    end
  end
  @doc "Check if peer is blocked. Used by PeerManager for filtering."
  def blocked?(peer) do
    now = mono_ms()
    blocked_key?({:ip, ip_key(peer)}, now) or blocked_key?({:subnet, subnet_key(peer)}, now)
  end
  @doc "Get current blocked IPs and subnets with expiry times."
  def get_blocks do
    now = mono_ms()
    active =
      @ets_blocked
      |> TryETS.tab2list()
      |> Enum.filter(fn {_k, exp} -> exp > now end)
    %{
      ips: for({{:ip, ip}, exp} <- active, do: {ip, exp - now}),
      subnets: for({{:subnet, s}, exp} <- active, do: {s, exp - now})
    }
  end
  def utp_syn_allowed?(peer) do
    not at_half_open_limit?() and try_record_syn(peer)
  rescue
    ArgumentError -> false
  end
  def utp_half_open_count() do
    ref = :persistent_term.get(@pt_counters)
    :atomics.get(ref, @idx_half_open)
  end
  defp decr_ets(table, key), do: TryETS.new_and_count(table, key, 0, -1)
  defp update_ip_used_stamp(ip), do: TryETS.insert(@ets_ip_last_used, {ip, mono_ms()})
  defp schedule_cleanup(), do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  def init(_opts) do
    ref = :atomics.new(4, signed: false)
    :persistent_term.put(@pt_counters, ref)
    init_tables()
    schedule_cleanup()
    {:ok, %{}}
  end
  def handle_info(:cleanup, st) do
    do_cleanup()
    schedule_cleanup()
    {:noreply, st}
  end
  def handle_info(_msg, st), do: {:noreply, st}
  defp try_acquire(type, peer, continuation?) do
    case try_claim_peer(peer) do
      {:error, :peer_busy_by_other_worker} = err ->
        err
      :ok ->
        ip = ip_key(peer)
        subnet = subnet_key(peer)
        now = mono_ms()
        case acquire_all_limits(type, ip, subnet, now, continuation?) do
          :ok ->
            :ok
          {:error, reason} ->
            release_peer_claim(peer)
            {:error, reason}
        end
    end
  end
  defp try_claim_peer(peer) do
    now = mono_ms()
    claim_scenario =
      case TryETS.lookup(@ets_peer_claimed, peer) do
        [{^peer, pid, _expires}] when pid == self() -> :mse_continuation
        [] -> :new
        [{^peer, _pid, expires}] when expires <= now -> :cooled_down
        [{^peer, _pid, _expires}] -> :other_worker_claimed
      end
    case claim_scenario do
      :mse_continuation -> :ok
      s when s in [:new, :cooled_down] -> ok_insert(peer, now)
      :other_worker_claimed -> {:error, :peer_busy_by_other_worker}
    end
  end
  defp acquire_all_limits(type, ip, subnet, now, continuation?) do
    with :ok <- maybe_check_blocked(ip, subnet, now, continuation?),
         :ok <- maybe_check_cooldown(ip, continuation?) do
      case check_all_limits(type, ip, subnet) do
        :ok ->
          commit_all_limits(type, ip, subnet)
          :ok
        {:error, _reason} = err ->
          err
      end
    end
  end
  defp check_all_limits(type, ip, subnet) do
    type_idx = idx_for_type(type)
    type_limit = limit_for_type(type)
    total_limit = max_connections()
    type_val = get_atomic(type_idx)
    total_val = get_atomic(@idx_total)
    ip_val = get_ets_count(@ets_per_ip, ip)
    subnet_val = get_ets_count(@ets_per_subnet, subnet)
    cond do
      type_val >= type_limit ->
        {:error, :transport_conn_limit}
      total_val >= total_limit ->
        {:error, :global_conn_limit}
      ip_val >= @per_ip_limit ->
        log_sampled(:ip, ip)
        {:error, :ip_limit}
      subnet_val >= @per_subnet_limit ->
        log_sampled(:subnet, subnet)
        {:error, :subnet_limit}
      true ->
        :ok
    end
  end
  defp commit_all_limits(type, ip, subnet) do
    incr_atomic(idx_for_type(type))
    incr_atomic(@idx_total)
    TryETS.new_and_count(@ets_per_ip, {ip, 1}, :u16)
    TryETS.new_and_count(@ets_per_subnet, {subnet, 1}, :u16)
  end
  defp get_atomic(idx) do
    ref = :persistent_term.get(@pt_counters)
    :atomics.get(ref, idx)
  end
  defp get_ets_count(table, key) do
    case TryETS.lookup(table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
  defp ok_insert(peer, now) do
    TryETS.insert(@ets_peer_claimed, {peer, self(), now + @claim_ttl_ms})
    :ok
  end
  defp maybe_check_blocked(_ip, _subnet, _now, true = _continuation?), do: :ok
  defp maybe_check_blocked(ip, subnet, now, false) do
    cond do
      blocked_key?({:ip, ip}, now) ->
        log_sampled(:rejected_blocked_ip, ip)
        {:error, :rejected_blocked_ip}
      blocked_key?({:subnet, subnet}, now) ->
        log_sampled(:rejected_blocked_subnet, subnet)
        {:error, :rejected_blocked_subnet}
      true ->
        :ok
    end
  end
  defp maybe_check_cooldown(_ip, true = _continuation?), do: :ok
  defp maybe_check_cooldown(ip, false) do
    if ip_in_cooldown?(ip), do: {:error, :ip_cooldown}, else: :ok
  end
  defp incr_failure(key, now) do
    window_id = div(now, @fail_window_ms)
    TryETS.new_and_count(@ets_fail_counts, {key, window_id}, :u16)
  end
  defp incr_atomic(idx) do
    ref = :persistent_term.get(@pt_counters)
    :atomics.add(ref, idx, 1)
  end
  defp safe_decr_atomic(idx) do
    ref = :persistent_term.get(@pt_counters)
    case :atomics.get(ref, idx) do
      0 -> :ok
      _ -> :atomics.sub(ref, idx, 1)
    end
  end
  defp safe_decr_ets(table, key) do
    case TryETS.lookup(table, key) do
      [{^key, 0}] -> :ok
      [{^key, _n}] -> decr_ets(table, key)
      [] -> :ok
    end
  end
  defp block_key(key, now) do
    expires = now + key_duration(key)
    TryETS.insert(@ets_blocked, {key, expires})
  end
  defp key_duration({:ip, _ip}), do: @ip_block_duration_ms
  defp key_duration({:subnet, _subnet}), do: @subnet_block_duration_ms
  defp blocked_key?(key, now) do
    case TryETS.lookup(@ets_blocked, key) do
      [{^key, expires}] when expires > now -> true
      _ -> false
    end
  end
  defp idx_for_type(:tcp), do: @idx_tcp
  defp idx_for_type(:utp), do: @idx_utp
  defp ip_in_cooldown?(ip) do
    now = mono_ms()
    case TryETS.lookup(@ets_ip_last_used, ip) do
      [{^ip, last}] when now - last < @ip_cooldown_ms -> true
      [{^ip, _last}] -> false
      [] -> false
    end
  end
  defp release_peer_claim(peer) do
    TryETS.delete(@ets_peer_claimed, peer)
  end
  defp add_grace(key, now) do
    current_expiry =
      case TryETS.lookup(@ets_grace_periods, key) do
        [{^key, exp}] when exp > now -> exp
        _ -> now
      end
    new_expiry = min(current_expiry + @grace_per_good_peer_ms, now + @max_grace_ms)
    TryETS.insert(@ets_grace_periods, {key, new_expiry})
  end
  defp in_grace_period?(key, now) do
    case TryETS.lookup(@ets_grace_periods, key) do
      [{^key, exp}] when exp > now -> true
      _ -> false
    end
  end
  defp check_half_open_limit() do
    case get_atomic(@idx_half_open) < max_connections() do
      false -> {:error, :half_open_limit}
      true -> :ok
    end
  end
  defp ip_key(<<a, b, c, d, _port::16>>), do: {a, b, c, d}
  defp subnet_key(<<a, b, c, _d, _port::16>>), do: {a, b, c}
  defp limit_for_type(:tcp), do: infohash_workers() * ih_worker_connections_factor()
  defp limit_for_type(:utp), do: infohash_workers() * ih_worker_connections_factor()
  defp max_connections(), do: infohash_workers() * ih_worker_connections_factor()
  defp log_sampled(:half_open), do: log_if_rolled(100, "[Limiter] Half-open limit hit")
  defp log_sampled(:ip, ip),
    do: log_if_rolled(1200, "[Limiter] Per-IP limit: #{PrinterSync.ip(ip)}", :debug)
  defp log_sampled(:subnet, s),
    do: log_if_rolled(50, "[Limiter] Per-subnet limit: #{PrinterSync.subnet(s)}", :debug)
  defp log_sampled(:rejected_blocked_ip, ip),
    do: log_if_rolled(600, "[Limiter] Rejected blocked IP: #{PrinterSync.ip(ip)}", :debug)
  defp log_sampled(:rejected_blocked_subnet, s),
    do: log_if_rolled(100, "[Limiter] Rejected blocked subnet: #{PrinterSync.subnet(s)}", :debug)
  defp log_sampled(:graced, ip, s),
    do:
      log_if_rolled(
        20,
        "[Limiter] Graced #{PrinterSync.ip(ip)} of #{PrinterSync.subnet(s)}, not blocked",
        :debug
      )
  defp log_sampled(:blocked_ip, ip, ip_count),
    do: log_if_rolled(800, "Blocked IP #{PrinterSync.ip(ip)}, #{ip_count} failures", :debug)
  defp log_sampled(:blocked_subnet, s, subnet_count),
    do:
      log_if_rolled(
        200,
        "Blocked subnet #{PrinterSync.subnet(s)}, #{subnet_count} failures",
        :debug
      )
  defp log_if_rolled(n, msg, level \\ :warning) do
    case MathSync.rolled?(1, n) do
      true when level == :debug -> Logger.debug(msg)
      true -> Logger.warning(msg)
      false -> :ok
    end
  end
  defp try_record_syn(peer) do
    now = mono_ms()
    key = {:syn, peer}
    case TryETS.lookup(@ets_syns, key) do
      [{^key, count, ts}] when now - ts < @syn_window_ms and count >= @syn_limit ->
        false
      [{^key, _count, ts}] when now - ts < @syn_window_ms ->
        TryETS.new_and_count(@ets_syns, {key, 1, ts}, :u16)
        true
      _ ->
        TryETS.insert(@ets_syns, {key, 1, now})
        true
    end
  end
  defp at_half_open_limit? do
    ref = :persistent_term.get(@pt_counters)
    :atomics.get(ref, @idx_half_open) >= max_connections()
  rescue
    ArgumentError -> true
  end
  defp init_tables do
    general_sets = [
      @ets_per_ip,
      @ets_per_subnet,
      @ets_fail_counts,
      @ets_blocked,
      @ets_ip_last_used,
      @ets_peer_claimed,
      @ets_grace_periods
    ]
    utp_sets = [
      @ets_utp_connections,
      @ets_syns,
      @half_open_key
    ]
    TryETS.create_many_named(general_sets, :set, :public, true, true)
    TryETS.create_many_named(utp_sets, :set, :public, true, true)
  end
  defp do_cleanup() do
    now = mono_ms()
    window_id = div(now, @fail_window_ms)
    cooldown_cutoff = now - @ip_cooldown_ms
    grace_cutoff = now - @max_grace_ms
    syn_cutoff = now - @syn_window_ms
    expired_fails =
      :ets.select_delete(@ets_fail_counts, [
        {{{:_, :"$1"}, :_}, [{:<, :"$1", window_id}], [true]}
      ])
    expired_blocks =
      :ets.select_delete(@ets_blocked, [
        {{:_, :"$1"}, [{:<, :"$1", now}], [true]}
      ])
    _expired_cooldowns =
      :ets.select_delete(@ets_ip_last_used, [
        {{:_, :"$1"}, [{:<, :"$1", cooldown_cutoff}], [true]}
      ])
    _expired_claims =
      :ets.select_delete(@ets_peer_claimed, [
        {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
      ])
    _expired_grace =
      :ets.select_delete(@ets_grace_periods, [{{:_, :"$1"}, [{:<, :"$1", grace_cutoff}], [true]}])
    :ets.select_delete(@ets_syns, [{{:_, :_, :"$1"}, [{:<, :"$1", syn_cutoff}], [true]}])
    :ets.select_delete(@ets_per_ip, [{{:_, 0}, [], [true]}])
    :ets.select_delete(@ets_per_subnet, [{{:_, 0}, [], [true]}])
    log_block_status(expired_fails, expired_blocks)
  end
  defp log_block_status(expired_fails, expired_blocks) do
    blocks = get_blocks()
    case blocks.ips != [] or blocks.subnets != [] or expired_blocks > 0 do
      true ->
        ip_strs =
          Enum.map(blocks.ips, fn {ip, ttl} -> "#{PrinterSync.ip(ip)}(#{div(ttl, 1000)}s)" end)
        sub_strs =
          Enum.map(blocks.subnets, fn {s, ttl} ->
            "#{PrinterSync.subnet(s)}(#{div(ttl, 1000)}s)"
          end)
        Logger.info(
          "[Limiter] STATS Blocks: IPs=#{inspect(ip_strs)}, Subnets=#{inspect(sub_strs)}, " <>
            "expired_fails=#{expired_fails}, expired_blocks=#{expired_blocks}"
        )
      false ->
        :ok
    end
  end
end