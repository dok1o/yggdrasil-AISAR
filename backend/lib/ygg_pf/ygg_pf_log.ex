defmodule YggPF.Log do
  @moduledoc """
  Distinguishable bootstrap failure conditions (spec sections 41-45).

  Spec section 41 is explicit: these must not collapse into a generic "bootstrap failed".
  Each condition points at a different root cause and a different user action, so
  `classify/1` returns them as distinct tagged tuples and `report/1` logs each with
  its own message.

  | Condition | Meaning | Spec |
  |---|---|---|
  | `:wall_clock_desync` | epoch scheme fails, fixed-prefix fallback works | 42 |
  | `:too_few_yaddrs` | fewer than 4 reachable yaddrs - degraded, not fatal | 43 |
  | `:no_new_candidates` | nothing new, but a prior-run cache exists | 44 |
  | `:no_candidates_no_dht` | 20s+, no candidates, no DHT bootstrap | 45 |

  `classify/1` is pure, so the whole taxonomy is testable without a running node.
  """

  require Logger
  alias YggPF.Const

  @type state :: %{
          optional(:epoch_candidates) => non_neg_integer(),
          optional(:fixed_candidates) => non_neg_integer(),
          optional(:reachable_yaddrs) => non_neg_integer(),
          optional(:new_candidates) => non_neg_integer(),
          optional(:cached_fnodes) => non_neg_integer(),
          optional(:dht_booted?) => boolean(),
          optional(:elapsed_ms) => non_neg_integer()
        }

  @type condition ::
          {:wall_clock_desync, map()}
          | {:too_few_yaddrs, map()}
          | {:no_new_candidates, map()}
          | {:no_candidates_no_dht, map()}

  @doc """
  Classify the current bootstrap state into zero or more distinct conditions.

  Conditions are independent - more than one can hold at once, and each is reported
  separately rather than being folded into a single verdict.
  """
  @spec classify(state()) :: [condition()]
  def classify(state) when is_map(state) do
    []
    |> maybe_wall_clock_desync(state)
    |> maybe_too_few_yaddrs(state)
    |> maybe_no_new_candidates(state)
    |> maybe_no_candidates_no_dht(state)
    |> Enum.reverse()
  end

  # spec section 42 - the epoch-dependent scheme finds nothing while the epoch-independent
  # fixed prefix does. Both paths use the same DHT, the same encoding and the same
  # peers; the only variable that distinguishes them is the epoch term in the
  # prefix. So this asymmetry points squarely at the system clock.
  defp maybe_wall_clock_desync(acc, %{epoch_candidates: 0, fixed_candidates: f} = s)
       when is_integer(f) and f > 0 do
    [{:wall_clock_desync, Map.take(s, [:epoch_candidates, :fixed_candidates])} | acc]
  end

  defp maybe_wall_clock_desync(acc, _state), do: acc

  # spec section 43 - degraded discovery, explicitly not total failure.
  defp maybe_too_few_yaddrs(acc, %{reachable_yaddrs: n} = s) when is_integer(n) do
    case n < Const.min_reachable_yaddrs() do
      true -> [{:too_few_yaddrs, Map.take(s, [:reachable_yaddrs])} | acc]
      false -> acc
    end
  end

  defp maybe_too_few_yaddrs(acc, _state), do: acc

  # spec section 44 - nothing new, but we are not starting from nothing. Cached state may
  # still be usable, so this is a visibility warning rather than a failure.
  defp maybe_no_new_candidates(acc, %{new_candidates: 0, cached_fnodes: c} = s)
       when is_integer(c) and c > 0 do
    [{:no_new_candidates, Map.take(s, [:cached_fnodes])} | acc]
  end

  defp maybe_no_new_candidates(acc, _state), do: acc

  # spec section 45 - hard network/bootstrap failure. Must not block forever.
  defp maybe_no_candidates_no_dht(acc, %{elapsed_ms: ms} = s) when is_integer(ms) do
    if ms >= Const.no_boot_deadline_ms() and
         Map.get(s, :new_candidates, 0) == 0 and
         Map.get(s, :dht_booted?, false) == false do
      [{:no_candidates_no_dht, Map.take(s, [:elapsed_ms])} | acc]
    else
      acc
    end
  end

  defp maybe_no_candidates_no_dht(acc, _state), do: acc

  @doc "Classify and log. Returns the conditions so callers can act on them."
  @spec report(state()) :: [condition()]
  def report(state) do
    conditions = classify(state)
    Enum.each(conditions, &log/1)
    conditions
  end

  defp log({:wall_clock_desync, d}) do
    Logger.error(
      "[YggPF] WALL CLOCK DESYNC SUSPECTED: epoch-derived prefixes yielded 0 candidates " <>
        "but the epoch-independent fixed prefix yielded #{d.fixed_candidates}. " <>
        "The 1-minute epoch is shared state - check system clock synchronisation (NTP)."
    )
  end

  defp log({:too_few_yaddrs, d}) do
    Logger.warning(
      "[YggPF] DEGRADED DISCOVERY: only #{d.reachable_yaddrs} reachable yaddr(s), " <>
        "below the minimum of #{Const.min_reachable_yaddrs()}. " <>
        "Discovery continues; this is not a total bootstrap failure."
    )
  end

  defp log({:no_new_candidates, d}) do
    Logger.warning(
      "[YggPF] NO NEW CANDIDATES this cycle, but #{d.cached_fnodes} fnode(s) are cached " <>
        "from a prior run. Possible causes: reduced network visibility, temporary " <>
        "connectivity loss, or DHT bootstrap degradation. Cached state may still be usable."
    )
  end

  defp log({:no_candidates_no_dht, d}) do
    Logger.error(
      "[YggPF] NETWORK/BOOTSTRAP FAILURE: #{div(d.elapsed_ms, 1000)}s elapsed with no " <>
        "candidates and no Mainline DHT bootstrap. Not waiting further - check UDP " <>
        "connectivity and whether outbound DHT traffic is being filtered."
    )
  end

  @doc "Log a successful pong, mirroring the legacy `GenS.PFLog.log_pong/1` format."
  def log_pong(uaddr, fid) do
    Logger.debug(
      "[YggPF] === PONG === #{PrinterSync.peer(uaddr)} fid=#{Base.encode16(fid, case: :lower)}"
    )
  end
end
