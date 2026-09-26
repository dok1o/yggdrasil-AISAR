defmodule Transport.Behaviour do
  @moduledoc "Behaviour defining transport operations contract"
  @type conn :: term()
  @callback send(conn(), iodata()) :: {:ok, conn()} | {:error, term()}
  @callback recv_exact(conn(), pos_integer(), timeout()) ::
              {:ok, binary(), conn()} | {:error, term()}
  @callback recv_stream(conn(), timeout()) :: {:ok, binary(), conn()} | {:error, term()}
  @callback close(conn()) :: :ok
end
defmodule Transport do
  @behaviour Transport.Behaviour
  @type conn :: {:tcp | :utp, pid()}
  @timeout 5_000
  @close_timeout 1_000
  @max_buffer_size 1_024 * 1_024
  def send({type, pid}, data) do
    case GenServer.call(pid, {:wrapped_send, data}, @timeout) do
      :ok -> {:ok, {type, pid}}
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :closed}
  end
  def recv_exact({_type, pid} = conn, bytes, timeout \\ @timeout) do
    case GenServer.call(pid, {:recv, bytes}, timeout) do
      {:ok, data} -> {:ok, data, conn}
      {:error, _reason} = err -> err
    end
  catch
    :exit, _reason -> {:error, :closed}
  end
  def recv_any({_type, pid} = conn, max_size, timeout \\ @timeout) do
    case GenServer.call(pid, {:recv_any, max_size}, timeout) do
      {:ok, data} ->
        {:ok, data, conn}
      :insufficient ->
        recv_exact(conn, 1, timeout)
      {:error, _reason} = err ->
        err
    end
  catch
    :exit, _reason -> {:error, :closed}
  end
  def recv_stream({_type, pid} = conn, timeout \\ @timeout) do
    case GenServer.call(pid, {:recv_stream, @max_buffer_size}, timeout) do
      {:ok, data} -> {:ok, data, conn}
      {:error, _reason} = err -> err
    end
  catch
    :exit, _reason -> {:error, :closed}
  end
  def close({_type, pid} = _conn) do
    try do
      GenServer.stop(pid, :normal, @close_timeout)
    catch
      :exit, _reason -> :ok
    end
  end
end
defmodule SecureTransport do
  @moduledoc """
  Unified transport wrapper handling both plain and encrypted connections.
  Replaces TorrHSTransport with a simpler design that calls Transport directly.
  """
  import TimeSync
  require Logger
  defstruct [:conn, :crypto, buffer: <<>>]
  @type t :: %__MODULE__{
          conn: Transport.conn(),
          crypto: {tuple(), tuple()} | nil,
          buffer: binary()
        }
  @max_pkt_size 1_024 * 1_024 * 2
  @m @max_pkt_size
  @bt_prefix_size 4
  def wrap(conn, crypto \\ nil, buffer \\ <<>>) do
    %__MODULE__{conn: conn, crypto: crypto, buffer: buffer}
  end
  def send(%__MODULE__{conn: conn, crypto: nil} = st, data) do
    case Transport.send(conn, data) do
      {:ok, new_conn} -> {:ok, %{st | conn: new_conn}}
      {:error, _reason} = err -> err
    end
  end
  def send(%__MODULE__{conn: conn, crypto: {enc, dec}} = st, data) do
    {ciphertext, new_enc} = RC4Sync.crypt(enc, :erlang.iolist_to_binary(data))
    case Transport.send(conn, ciphertext) do
      {:ok, new_conn} -> {:ok, %{st | conn: new_conn, crypto: {new_enc, dec}}}
      {:error, _reason} = err -> err
    end
  end
  def recv_exact(%__MODULE__{buffer: buf, conn: conn, crypto: crypto} = st, n, to) do
    case byte_size(buf) >= n do
      true ->
        <<chunk::binary-size(n), rest::binary>> = buf
        {plain, next_crypto} = decrypt(crypto, chunk)
        {:ok, plain, %{st | buffer: rest, crypto: next_crypto}}
      false ->
        needed = n - byte_size(buf)
        case Transport.recv_exact(conn, needed, to) do
          {:ok, n_data, n_conn} ->
            recv_exact(%{st | conn: n_conn, buffer: buf <> n_data}, n, to)
          {:error, reason} ->
            {:error, reason}
        end
    end
  end
  def recv_stream(%__MODULE__{} = st, rem_ms) do
    start_ms = mono_ms()
    case recv_exact(st, @bt_prefix_size, rem_ms) do
      {:ok, <<len::32>>, st} -> recv_body(st, len, remaining_ms(start_ms, rem_ms))
      {:error, reason} -> {:error, reason}
    end
  end
  defp recv_body(st, 0, _to), do: {:ok, <<>>, st}
  defp recv_body(st, len, timeout) when len <= @m, do: recv_exact(st, len, timeout)
  defp recv_body(_st, _len, _to), do: {:error, :buffer_overflow}
  defp decrypt(nil, data), do: {data, nil}
  defp decrypt({enc, dec}, data) do
    {plain, new_dec} = RC4Sync.crypt(dec, data)
    {plain, {enc, new_dec}}
  end
end