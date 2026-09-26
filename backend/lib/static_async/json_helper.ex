defmodule JsonHelper do
  @type path() :: Path.t()
  @type decoded_item() :: %{atom() => any()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, Jason.decode!(contents, keys: :atoms)}
      {:error, reason} -> err("Failed to read JSON file", path, reason)
    end
  end
  def write(path, data) when is_map(data) and is_binary(path) do
    dir = Path.dirname(path)
    with :ok <- File.mkdir_p(dir),
         {:ok, json_str} <- Jason.encode(data, pretty: true),
         :ok <- File.write(path, json_str) do
      :ok
    else
      {:error, reason} -> err("Failed to write JSON", path, reason)
    end
  end
  def read_l(path) when is_binary(path) do
    contents =
      File.stream!(path, :line)
      |> Stream.map(&String.trim/1)
      |> Stream.filter(&(&1 != ""))
      |> Enum.map(&Jason.decode!(&1, keys: :atoms))
    {:ok, contents}
  end
  def append_l(path, data) when is_map(data) and is_binary(path) do
    json_line = Jason.encode!(data) <> "\n"
    case File.write(path, json_line, [:append, :binary]) do
      :ok -> :ok
      {:error, reason} -> err("Failed to append to JSONL", path, reason)
    end
  end
  defp err(text, path, reason) do
    {:error, text <> "#{inspect(path)}: #{inspect(reason)}"}
  end
end