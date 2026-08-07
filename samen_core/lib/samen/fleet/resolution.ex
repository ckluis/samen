defmodule Samen.Fleet.Resolution do
  @moduledoc """
  J3 / Amendment 1 — the `:fleet_resolution` SEAM SHAPE (ADR-044 §16.2, §6.3a #2).

  ## Scope: this module ships the SEAM; T84 ships the answer

  Amendment 1 made a tenant's display **name** per-viewer-resolvable, gated by an account
  scope the OWNING PRODUCT decides:

      may_resolve?(principal, app_id, handle) :=
           roles[app_id] != nil                       # J3 args-carrier (Samen.Fleet.Authz)
       AND handle ∈ scope_of(principal, app_id)       # THIS seam

      scope_of/2  ->  :all | {:accounts, MapSet.t(org_id)} | :none

  **This module is T83's half: the reader + shape validator + fail-closed posture of the
  seam — NOT the answer.** The actual per-product scope (the `{:accounts, set}` book of
  business) comes from a dedicated ASSIGNMENT RESOURCE built in **T84** (operator ruling
  R-A, §16.5 #1); the host resolver wired behind this seam, the `scope_of/2`
  implementation, and the `Samen.Web.Operator.Impersonation.gate/2` scope-conjunct
  composition (`may_drill_in?`, §16.4a) are all **T84**. T83 leaves those untouched so the
  T150 impersonation surface stays per-product UNCHANGED (§6.4, RP-J-6).

  ## The seam — `:fleet_resolution` (fail CLOSED to `:none`)

  Mirrors `:operator_authority`/`:fleet_authority` exactly — an `{mod, fun, args}` MFA
  whose args list carries the product scope, called with the principal id APPENDED:

      config :my_app, :fleet_resolution, {MyApp.Fleet.Auth, :resolution_scope, [:my_app]}

  **Fails CLOSED**: no seam, a non-MFA config, an erroring resolver, `nil`, or ANY return
  outside the closed shape `:all | {:accounts, MapSet} | :none` collapses to `:none` — a
  host that wires nothing gets no names, never all names (§16.2). This is the ADR-028
  mask-by-omission discipline: a resolver bug fails toward masking.

  The seam is consumed from TWO places with DIFFERENT inputs (§16.2 table), both wired in
  T84: cockpit-side name resolution starts from a wire handle (needs the
  `fleet_subject_key` to relate handle→org first); the product-local drill-in gate already
  holds the `org_id` and tests membership directly (keyless). This module answers neither —
  it only reads the seam and hands back a validated scope value.
  """

  @typedoc "The closed scope shape a `:fleet_resolution` resolver may return."
  @type scope :: :all | {:accounts, MapSet.t(String.t())} | :none

  @doc """
  The account scope the authenticated `principal_id` holds for the product wired at
  `otp_app`'s `:fleet_resolution` seam. Returns the validated, closed-shape value, or
  `:none` (fail CLOSED) for a missing/erroring/malformed seam or any out-of-shape return.

  The product scope is carried in the seam's baked `args` (e.g. `[:driftwood]`), so this
  reader takes only `otp_app` (which app-env to read) and the principal id (appended).
  """
  @spec scope_of(atom(), String.t() | nil) :: scope()
  def scope_of(otp_app, principal_id) when is_atom(otp_app) do
    case Application.get_env(otp_app, :fleet_resolution) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        validate_scope(apply(mod, fun, args ++ [principal_id]))

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  def scope_of(_otp_app, _principal_id), do: :none

  @doc """
  Validate a value against the closed `scope_of/2` shape. Public so callers that obtain a
  scope by other means (T84's cockpit + drill-in paths) reuse ONE definition of "valid
  shape" rather than re-deriving it and diverging. Anything out of shape → `:none`.
  """
  @spec validate_scope(term()) :: scope()
  def validate_scope(:all), do: :all
  def validate_scope(:none), do: :none

  def validate_scope({:accounts, %MapSet{} = set}) do
    if Enum.all?(set, &is_binary/1), do: {:accounts, set}, else: :none
  end

  def validate_scope(_), do: :none
end
