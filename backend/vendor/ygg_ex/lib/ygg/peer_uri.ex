defmodule Ygg.PeerURI do
  @moduledoc """
  Parsed peering URI: `tcp://host:port` or `tls://host:port` plus the query options.
  Ports the option handling of `links.add` (`reference/yggdrasil-go/src/core/link.go:160-230`), `dialerFor`
  (link.go:604-625, only `tcp`/`tls` are implemented, other schemes are
  `:unrecognised_schema`) and `urlForLinkInfo` (link.go:766-769: the links map key is the
  URI without its query, `info_uri` here). Options: `key=<hex>` (repeatable, pinned keys),
  `priority=<0..255>`, `password=<str>` (max 64 bytes, link.go:200-206), `maxbackoff=<Go
  duration>` (min 5 s, link.go:207-214), `sni=<host>` (link.go:215-230: never an IP literal,
  falls back to the URI host when that is not an IP either).
  Deviation: Go copies a pinned key into a 32-byte array without a length check
  (link.go:185-186); here a key that is not exactly 32 bytes is `:pinned_key_invalid`.
  """
  @compile {:inline, [info_uri: 3, ip_literal?: 1]}
  @default_backoff_ms 1_000 * 4096
  @min_backoff_ms 5_000
  @max_password 64
  @key_size 32
  defstruct scheme: :tcp,
            host: nil,
            port: nil,
            pinned_keys: MapSet.new(),
            priority: 0,
            password: "",
            max_backoff_ms: @default_backoff_ms,
            sni: nil,
            info_uri: nil,
            uri: nil
  @type t :: %__MODULE__{
          scheme: :tcp | :tls,
          host: String.t(),
          port: 1..65_535,
          pinned_keys: MapSet.t(<<_::256>>),
          priority: byte(),
          password: binary(),
          max_backoff_ms: pos_integer(),
          sni: String.t() | nil,
          info_uri: String.t(),
          uri: String.t()
        }
  @type error ::
          :unrecognised_schema
          | :invalid_host
          | :pinned_key_invalid
          | :priority_invalid
          | :password_invalid
          | :max_backoff_invalid
  def default_backoff_ms, do: @default_backoff_ms
  def min_backoff_ms, do: @min_backoff_ms
  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse(uri) when is_binary(uri) do
    uri = String.trim(uri)
    parsed = URI.parse(uri)
    with {:ok, scheme} <- scheme(parsed.scheme),
         {:ok, host, port} <- host_port(parsed),
         query = query(parsed.query),
         {:ok, keys} <- pinned_keys(query),
         {:ok, priority} <- priority(query),
         {:ok, password} <- password(query),
         {:ok, backoff} <- max_backoff(query) do
      {:ok,
       %__MODULE__{
         scheme: scheme,
         host: host,
         port: port,
         pinned_keys: keys,
         priority: priority,
         password: password,
         max_backoff_ms: backoff,
         sni: sni(query, host),
         info_uri: info_uri(scheme, host, port),
         uri: uri
       }}
    end
  end
  @doc "`scheme://host:port` without query; IPv6 literals are bracketed (urlForLinkInfo)."
  @spec info_uri(atom(), String.t(), :inet.port_number()) :: String.t()
  def info_uri(scheme, host, port) do
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    "#{scheme}://#{host}:#{port}"
  end
  @doc "Same key as Go's linkInfo for an accepted socket (link.go:521-527)."
  @spec incoming_info_uri(atom(), :inet.ip_address(), :inet.port_number()) :: String.t()
  def incoming_info_uri(scheme, ip, port),
    do: info_uri(scheme, List.to_string(:inet.ntoa(ip)), port)
  @spec ip_literal?(String.t()) :: boolean()
  def ip_literal?(host) when is_binary(host),
    do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  @doc """
  Go `time.ParseDuration` subset: sequence of `<number><unit>` with units ns, us, µs, ms, s,
  m, h and optional fraction; result in whole milliseconds (`"1.5h"` -> 5_400_000).
  """
  @spec parse_go_duration(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_go_duration("0"), do: {:ok, 0}
  def parse_go_duration(str) when is_binary(str) do
    case Regex.scan(~r/^(?:(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|ms|s|m|h))+$/u, str) do
      [] ->
        :error
      _ ->
        ns =
          ~r/(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|ms|s|m|h)/u
          |> Regex.scan(str)
          |> Enum.reduce(0.0, fn [_, num, unit], acc -> acc + to_float(num) * unit_ns(unit) end)
        {:ok, trunc(ns / 1_000_000)}
    end
  end
  defp scheme(nil), do: {:error, :unrecognised_schema}
  defp scheme(s) do
    case String.downcase(s) do
      "tcp" -> {:ok, :tcp}
      "tls" -> {:ok, :tls}
      _other -> {:error, :unrecognised_schema}
    end
  end
  defp host_port(%URI{host: host, port: port})
       when is_binary(host) and host != "" and is_integer(port),
       do: {:ok, host, port}
  defp host_port(_uri), do: {:error, :invalid_host}
  defp query(nil), do: []
  defp query(q), do: Enum.to_list(URI.query_decoder(q))
  defp pinned_keys(query) do
    Enum.reduce_while(query, {:ok, MapSet.new()}, fn
      {"key", hex}, {:ok, acc} ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, <<key::binary-size(@key_size)>>} -> {:cont, {:ok, MapSet.put(acc, key)}}
          _other -> {:halt, {:error, :pinned_key_invalid}}
        end
      _other, acc ->
        {:cont, acc}
    end)
  end
  defp priority(query) do
    case List.keyfind(query, "priority", 0) do
      nil -> {:ok, 0}
      {_, ""} -> {:ok, 0}
      {_, p} -> parse_uint8(p)
    end
  end
  defp parse_uint8(p) do
    case Integer.parse(p) do
      {n, ""} when n in 0..255 -> {:ok, n}
      _other -> {:error, :priority_invalid}
    end
  end
  defp password(query) do
    case List.keyfind(query, "password", 0) do
      nil -> {:ok, ""}
      {_, p} when byte_size(p) <= @max_password -> {:ok, p}
      _other -> {:error, :password_invalid}
    end
  end
  defp max_backoff(query) do
    case List.keyfind(query, "maxbackoff", 0) do
      nil ->
        {:ok, @default_backoff_ms}
      {_, ""} ->
        {:ok, @default_backoff_ms}
      {_, d} ->
        case parse_go_duration(d) do
          {:ok, ms} when ms >= @min_backoff_ms -> {:ok, ms}
          _other -> {:error, :max_backoff_invalid}
        end
    end
  end
  defp sni(query, host) do
    from_query =
      case List.keyfind(query, "sni", 0) do
        {_, s} when s != "" -> if ip_literal?(s), do: nil, else: s
        _other -> nil
      end
    cond do
      from_query != nil -> from_query
      ip_literal?(host) -> nil
      true -> host
    end
  end
  defp to_float(num) do
    num = if String.starts_with?(num, "."), do: "0" <> num, else: num
    num = if String.ends_with?(num, "."), do: num <> "0", else: num
    String.to_float(num)
  rescue
    ArgumentError -> num |> String.to_integer() |> Kernel.*(1.0)
  end
  defp unit_ns("ns"), do: 1
  defp unit_ns("us"), do: 1_000
  defp unit_ns("µs"), do: 1_000
  defp unit_ns("ms"), do: 1_000_000
  defp unit_ns("s"), do: 1_000_000_000
  defp unit_ns("m"), do: 60 * 1_000_000_000
  defp unit_ns("h"), do: 3600 * 1_000_000_000
end