defmodule KeyStorageSync do
  @num_udp_shards_key {__MODULE__, :num_udp_shards}
  @own_ip_key {__MODULE__, :own_ip}
  @own_uaddr_key {__MODULE__, :own_uaddr}
  @nat_type {__MODULE__, :nat_type}
  @known_ihs {__MODULE__, :known_ihs}
  @id_mgr_ready {__MODULE__, :id_mgr_ready}
  @peer_mgr_ready {__MODULE__, :peer_mgr_ready}
  @gui_metrics_ready {__MODULE__, :gui_metrics_ready}
  @utm_cand_prepared {__MODULE__, :utm_cand_prepared}
  @ihc_build_in_progress {__MODULE__, :ihc_build_in_progress}
  @rt_filled_flag {__MODULE__, :routing_table_filled}
  @pf_rt_filled_flag {__MODULE__, :pf_routing_table_filled}
  @utp_usage_flag {__MODULE__, :utp_usage_flag}
  @pf_usage_flag {__MODULE__, :pf_usage_flag}
  @ygg_usage_flag {__MODULE__, :ygg_usage_flag}
  @crawl_flag {__MODULE__, :crawl_flag}
  @sample_log_flag {__MODULE__, :sample_log_flag}
  @os_rules_atom {__MODULE__, :os_rules_atom}
  @nat_analyzed {__MODULE__, :nat_analyzed}
  @worker_ids_list {__MODULE__, :worker_ids}
  @worker_lookup_tuple {__MODULE__, :worker_lookup}
  def own_ip(), do: :persistent_term.get(@own_ip_key, <<0, 0, 0, 0>>)
  def own_uaddr(), do: :persistent_term.get(@own_uaddr_key, <<0, 0, 0, 0, 0, 0>>)
  def set_own_ip(ipv4), do: :persistent_term.put(@own_ip_key, ipv4)
  def set_own_uaddr(uaddr), do: :persistent_term.put(@own_uaddr_key, uaddr)
  @doc "Set the number of UDP shards globally."
  def set_num_udp_shards(n), do: :persistent_term.put(@num_udp_shards_key, n)
  @doc "Get the number of UDP shards (defaults to 1)."
  def get_num_udp_shards(), do: :persistent_term.get(@num_udp_shards_key, 1)
  def set_os_rules_atom(atom), do: :persistent_term.put(@os_rules_atom, atom)
  def get_os_rules_atom(), do: :persistent_term.get(@os_rules_atom, :non_unix_os)
  @doc "Register a shard's socket. Call from each shard during init."
  def set_nat_type(type), do: :persistent_term.put(@nat_type, type)
  def get_nat_type(), do: :persistent_term.get(@nat_type, :unknown)
  def symmetric_nat?(), do: get_nat_type() == :symmetric
  def set_id_mgr_ready(), do: :persistent_term.put(@id_mgr_ready, true)
  def set_peer_mgr_ready(), do: :persistent_term.put(@peer_mgr_ready, true)
  def set_gui_metrics_ready(), do: :persistent_term.put(@gui_metrics_ready, true)
  def set_rt_filled(), do: :persistent_term.put(@rt_filled_flag, true)
  def set_pf_rt_filled(), do: :persistent_term.put(@pf_rt_filled_flag, true)
  def set_utm_candidates_prepared(), do: :persistent_term.put(@utm_cand_prepared, true)
  def set_nat_analyzed(), do: :persistent_term.put(@nat_analyzed, true)
  def set_worker_ids_list(worker_ids), do: :persistent_term.put(@worker_ids_list, worker_ids)
  def set_worker_lookup_tuple(tuple), do: :persistent_term.put(@worker_lookup_tuple, tuple)
  def worker_ids_list(), do: :persistent_term.get(@worker_ids_list, nil)
  def set_build_in_progress(bool), do: :persistent_term.put(@ihc_build_in_progress, bool)
  def build_in_progress?(), do: :persistent_term.get(@ihc_build_in_progress, false)
  def set_known_ihs(int), do: :persistent_term.put(@known_ihs, int)
  def get_known_ihs(), do: :persistent_term.get(@known_ihs, 0)
  def set_use_utp(bool), do: :persistent_term.put(@utp_usage_flag, bool)
  def use_utp?(), do: :persistent_term.get(@utp_usage_flag, false)
  def set_use_pf(bool), do: :persistent_term.put(@pf_usage_flag, bool)
  def use_pf?(), do: :persistent_term.get(@pf_usage_flag, false)
  def set_use_ygg(bool), do: :persistent_term.put(@ygg_usage_flag, bool)
  def use_ygg?(), do: :persistent_term.get(@ygg_usage_flag, false)
  def set_crawl(bool), do: :persistent_term.put(@crawl_flag, bool)
  def do_crawl?(), do: :persistent_term.get(@crawl_flag, false)
  def set_samples_log(bool), do: :persistent_term.put(@sample_log_flag, bool)
  def write_samples_log?(), do: :persistent_term.get(@sample_log_flag, false)
  def metrics_ready?(), do: :persistent_term.get(@gui_metrics_ready, false)
  def rt_ready?(), do: :persistent_term.get(@rt_filled_flag, false)
  def pf_rt_ready?(), do: :persistent_term.get(@pf_rt_filled_flag, false)
  def flags_for_dht_work?() do
    metrics_ready?() and
      :persistent_term.get(@id_mgr_ready, false)
  end
  def ready_for_preparing_utm_candidates?() do
    metrics_ready?() and
      :persistent_term.get(@peer_mgr_ready, false)
  end
  def ready_for_utm_download?() do
    metrics_ready?() and
      :persistent_term.get(@utm_cand_prepared, false) and
      :persistent_term.get(@nat_analyzed, false)
  end
end