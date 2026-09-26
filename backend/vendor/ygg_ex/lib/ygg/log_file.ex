defmodule Ygg.LogFile do
  @moduledoc """
  Log file for the node: attaches an Erlang `logger_std_h` file handler next to the console
  one, so every `Logger` line (links, handshakes, routing summaries) is
  also written to `LogFile` from `ygg.json` (default `log/ygg.log`). Rotated at 10 MB,
  5 files kept. Replaces the `tee`/redirect used for the live runs of stage 1.
  Option `filter:` `:all` (default, the standalone node: every line of the VM) or `:ygg`
  (embedded in another application, `Ygg.Embedded`: only events whose `mfa` metadata names
  `Ygg` or an `Ygg.*` module, which every `Logger` macro call inside ygg_ex carries; OTP
  crash reports of ygg processes come from `gen_server`/`proc_lib` and stay in the host log).
  """
  require Logger
  @handler :ygg_file
  @max_bytes 10 * 1024 * 1024
  @max_files 5
  @format "$date $time [$level] $message\n"
  def handler_id, do: @handler
  @spec attach(Path.t() | nil, keyword()) :: :ok | {:error, term()}
  def attach(path, opts \\ [])
  def attach(nil, _opts), do: :ok
  def attach("", _opts), do: :ok
  def attach(path, opts) do
    id = Keyword.get(opts, :id, @handler)
    full = Path.expand(path)
    config = %{
      file: String.to_charlist(full),
      max_no_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
      max_no_files: Keyword.get(opts, :max_files, @max_files),
      file_check: 1_000
    }
    handler = %{
      level: :all,
      filter_default: :log,
      filters: filters(Keyword.get(opts, :filter, :all)),
      config: config,
      formatter: Logger.Formatter.new(format: @format, metadata: [], colors: [enabled: false])
    }
    with :ok <- File.mkdir_p(Path.dirname(full)),
         :ok <- add(id, handler) do
      :ok
    end
  end
  defp filters(:all), do: []
  defp filters(:ygg), do: [ygg_only: {&__MODULE__.ygg_only/2, []}]
  @doc "Logger filter: passes events logged from `Ygg` / `Ygg.*` modules, stops the rest."
  @spec ygg_only(:logger.log_event(), term()) :: :logger.filter_return()
  def ygg_only(%{meta: %{mfa: {mod, _fun, _arity}}} = event, _arg) when is_atom(mod) do
    if ygg_module?(mod), do: event, else: :stop
  end
  def ygg_only(_event, _arg), do: :stop
  @doc "True for `Ygg` and every `Ygg.*` module."
  @spec ygg_module?(module()) :: boolean()
  def ygg_module?(Ygg), do: true
  def ygg_module?(mod), do: String.starts_with?(Atom.to_string(mod), "Elixir.Ygg.")
  defp add(id, handler) do
    case :logger.add_handler(id, :logger_std_h, handler) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
  @spec detach(atom()) :: :ok | {:error, term()}
  def detach(id \\ @handler) do
    case :logger.remove_handler(id) do
      :ok -> :ok
      {:error, {:not_found, _}} -> :ok
      other -> other
    end
  end
  @doc "Flush buffered lines to disk (the handler writes asynchronously)."
  @spec sync(atom()) :: :ok | {:error, term()}
  def sync(id \\ @handler), do: :logger_std_h.filesync(id)
end