defmodule Ygg.Meta do
  @moduledoc """
  The `meta` handshake exchanged right after a TCP/TLS link is established.
  Ports `reference/yggdrasil-go/src/core/version.go`: `version_metadata`, `version_getBaseMetadata`,
  `encode` (version.go:59-96), `decode` (version.go:99-170), `check` (version.go:173-184)
  and the `ErrHandshake*` errors. Wire layout (big-endian): `"meta"`, uint16 length of the
  rest, then `op:uint16 len:uint16 value` fields (0 major, 1 minor, 2 public key, 3 priority),
  then a 64-byte ed25519 signature over BLAKE2b-512(key = password, data = public key).
  Unknown ops are skipped; every known op has a fixed length; trailing bytes are an error.
  The password hash: with an empty password keyed BLAKE2b equals plain BLAKE2b-512, which
  `:crypto.hash(:blake2b, pub)` provides. OTP has no keyed BLAKE2b, so a non-empty password
  is rejected here (extension point `password_hash/2`); public peers do not use passwords.
  The 64-byte password limit is `link.go:201` (`len(p) > blake2b.Size`).
  """
  alias Ygg.Identity
  @compile {:inline, [parse_header: 1, password_hash: 2]}
  @preamble "meta"
  @header_size 6
  @sig_size 64
  @key_size 32
  @major 0
  @minor 5
  @op_major 0
  @op_minor 1
  @op_key 2
  @op_priority 3
  @max_password 64
  @type t :: %{
          major: non_neg_integer(),
          minor: non_neg_integer(),
          pubkey: binary() | nil,
          priority: byte()
        }
  @type error ::
          :invalid_preamble
          | :invalid_length
          | :invalid_password
          | :hash_failure
          | :incorrect_password
          | :password_unsupported
  def header_size, do: @header_size
  def protocol_version, do: {@major, @minor}
  @spec base() :: t()
  def base, do: %{major: @major, minor: @minor, pubkey: nil, priority: 0}
  @doc "Our handshake block: base version, our key, the link priority (link.go:628-631)."
  @spec encode_local(Identity.t(), byte(), binary()) :: {:ok, binary()} | {:error, error()}
  def encode_local(%Identity{pub: pub} = id, priority, password),
    do: encode(%{base() | pubkey: pub, priority: priority}, id, password)
  @spec encode(t(), Identity.t(), binary()) :: {:ok, binary()} | {:error, error()}
  def encode(
        %{major: major, minor: minor, pubkey: pub, priority: prio},
        %Identity{} = id,
        password
      )
      when byte_size(pub) == @key_size do
    with {:ok, hash} <- password_hash(password, pub) do
      body =
        <<@op_major::16, 2::16, major::16, @op_minor::16, 2::16, minor::16, @op_key::16,
          @key_size::16, pub::binary, @op_priority::16, 1::16, prio>> <> Identity.sign(id, hash)
      {:ok, <<@preamble, byte_size(body)::16, body::binary>>}
    end
  end
  @doc "First 6 bytes: preamble check and the body length that follows (version.go:100-111)."
  @spec parse_header(binary()) :: {:ok, non_neg_integer()} | {:error, error()}
  def parse_header(<<@preamble, hl::16>>) when hl >= @sig_size, do: {:ok, hl}
  def parse_header(<<@preamble, _hl::16>>), do: {:error, :invalid_length}
  def parse_header(<<_::binary-size(@header_size)>>), do: {:error, :invalid_preamble}
  def parse_header(_short), do: {:error, :invalid_length}
  @doc "Whole block (header + body), convenience for tests and buffers."
  @spec decode(binary(), binary()) :: {:ok, t()} | {:error, error()}
  def decode(<<header::binary-size(@header_size), rest::binary>>, password) do
    with {:ok, hl} <- parse_header(header) do
      case rest do
        <<body::binary-size(hl)>> -> decode_body(body, password)
        _other -> {:error, :invalid_length}
      end
    end
  end
  def decode(_short, _password), do: {:error, :invalid_length}
  @doc "The `hl` bytes after the header (version.go:112-169)."
  @spec decode_body(binary(), binary()) :: {:ok, t()} | {:error, error()}
  def decode_body(body, password) when byte_size(body) >= @sig_size do
    fields_len = byte_size(body) - @sig_size
    <<fields::binary-size(fields_len), sig::binary-size(@sig_size)>> = body
    with {:ok, meta} <- fields(fields, %{base() | major: 0, minor: 0}),
         :ok <- validate_password(password),
         {:ok, hash} <- password_hash(password, meta.pubkey) do
      if Identity.verify(meta.pubkey, hash, sig),
        do: {:ok, meta},
        else: {:error, :incorrect_password}
    end
  end
  def decode_body(_body, _password), do: {:error, :invalid_length}
  @doc "Version and key sanity (version.go:173-184)."
  @spec check(t()) :: boolean()
  def check(%{major: @major, minor: @minor, pubkey: <<_::binary-size(@key_size)>>}), do: true
  def check(_meta), do: false
  @spec validate_password(binary()) :: :ok | {:error, :invalid_password}
  def validate_password(password) when byte_size(password) <= @max_password, do: :ok
  def validate_password(_password), do: {:error, :invalid_password}
  @spec password_hash(binary(), binary() | nil) :: {:ok, <<_::512>>} | {:error, error()}
  def password_hash(_password, pub) when not (is_binary(pub) and byte_size(pub) == @key_size),
    do: {:error, :hash_failure}
  def password_hash(<<>>, pub), do: {:ok, :crypto.hash(:blake2b, pub)}
  def password_hash(_password, _pub), do: {:error, :password_unsupported}
  defp fields(<<>>, meta), do: {:ok, meta}
  defp fields(<<op::16, oplen::16, rest::binary>>, meta) when byte_size(rest) >= oplen do
    <<field::binary-size(oplen), rest::binary>> = rest
    case field(op, field, meta) do
      {:ok, meta} -> fields(rest, meta)
      {:error, _} = err -> err
    end
  end
  defp fields(_bad, _meta), do: {:error, :invalid_length}
  defp field(@op_major, <<v::16>>, meta), do: {:ok, %{meta | major: v}}
  defp field(@op_minor, <<v::16>>, meta), do: {:ok, %{meta | minor: v}}
  defp field(@op_key, <<k::binary-size(@key_size)>>, meta), do: {:ok, %{meta | pubkey: k}}
  defp field(@op_priority, <<p>>, meta), do: {:ok, %{meta | priority: p}}
  defp field(op, _bad, _meta) when op in [@op_major, @op_minor, @op_key, @op_priority],
    do: {:error, :invalid_length}
  defp field(_unknown, _field, meta), do: {:ok, meta}
end