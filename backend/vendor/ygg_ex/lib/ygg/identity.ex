defmodule Ygg.Identity do
  @moduledoc """
  Node identity: ed25519 key pair plus the derived Yggdrasil address and subnet.
  Ports `reference/yggdrasil-go/src/config/config.go` `NewPrivateKey` (config.go:204-210) and the `KeyBytes`
  hex JSON form (config.go:247-261): `PrivateKey` in `ygg.json` is the Go `ed25519.PrivateKey`
  layout, 64 bytes = seed(32) ++ public(32), hex encoded, so a key made by
  `yggdrasil -genconf` works here and vice versa. The key *file* (`PrivateKeyFile`) holds
  only the 32-byte seed as 64 hex characters (`load_or_create/1`); both forms are accepted
  on input (`from_hex/1`), the public key is always recomputed from the seed. Also `core.New` key checks
  (core.go:83-90) and `Core.Address`/`Core.Subnet` (api.go) via `Ygg.Address`.
  Signing uses `:crypto.sign(:eddsa, :none, msg, [seed, :ed25519])` (Go `ed25519.Sign`).
  `inspect/1` leaves out the seed, so it stays out of logs and crash reports (process state).
  """
  alias Ygg.Address
  @compile {:inline, [sign: 2, verify: 3, pub_hex: 1]}
  @seed_size 32
  @pub_size 32
  @priv_size 64
  @derive {Inspect, except: [:seed]}
  defstruct [:seed, :pub, :address, :subnet]
  @type t :: %__MODULE__{
          seed: <<_::256>>,
          pub: <<_::256>>,
          address: <<_::128>>,
          subnet: <<_::64>>
        }
  @spec generate() :: t()
  def generate do
    {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)
    build(seed, pub)
  end
  @doc """
  From the 32-byte seed (the key everything derives from: public key, then address) or
  the 64-byte Go ed25519.PrivateKey (seed ++ public, checked for consistency).
  """
  @spec from_private(binary()) :: {:ok, t()} | {:error, :invalid_length | :key_mismatch}
  def from_private(<<seed::binary-size(@seed_size), pub::binary-size(@pub_size)>>) do
    case :crypto.generate_key(:eddsa, :ed25519, seed) do
      {^pub, ^seed} -> {:ok, build(seed, pub)}
      _other -> {:error, :key_mismatch}
    end
  end
  def from_private(<<seed::binary-size(@seed_size)>>) do
    {pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {:ok, build(seed, pub)}
  end
  def from_private(_bin), do: {:error, :invalid_length}
  @spec from_hex(String.t()) ::
          {:ok, t()} | {:error, :invalid_hex | :invalid_length | :key_mismatch}
  def from_hex(hex) when is_binary(hex) do
    case Base.decode16(String.trim(hex), case: :mixed) do
      {:ok, bin} -> from_private(bin)
      :error -> {:error, :invalid_hex}
    end
  end
  @spec to_private(t()) :: <<_::512>>
  def to_private(%__MODULE__{seed: seed, pub: pub}), do: seed <> pub
  @spec to_hex(t()) :: String.t()
  def to_hex(%__MODULE__{} = id), do: Base.encode16(to_private(id), case: :lower)
  @doc "The 32-byte seed as 64 hex characters, the key file format."
  @spec to_seed_hex(t()) :: String.t()
  def to_seed_hex(%__MODULE__{seed: seed}), do: Base.encode16(seed, case: :lower)
  @spec pub_hex(t() | binary()) :: String.t()
  def pub_hex(%__MODULE__{pub: pub}), do: Base.encode16(pub, case: :lower)
  def pub_hex(pub) when is_binary(pub), do: Base.encode16(pub, case: :lower)
  @doc """
  Reads the key file, or generates a new key and writes it (created empty with mode 0600
  before the key goes in, never over an existing file). The file holds the
  32-byte seed as 64 hex characters, the key the Yggdrasil address is derived from; a
  128-character file in the Go `PrivateKey` layout (`yggdrasil -genconf`) is read as well.
  """
  @spec load_or_create(Path.t()) :: {:ok, t(), :loaded | :created} | {:error, term()}
  def load_or_create(path) do
    case File.read(path) do
      {:ok, hex} ->
        case from_hex(hex) do
          {:ok, id} -> {:ok, id, :loaded}
          {:error, reason} -> {:error, {:bad_key_file, path, reason}}
        end
      {:error, :enoent} ->
        id = generate()
        with :ok <- write_private(path, to_seed_hex(id) <> "\n", [:write, :exclusive]) do
          {:ok, id, :created}
        end
      {:error, reason} ->
        {:error, {:read_key_file, path, reason}}
    end
  end
  @doc """
  Appends our key to the collected-keys text file (`KeysFile` in `ygg.json`, default
  `keys_collected.txt`, mode 0600): one line per key,
  `<iso8601> <how> pub=<hex> priv=<hex>`. A pub already present is not written again
  (`:exists`). Only keys this program generated or loaded end up here; a node never sees a
  peer's private key, peers are known by public key only (see the routing log).
  """
  @spec record(Path.t() | nil, t(), atom()) :: :ok | :exists | {:error, term()}
  def record(nil, _id, _how), do: :ok
  def record("", _id, _how), do: :ok
  def record(path, %__MODULE__{} = id, how) do
    pub = pub_hex(id)
    existing =
      case File.read(path) do
        {:ok, text} -> text
        {:error, _} -> ""
      end
    if String.contains?(existing, "pub=" <> pub) do
      :exists
    else
      line =
        "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{how} pub=#{pub} priv=#{to_hex(id)}\n"
      write_private(path, line, [:append])
    end
  end
  defp write_private(path, data, modes) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(path))),
         {:ok, dev} <- File.open(path, [:binary | modes]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(dev, data)
      after
        File.close(dev)
      end
    end
  end
  @spec sign(t(), iodata()) :: <<_::512>>
  def sign(%__MODULE__{seed: seed}, msg), do: :crypto.sign(:eddsa, :none, msg, [seed, :ed25519])
  @spec verify(<<_::256>>, iodata(), binary()) :: boolean()
  def verify(<<pub::binary-size(@pub_size)>>, msg, <<sig::binary-size(64)>>),
    do: :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])
  def verify(_pub, _msg, _sig), do: false
  def private_size, do: @priv_size
  defp build(seed, pub) do
    %__MODULE__{
      seed: seed,
      pub: pub,
      address: Address.addr_for_key(pub),
      subnet: Address.subnet_for_key(pub)
    }
  end
end