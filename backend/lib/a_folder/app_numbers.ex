defmodule MagnetSorter.Const do
  import Bitwise
  @mainline_dht_space_bytes 20
  defmacro infohash_workers, do: 48
  defmacro worker_ids_count, do: 1_024 * 8
  defmacro ratelimit, do: 1_024 * 8
  defmacro dht_size, do: 1_024 * 4
  defmacro dht_bytes, do: @mainline_dht_space_bytes
  defmacro dht_bits, do: @mainline_dht_space_bytes * 8
  defmacro udp_port, do: 51413
  defmacro worker_ids_lookup_bits, do: trunc(:math.log2(worker_ids_count()))
  defmacro worker_ids_lookup_table_size, do: 1 <<< worker_ids_lookup_bits()
  defmacro worker_ids_bitshift, do: dht_bits() - worker_ids_lookup_bits()
  defmacro ih_worker_concurrent_downloads, do: 8
  defmacro ih_worker_connections_factor, do: ih_worker_concurrent_downloads()
  defmacro worker_lifespan_s, do: 35
  defmacro base_sample_infohashes_rate_s, do: 32
  defmacro get_peers_echo_rate_s, do: base_sample_infohashes_rate_s()
  defmacro samples_prefix_length(), do: 1
  defmacro sleep_ms(), do: 100
end