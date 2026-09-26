defmodule YggPF.Cursor do
  @moduledoc """
  Epoch-local cursor state (spec sections 21, 22, 26).

  Pure functions over an explicit struct so the rules are testable without a clock:

    * `R` starts at 0 each epoch (INV-010, INV-012).
    * `R` increments when **more than 8** matching yids are seen for the current
      cursor, i.e. escalation begins at 9 (INV-011, spec section 58).
    * the cursor resets when the 1-minute epoch changes (INV-012).

  Spec section 25 keeps two cursors in flight - "last and next". `active/1` returns them.

  Spec section 26 requires the first scans of each epoch to be staggered in proportion to
  cached fnode density over cached legacy density, so that a large population does
  not converge on the same few legacy nodes at the minute boundary. That is
  `initial_delay_ms/3`.
  """

  alias YggPF.Const

  @enforce_keys [:epoch, :cursor]
  defstruct epoch: 0, cursor: 0, matches: 0, escalations: 0

  @type t :: %__MODULE__{
          epoch: non_neg_integer(),
          cursor: non_neg_integer(),
          matches: non_neg_integer(),
          escalations: non_neg_integer()
        }

  @doc "Fresh state for an epoch, cursor at 0."
  @spec new(non_neg_integer()) :: t()
  def new(epoch), do: %__MODULE__{epoch: epoch, cursor: Const.cursor_start(), matches: 0}

  @doc """
  Fold an observed count of matching yids into the state.

  Counts accumulate within a cursor; crossing the threshold escalates and resets the
  running count, because the new cursor addresses a different region.
  """
  @spec observe(t(), non_neg_integer()) :: t()
  def observe(%__MODULE__{} = st, count) when is_integer(count) and count >= 0 do
    total = st.matches + count

    case total > Const.cursor_threshold() do
      true -> %{st | cursor: st.cursor + 1, matches: 0, escalations: st.escalations + 1}
      false -> %{st | matches: total}
    end
  end

  @doc """
  Advance to `epoch`. Resets the cursor when the epoch actually changed (INV-012).
  """
  @spec advance(t(), non_neg_integer()) :: t()
  def advance(%__MODULE__{epoch: same} = st, same), do: st
  def advance(%__MODULE__{}, epoch), do: new(epoch)

  @doc """
  The cursors that should be receiving traffic: "last and next" (spec section 25).

  At `R = 0` there is no previous cursor, so only `[0]` is active and the budget is
  spent there.
  """
  @spec active(t()) :: [non_neg_integer()]
  def active(%__MODULE__{cursor: 0}), do: [0]
  def active(%__MODULE__{cursor: r}), do: [r - 1, r]

  @doc """
  Would this many matching yids escalate the cursor from a clean slate?

  Spec section 58 requires 0 -> no, 8 -> no, 9 -> yes.
  """
  @spec escalate?(non_neg_integer()) :: boolean()
  def escalate?(count) when is_integer(count), do: count > Const.cursor_threshold()

  @doc """
  Milliseconds to stagger this node's first scan of an epoch (spec section 26).

  The delay grows with the ratio of cached fnodes to cached legacy nodes: the more
  fnodes there are per legacy node, the more contention there is for the few legacy
  nodes closest to a fresh prefix, so the wider the spread has to be.

      delay = min(window, round(window * fnodes / max(legacy, 1))) * jitter

  A deterministic fixed sleep is explicitly disallowed by spec section 26, so the result is
  jittered uniformly. `window` defaults to one epoch, since staggering past the
  epoch boundary would be pointless.
  """
  @spec initial_delay_ms(non_neg_integer(), non_neg_integer(), keyword()) :: non_neg_integer()
  def initial_delay_ms(fnode_count, legacy_count, opts \\ [])
      when is_integer(fnode_count) and fnode_count >= 0 and
             is_integer(legacy_count) and legacy_count >= 0 do
    window = Keyword.get(opts, :window_ms, Const.epoch_seconds() * 1_000)
    rand = Keyword.get(opts, :rand, &:rand.uniform/0)

    ratio = fnode_count / max(legacy_count, 1)
    spread = min(window, round(window * ratio))

    case spread do
      0 -> 0
      n -> trunc(rand.() * n)
    end
  end
end
