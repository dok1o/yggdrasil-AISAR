defmodule YggPF.YggProbe do
  @moduledoc """
  The yaddr validation path (spec sections 30, 34, 35).

  ## Why this is stronger than an IP probe

  The vendored Yggdrasil stack is **key-addressed**, not address-addressed:
  `Ygg.send_traffic(key, payload)` delivers to a 32-byte public key, and subscribers
  receive `{:ygg_traffic, node_id, src_key, payload}` where `src_key` has been
  authenticated by Yggdrasil's end-to-end cryptography.

  Since `fid` *is* the Ygg public key (spec section 11), a `pong` arriving over Ygg from
  `src_key == fid` is cryptographic proof that the peer holds the private key for the
  identity it claims. That is exactly the fork protection spec section 34 asks for, and it is
  far harder to forge than answering a UDP ping.

  ## Recovering fid from a painted yaddr

  A painted yaddr is a 128-bit truncation of the key, so it does not contain the whole
  `fid`. `Ygg.Address.addr_get_key/1` recovers the known prefix bits (the rest are 1s),
  and `Ygg.lookup/2` accepts a partial key. So:

      painted yaddr -> addr_get_key -> partial key -> Ygg.lookup -> full fid
                    -> send pingx over Ygg -> authenticated pong -> trusted

  ## Fixed port

  Spec section 30's fixed port (`YggPF.Const.ygg_pf_port/0`) identifies the ygg_pf service
  inside the painter address. Ygg delivery itself is key-addressed, so the port is
  carried as payload metadata rather than used for socket addressing.
  """

  use GenServer
  require Logger

  alias YggPF.{Const, Wire}

  @lookup_timeout 10_000

  defstruct fid: nil, inflight: %{}, scanner: nil

  # ------------------------------------------------------------------ #
  # API                                                                 #
  # ------------------------------------------------------------------ #

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: name(opts))
  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @doc """
  Probe a candidate over Yggdrasil.

  Accepts either a full 32-byte `fid` (when a uaddr pong already revealed it) or a
  reconstructed yaddr, which is resolved to a key first.
  """
  def pingx(target, port \\ Const.ygg_pf_port(), fid \\ nil),
    do: GenServer.cast(__MODULE__, {:pingx, target, port, fid})

  @doc "Resolve a painted yaddr to a full fid via the Ygg router. Blocking."
  def resolve(yaddr_bin) when is_binary(yaddr_bin), do: do_resolve(yaddr_bin)

  # ------------------------------------------------------------------ #
  # Callbacks                                                           #
  # ------------------------------------------------------------------ #

  @impl true
  def init(opts) do
    send(self(), :subscribe)

    {:ok,
     %__MODULE__{
       fid: Keyword.get(opts, :fid, local_fid()),
       scanner: Keyword.get(opts, :scanner, GenS.YggPFScanner)
     }}
  end

  @impl true
  def handle_cast({:pingx, _target, _port, <<fid::binary-32>>}, st) do
    {:noreply, maybe_track_ping(fid, st)}
  end

  def handle_cast({:pingx, yaddr_bin, _port, nil}, st) when is_binary(yaddr_bin) do
    case do_resolve(yaddr_bin) do
      {:ok, fid} ->
        {:noreply, maybe_track_ping(fid, st)}

      {:error, reason} ->
        Logger.debug("[YggPF.YggProbe] cannot resolve yaddr: #{inspect(reason)}")
        {:noreply, st}
    end
  end

  def handle_cast(_other, st), do: {:noreply, st}

  @impl true
  def handle_info(:subscribe, st) do
    case safe(fn -> Ygg.subscribe_traffic() end) do
      {:ok, :ok} -> Logger.info("[YggPF.YggProbe] subscribed to Ygg traffic")
      result ->
        Logger.debug("[YggPF.YggProbe] waiting for Ygg traffic: #{inspect(result)}")
        Process.send_after(self(), :subscribe, 5_000)
    end

    {:noreply, st}
  end

  # src_key is authenticated by Yggdrasil - this is the trusted promotion path.
  def handle_info({:ygg_traffic, _node_id, <<src_key::binary-32>>, payload}, st) do
    case Wire.parse(payload) do
      {:ok, %{version: 2, opcode: 0x0001, tx_id: tx_id}} ->
        if fid = st.fid || local_fid() do
          _ = safe(fn -> Ygg.send_traffic(src_key, Wire.pong(fid, tx_id)) end)
        end

        {:noreply, st}

      {:ok, %{version: 2, opcode: 0x4001, fid: fid}} when fid == src_key ->
        yaddr = derive_yaddr(src_key)
        GenS.YggPFScanner.pf_packet_ygg(st.scanner, payload, yaddr)
        {:noreply, %{st | inflight: Map.delete(st.inflight, src_key)}}

      {:ok, %{version: 2, opcode: 0x4001, fid: other_fid}} ->
        # The payload claims a different identity than the authenticated sender.
        Logger.warning(
          "[YggPF.YggProbe] fid/src_key mismatch: payload claims " <>
            "#{short(other_fid)} but Ygg authenticated #{short(src_key)} - dropping"
        )

        {:noreply, st}

      _other ->
        {:noreply, st}
    end
  end

  def handle_info(_other, st), do: {:noreply, st}

  # ------------------------------------------------------------------ #
  # Internals                                                           #
  # ------------------------------------------------------------------ #

  defp maybe_track_ping(fid, st) do
    case send_pingx(fid, st) do
      :ok -> put_in(st.inflight[fid], now_ms())
      _failed -> st
    end
  end

  defp send_pingx(fid, st) do
    case st.fid || local_fid() do
      nil -> {:error, :local_fid_unavailable}
      own_fid -> send_pingx_with_fid(fid, own_fid)
    end
  end

  defp send_pingx_with_fid(fid, own_fid) do
    packet = Wire.build(<<0::32>>, own_fid, Const.opcode_ping())

    case safe(fn -> Ygg.send_traffic(fid, packet) end) do
      {:ok, :ok} -> :ok
      failed ->
        Logger.debug("[YggPF.YggProbe] send to #{short(fid)} failed: #{inspect(failed)}")
        {:error, failed}
    end
  end

  # Painted yaddr -> full 32-byte fid.
  #
  # `Ygg.lookup/2` is asynchronous: it returns `:ok` and asks the router to find a
  # path, it does not hand back a key. So resolution is two-phase - first check the
  # keys the router already knows, and if the node is not there yet, kick off a
  # lookup and report `:pending` so the caller retries on a later cycle rather than
  # blocking (spec section 45: never block forever).
  defp do_resolve(<<_::binary-16>> = yaddr_bin) do
    case find_known_key(yaddr_bin) do
      {:ok, fid} ->
        {:ok, fid}

      :error ->
        _ = safe(fn -> Ygg.lookup(Ygg.Address.addr_get_key(yaddr_bin)) end)
        {:error, :pending}
    end
  end

  defp do_resolve(_bad), do: {:error, :bad_yaddr}

  # A painted yaddr is a truncation of the key, so the only reliable test is to
  # re-derive the address from each key the router knows and compare.
  defp find_known_key(yaddr_bin) do
    case safe(fn -> Ygg.routing() end) do
      {:ok, %{} = dump} ->
        dump
        |> collect_keys()
        |> Enum.find_value(:error, fn fid ->
          case Ygg.Address.addr_for_key(fid) == yaddr_bin do
            true -> {:ok, fid}
            false -> nil
          end
        end)

      _unavailable ->
        :error
    end
  end

  # The dump shape varies by router (peers / tree / paths / sessions), so walk it
  # generically and pick up anything that looks like a 32-byte key.
  defp collect_keys(term), do: term |> do_collect([]) |> Enum.uniq()

  defp do_collect(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {k, v}, a -> do_collect(v, do_collect(k, a)) end)

  defp do_collect(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &do_collect/2)

  defp do_collect(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> do_collect(acc)

  defp do_collect(<<key::binary-32>>, acc), do: [key | acc]

  defp do_collect(<<hex::binary-64>>, acc) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, key} -> [key | acc]
      :error -> acc
    end
  end

  defp do_collect(_other, acc), do: acc

  defp derive_yaddr(key) do
    case Ygg.Address.addr_for_key(key) do
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> ->
        {{a, b, c, d, e, f, g, h}, Const.ygg_pf_port()}

      _other ->
        nil
    end
  end

  # `Ygg.self_info/1` reports the key as hex (`Ygg.Identity.pub_hex/1`), not raw bytes.
  defp local_fid do
    case safe(fn -> Ygg.self_info() end) do
      {:ok, %{key: hex}} when is_binary(hex) ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, <<fid::binary-32>>} -> fid
          _not_a_key -> nil
        end

      _unavailable ->
        nil
    end
  end

  # The Ygg node may not be running; never let that crash the probe.
  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp short(k), do: k |> Base.encode16(case: :lower) |> binary_part(0, 12)
  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc false
  def lookup_timeout, do: @lookup_timeout
end
