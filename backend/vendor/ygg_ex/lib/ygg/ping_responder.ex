defmodule Ygg.PingResponder do
  @moduledoc """
  Answers ICMPv6 echo requests (`ping`) that other Yggdrasil nodes send to our address, so a
  no-TUN sub-node is pingable from the real network. Yggdrasil session traffic is one type
  byte then the raw IPv6 packet (`reference/yggdrasil-go/src/core/core.go` `ReadFrom`/`WriteTo`: `typeSessionTraffic`
  = 1, `typeSessionProto` = 2 for nodeinfo/debug requests, which are only logged here).
  The receiving side (`reference/yggdrasil-go/_other/src/ipv6rwc/ipv6rwc.go:265-275`) requires the IPv6 source to
  match the sender key's address or /64 subnet and the destination to be its own, so the
  reply swaps the addresses of the request and goes back to the key the request came from.
  Subscribes to `Ygg.Datagram` (proto requests are answered by `Ygg.Core`, which does not
  forward them); started by `Ygg.Datagram.child_specs/1` for every router but the stub.
  """
  use GenServer
  import Bitwise
  require Logger
  alias Ygg.{Address, Datagram, Identity, Node}
  @session_traffic 1
  @session_proto 2
  @icmpv6 58
  @echo_request 128
  @echo_reply 129
  @hop_limit 64
  defstruct [:ctx, pings: 0, replies: 0, proto: 0, other: 0]
  def start_link(ctx), do: GenServer.start_link(__MODULE__, ctx, name: Node.via(ctx, __MODULE__))
  @spec stats(Node.t()) :: map()
  def stats(ctx), do: GenServer.call(Node.via(ctx, __MODULE__), :stats)
  @impl true
  def init(%Node{} = ctx), do: {:ok, %__MODULE__{ctx: ctx}, {:continue, :subscribe}}
  @impl true
  def handle_continue(:subscribe, %{ctx: ctx} = st) do
    case Datagram.subscribe(ctx, self()) do
      :ok -> {:noreply, st}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}, st}
    end
  end
  @impl true
  def handle_call(:stats, _from, st),
    do: {:reply, Map.take(st, [:pings, :replies, :proto, :other]), st}
  @impl true
  def handle_info({:ygg_traffic, _node, src_key, <<@session_traffic, packet::binary>>}, st) do
    %{ctx: ctx} = st
    case reply_for(packet, ctx.identity) do
      {:ok, reply, info} ->
        st = %{st | pings: st.pings + 1}
        case Datagram.send(ctx, src_key, <<@session_traffic, reply::binary>>) do
          :ok ->
            Logger.info(
              "Ping from #{info.from} (key #{short(src_key)}) id=#{info.id} seq=#{info.seq} " <>
                "#{info.bytes}B: replied"
            )
            {:noreply, %{st | replies: st.replies + 1}}
          {:error, reason} ->
            Logger.warning("Ping from #{info.from}: cannot reply, #{inspect(reason)}")
            {:noreply, st}
        end
      {:error, reason} ->
        Logger.debug("IPv6 packet from #{short(src_key)} not answered: #{inspect(reason)}")
        {:noreply, %{st | other: st.other + 1}}
      :ignore ->
        {:noreply, %{st | other: st.other + 1}}
    end
  end
  def handle_info({:ygg_traffic, _node, src_key, <<@session_proto, rest::binary>>}, st) do
    Logger.debug(
      "Session proto request from #{short(src_key)} (#{byte_size(rest)}B), not supported"
    )
    {:noreply, %{st | proto: st.proto + 1}}
  end
  def handle_info({:ygg_traffic, _node, _src_key, _other}, st),
    do: {:noreply, %{st | other: st.other + 1}}
  def handle_info(_msg, st), do: {:noreply, st}
  @doc """
  Pure: the echo reply for an IPv6/ICMPv6 echo request addressed to our address or subnet.
  `:ignore` for anything that is not ICMPv6, `{:error, _}` for ICMPv6 we do not answer.
  """
  @spec reply_for(binary(), Identity.t()) :: {:ok, binary(), map()} | :ignore | {:error, term()}
  def reply_for(
        <<6::4, tc::8, flow::20, plen::16, @icmpv6, _hop, src::binary-size(16),
          dst::binary-size(16), icmp::binary>>,
        %Identity{address: addr, subnet: subnet}
      )
      when byte_size(icmp) == plen do
    cond do
      dst != addr and binary_part(dst, 0, 8) != subnet ->
        {:error, {:not_for_us, Address.format(dst)}}
      true ->
        case icmp do
          <<@echo_request, 0, _csum::16, id::16, seq::16, data::binary>> ->
            body = <<@echo_reply, 0, 0::16, id::16, seq::16, data::binary>>
            csum = checksum(dst, src, body)
            <<head::binary-size(2), _::16, tail::binary>> = body
            body = <<head::binary, csum::16, tail::binary>>
            reply =
              <<6::4, tc::8, flow::20, plen::16, @icmpv6, @hop_limit, dst::binary, src::binary,
                body::binary>>
            {:ok, reply, %{from: Address.format(src), id: id, seq: seq, bytes: byte_size(data)}}
          <<type, code, _::binary>> ->
            {:error, {:icmpv6, type, code}}
          _ ->
            {:error, :icmpv6_short}
        end
    end
  end
  def reply_for(_packet, _id), do: :ignore
  @doc "ICMPv6 checksum (RFC 4443 §2.3) over the IPv6 pseudo-header and the message."
  @spec checksum(<<_::128>>, <<_::128>>, binary()) :: 0..0xFFFF
  def checksum(src, dst, icmp) do
    pseudo = <<src::binary, dst::binary, byte_size(icmp)::32, 0, 0, 0, @icmpv6>>
    sum = sum16(pseudo <> icmp, 0)
    bxor(fold(sum), 0xFFFF)
  end
  defp sum16(<<w::16, rest::binary>>, acc), do: sum16(rest, acc + w)
  defp sum16(<<b>>, acc), do: acc + (b <<< 8)
  defp sum16(<<>>, acc), do: acc
  defp fold(sum) when sum > 0xFFFF, do: fold((sum &&& 0xFFFF) + (sum >>> 16))
  defp fold(sum), do: sum
  defp short(key), do: key |> Identity.pub_hex() |> binary_part(0, 8)
end