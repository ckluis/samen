defmodule Samen.Fleet.Transport do
  @moduledoc """
  The three-transport behaviour (ADR-044 §3.2): `:embedded` (in-VM), `:pull`
  (cockpit reads the app's health probe), `:push` (app heartbeats to the cockpit).
  `Samen.Fleet.read/2` reads through this behaviour and never knows which transport
  produced a row — swapping `:embedded` for `:push` changes the plumbing, not the
  surface (§8.3: "there is no separate single product render to be honest about").

  T82 ships the `:embedded` implementation in full (J5, zero config). The `:pull`
  interval scheduler and the cockpit-side aggregate READ across all registered apps
  (rendering, ranking, roll-ups) are T84's (cockpit UI/aggregates, per this task's
  scope split) — `Samen.Fleet.Registry` (this package) provides the WRITE-side
  primitives `:pull`/`:push` both land on (`record_report/3`).
  """

  @callback rows(host :: atom(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  @doc "The transport module for `mode` (§3.2)."
  @spec for_mode(:embedded | :manual | :heartbeat) :: module()
  def for_mode(:embedded), do: Samen.Fleet.Transport.Embedded
  def for_mode(:manual), do: Samen.Fleet.Transport.Pull
  def for_mode(:heartbeat), do: Samen.Fleet.Transport.Push
end
