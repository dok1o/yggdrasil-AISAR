defmodule YggPF.Self do
  @moduledoc """
  This node's own identity, as the SDP layer sees it.

  Two addresses matter and they come from different places:

    * **yaddr** - our Yggdrasil overlay address, from the embedded node via
      `Ygg.self_info/1`. This is what we paint (D-1).
    * **uaddr** - our underlay `ip:port`, from `KeyStorageSync.own_uaddr/0`,
      which `GenS.NATChk` populates once external reachability is known.

  Both are cached in `:persistent_term` because they are read on every scan reply
  and effectively never change for the lifetime of the node. `yaddr/0` caches only
  a successful lookup, so a probe made before the Ygg node has finished starting
  is retried rather than remembered as `nil`.
  """

  require Logger
  alias YggPF.{Codec, Const}

  @painter_key {__MODULE__, :painter}
  @unknown_uaddr <<0, 0, 0, 0, 0, 0>>

  @doc "Our 144-bit painter address, or `nil` if the Ygg node is not up yet."
  @spec painter_address() :: binary() | nil
  def painter_address do
    case :persistent_term.get(@painter_key, :miss) do
      :miss ->
        painter = compute_painter_address()
        if painter, do: :persistent_term.put(@painter_key, painter)
        painter

      painter ->
        painter
    end
  end

  @doc "Our own yaddr as `{ip6_tuple, port}`, or `nil`."
  @spec yaddr() :: Codec.yaddr() | nil
  def yaddr do
    case painter_address() do
      nil ->
        nil

      painter ->
        case Codec.parse_painter_address(painter) do
          {:ok, y} -> y
          :error -> nil
        end
    end
  end

  @doc """
  Is this reconstructed yaddr our own?

  Compares the address only, ignoring the port, so a peer that painted us with a
  different port still registers as self rather than as a stranger.
  """
  @spec own_yaddr?(Codec.yaddr() | :inet.ip6_address() | nil) :: boolean()
  def own_yaddr?(nil), do: false
  def own_yaddr?({ip, _port}), do: own_yaddr?(ip)

  def own_yaddr?({_, _, _, _, _, _, _, _} = ip) do
    case yaddr() do
      {own_ip, _port} -> own_ip == ip
      nil -> false
    end
  end

  def own_yaddr?(_other), do: false

  @doc "Our own underlay address, or `nil` when NAT detection has not completed."
  @spec uaddr() :: binary() | nil
  def uaddr do
    case KeyStorageSync.own_uaddr() do
      @unknown_uaddr -> nil
      <<_::binary-6>> = u -> u
      _other -> nil
    end
  end

  @doc """
  Is this underlay address ours?

  Always `false` while our own uaddr is unknown - an unknown self must never make a
  remote node look like us, because that would suppress a genuine discovery.
  """
  @spec own_uaddr?(binary() | nil) :: boolean()
  def own_uaddr?(nil), do: false

  def own_uaddr?(<<_::binary-6>> = candidate) do
    case uaddr() do
      nil -> false
      own -> own == candidate
    end
  end

  def own_uaddr?(_other), do: false

  @doc """
  Attribute a finding to its origin: did it come back from us, or from someone else?

  This is what makes a self-sighting meaningful. Our own paint echoing out of our
  own routing table proves nothing. The *same* yid returned by a remote node is
  evidence that the paint propagated and that we are genuinely discoverable by
  third parties - which is the single most useful health signal the scanner has.

    * `:self`    - every responder we can identify is us
    * `:other`   - at least one responder is a different node
    * `:unknown` - no responder was recorded, or our own uaddr is not known yet,
      so the finding cannot be attributed either way

  `:unknown` is deliberately distinct from `:self`: silently treating an
  unattributable sighting as a local echo would hide real propagation.
  """
  @spec origin([binary() | nil]) :: :self | :other | :unknown
  def origin(responders) when is_list(responders) do
    known = Enum.reject(responders, &is_nil/1)

    cond do
      known == [] -> :unknown
      is_nil(uaddr()) -> :unknown
      Enum.all?(known, &own_uaddr?/1) -> :self
      true -> :other
    end
  end

  def origin(_other), do: :unknown

  @doc false
  def reset_cache, do: :persistent_term.erase(@painter_key)

  # `Ygg.self_info/1` reports a *formatted* address string and a *hex* key, not raw
  # binaries - parse rather than pattern match.
  @doc """
  Human-readable reason our own Yggdrasil address could not be determined.

  Painting is impossible without it, and the failure is otherwise completely
  silent, so the reason is surfaced verbatim rather than collapsed to "unavailable".
  """
  @spec explain_unavailable() :: String.t()
  def explain_unavailable do
    case safe_self_info() do
      {:ok, %{address: addr}} when is_binary(addr) ->
        "Ygg.self_info/1 returned address #{inspect(addr)} but it does not parse as IPv6"

      {:ok, %{} = info} ->
        "Ygg.self_info/1 returned a map without an :address key - keys: " <>
          inspect(Map.keys(info))

      {:ok, {:error, :not_running}} ->
        "the embedded Yggdrasil node is not running (Ygg.self_info/1 -> {:error, :not_running})"

      {:ok, other} ->
        "Ygg.self_info/1 returned #{inspect(other)}"

      {:error, reason} ->
        "Ygg.self_info/1 raised or exited: #{inspect(reason)}"
    end
  end

  defp safe_self_info do
    {:ok, Ygg.self_info()}
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp compute_painter_address do
    case Ygg.self_info() do
      %{address: addr} when is_binary(addr) ->
        case :inet.parse_ipv6_address(String.to_charlist(addr)) do
          {:ok, ip} ->
            Codec.painter_address(ip, Const.ygg_pf_port())

          {:error, _} ->
            Logger.warning("[YggPF] cannot parse own Ygg address #{inspect(addr)}")
            nil
        end

      _unavailable ->
        Logger.debug("[YggPF] own Ygg address not available yet")
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
