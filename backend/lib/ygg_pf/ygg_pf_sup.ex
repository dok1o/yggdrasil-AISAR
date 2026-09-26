defmodule Spv.YggPFSup do
  @moduledoc """
  Supervision for the Yggdrasil SDP bootstrap subsystem.

  Start order matters: the scanner owns the ETS trust tables, so it comes up before
  the scheduler starts generating traffic that will feed it. The Ygg probe is last
  because it depends on the embedded Ygg node, which may still be coming up - it
  tolerates that and retries.

  Mounted from `MagnetSorter.Application` alongside `pf_supervisors/0` and
  `ygg_supervisors/0`. Gated on the `enable_ygg` setting: `ygg_pf` cannot validate a
  candidate through the yaddr path without a running Ygg node (spec section 34), so running
  it with Yggdrasil disabled would only ever produce untrusted uaddr-only results.
  """

  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    if KeyStorageSync.use_ygg?() do
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    else
      Logger.info("[YggPF] disabled: enable_ygg is false")
      :ignore
    end
  end

  @impl true
  def init(opts) do
    children = [
      {GenS.YggPFScanner, opts},
      {GenS.YggPFScheduler, opts},
      {YggPF.YggProbe, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Child spec for the application supervisor.

  The setting is checked in `start_link/1`, after SettingsManager has started.
  """
  def child_spec_if_enabled(opts \\ []) do
    [Supervisor.child_spec({__MODULE__, opts}, restart: :permanent)]
  end
end
