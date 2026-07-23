defmodule Samen.Web.Application do
  @moduledoc """
  `samen_web`'s OTP application — supervises the framework's process-owned singletons.

  Currently just `Samen.Web.RateLimit.Backend` (the Hammer fixed-window ETS counter store
  behind `Samen.Web.RateLimit`, ADR-038 §6.1). A rate limiter needs a STABLE owner for its
  ETS table: counters keyed per-account/per-IP must survive across requests, so the table
  cannot be owned by a transient request process. Supervising the backend here gives it a
  long-lived owner whenever the `:samen_web` app is running (every host that depends on it,
  plus this library's own test suite). The seam also lazily auto-starts the backend on
  first use (the `Samen.FeatureFlags.Cache` house pattern), so it degrades gracefully in
  contexts where this supervisor is not running.

  No web/vendor deps flow into `samen_core` (INV-4): the rate-limiter deps and this
  supervisor live entirely in `samen_web`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Samen.Web.RateLimit.Backend, clean_period: :timer.minutes(1)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Samen.Web.Supervisor)
  end
end
