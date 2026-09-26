defmodule Ygg.Router do
  @moduledoc """
  Router selection (PLAN_STAGE2.md §3.3): `impl/1` maps `ctx.router` to the module that
  implements `Ygg.Router.Behaviour` (`:native` -> `Ygg.Router.Native`, `:stub` ->
  `Ygg.Router.Stub`, the stage-1 router kept as the test default of `Ygg.Node.start_link/1`).
  Plays the role of the `iwn.NewPacketConn` / `iwe.NewPacketConnWithPassword` choice in
  `reference/yggdrasil-go/src/core/core.go:98-104`. The Go sidecar router (`:ironwood`) was
  removed; it lives only in the archive (`/mnt/d/_MagnetSorter/yggdrasil-split/ygg_ex`).
  """
  alias Ygg.Node
  @compile {:inline, impl: 1}
  @spec impl(Node.t() | %{router: atom()}) :: module()
  def impl(%{router: :native}), do: Ygg.Router.Native
  def impl(%{router: :stub}), do: Ygg.Router.Stub
end