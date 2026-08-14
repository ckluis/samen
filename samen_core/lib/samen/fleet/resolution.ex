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

  # ===========================================================================
  # T84 — the REAL reader over the assignment resource (ruling R-A, §16.5 #1)
  # ===========================================================================

  # The broad operator roles that resolve `:all` with no assignment row — today's
  # `/operator/accounts` behaviour, unchanged (§16.2/§16.5 #1). `:operator_readonly`
  # is deliberately ABSENT: a readonly operator is an ASSIGNABLE role, scoped by row.
  @broad_roles [:operator_admin, :operator_support, :operator_break_glass]

  @doc """
  The **real** account scope for `principal_id`, read from the per-product ASSIGNMENT
  resource (ruling R-A). This is the reader a host wires behind its `:fleet_resolution`
  seam (`scope_of/2` calls it); it is the ONLY reader of the assignment resource.

  Composition (the OWNING PRODUCT decides — the product supplies `role` from its own
  `:operator_authority` resolver + the `assignment_resource` from its own domain):

    * a **broad role** (`:operator_admin`/`:operator_support`/`:operator_break_glass`)
      ⇒ `:all` — no row needed, parity with `/operator/accounts`;
    * else the operator's assignment rows for `(principal_id, app_scope)` ⇒
      `{:accounts, MapSet.of(account_org_id)}`;
    * **no row / a nil principal ⇒ `:none`** — fail-closed by ABSENCE, so a
      newly-added assignable operator has no scope until someone assigns them.

  Fail-CLOSED to `:none` on ANY error (an unreachable repo, a bad resource) — the
  mask-by-omission discipline: a reader bug fails toward LESS access. The result is
  run through `validate_scope/1`, so this can never widen the closed shape.
  """
  @spec scope_from_assignments(module(), atom() | nil, atom() | String.t(), String.t() | nil) ::
          scope()
  def scope_from_assignments(assignment_resource, role, app_scope, principal_id)
      when is_atom(assignment_resource) do
    cond do
      role in @broad_roles ->
        :all

      not is_binary(principal_id) ->
        :none

      true ->
        app_scope_str = to_string(app_scope)

        require Ash.Query

        assignment_resource
        |> Ash.Query.filter(operator_id == ^principal_id and app_scope == ^app_scope_str)
        # authz-scope: authorization-boundary read — derives the operator's account scope from
        # assignment rows keyed on the unique operator id; deny-on-empty (:none), fail closed
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.account_org_id)
        |> Enum.filter(&is_binary/1)
        |> case do
          [] -> :none
          accounts -> validate_scope({:accounts, MapSet.new(accounts)})
        end
    end
  rescue
    _ -> :none
  end

  def scope_from_assignments(_resource, _role, _app_scope, _principal_id), do: :none

  @doc """
  Is a `:fleet_resolution` seam CONFIGURED for `otp_app`?

  The gate uses this to distinguish two `:none`-shaped situations that must behave
  OPPOSITELY at the drill-in door (§16.4a, the no-lockout property):

    * seam **configured**, operator has no assignment row ⇒ `scope_of/2` is `:none`
      ⇒ the drill-in is DENIED (fail-closed for a scoped product);
    * seam **not configured at all** (no fleet, or a product that never adopted
      scoping) ⇒ the scope conjunct is INERT ⇒ the drill-in behaves exactly as it did
      before Amendment 1 (T146 + T150 only). This is what refutes the
      "separately-deployed fleet locks everyone out" composition error — a product
      with no `:fleet_resolution` seam is never locked out of its OWN drill-ins.

  Only the *presence + MFA shape* of the config is checked here; the seam's ANSWER
  (`scope_of/2`) is where `:none`-on-missing-row lives.
  """
  @spec configured?(atom()) :: boolean()
  def configured?(otp_app) when is_atom(otp_app) do
    case Application.get_env(otp_app, :fleet_resolution) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) -> true
      _ -> false
    end
  end

  def configured?(_), do: false

  @doc """
  Is a `:fleet_name_resolver` NAME-resolution seam reachable for `otp_app`?

  Distinct from `configured?/1` (which checks the `:fleet_resolution` SCOPE seam):
  this checks the handle→display-name seam that `resolve/3` consumes. The tier-2
  cockpit (`Samen.Web.Operator.FleetDetailLive`) uses it to attribute a masked
  cohort name to the RIGHT cause (§16.2):

    * seam **reachable**, but a handle is outside the viewer's `scope_of/2` ⇒ the
      row is masked "not in your scope" — a genuine per-viewer authz outcome;
    * seam **NOT wired at all** (a separately-deployed / cross-origin cockpit whose
      deployment never received the product's name-resolution seam) ⇒ `resolve/3`
      returns `%{}` for EVERY handle, so every name masks — but the honest cause is
      "resolution seam not reachable", a whole-page condition, NOT per-row out-of-scope.

  Fail-closed regardless: an unreachable/absent seam withholds names either way (no
  leak). This predicate only picks the truthful copy.
  """
  @spec name_resolver_configured?(atom()) :: boolean()
  def name_resolver_configured?(otp_app) when is_atom(otp_app) do
    case Application.get_env(otp_app, :fleet_name_resolver) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) -> true
      _ -> false
    end
  end

  def name_resolver_configured?(_), do: false

  @doc """
  Plain `org_id` membership against a resolved `scope/0` value — the KEYLESS drill-in
  gate test (§16.4a): the URL already carries the `org_id` and `scope_of/2` already
  returns `org_id`s, so no handle and no `fleet_subject_key` HMAC are involved.

    * `:all` ⇒ always in scope;
    * `{:accounts, set}` ⇒ `org_id ∈ set`;
    * `:none` ⇒ never in scope.
  """
  @spec in_scope?(scope(), String.t() | nil) :: boolean()
  def in_scope?(:all, _org_id), do: true
  def in_scope?({:accounts, %MapSet{} = set}, org_id) when is_binary(org_id), do: MapSet.member?(set, org_id)
  def in_scope?(_scope, _org_id), do: false

  # ===========================================================================
  # T84b — COCKPIT-SIDE name resolution (§16.2's `resolve/3`, the co-resident path)
  # ===========================================================================

  @doc """
  Resolve a set of wire `handles` to tenant DISPLAY NAMES, for `principal_id` on
  product `otp_app` — the co-resident path §16.2 names: *"the cockpit calls
  `Samen.Fleet.Resolution.resolve/3` in-VM through the product's seam."*

  ## Why this does NOT touch `fleet_subject_key`/`Samen.Fleet.Handle` itself

  This module never holds a product's `fleet_subject_key` (§16.2's custody rule
  — "never sent to the cockpit"). Relating a handle to a real org REQUIRES that
  key, so the relating work is delegated to a HOST-owned seam
  (`:fleet_name_resolver`, mirroring `:operator_authority`/`:fleet_authority`/
  `:fleet_resolution` exactly) — product-side code that DOES hold the key (and
  its own org table), running IN the product's own process. The cockpit LiveView
  (running co-resident, same BEAM) calls this reader; this reader calls the
  seam; the seam does the actual HMAC relating + scope filtering. The cockpit
  itself never computes an HMAC and never sees an unfiltered org list.

  ## Fail-CLOSED + mask-by-omission (§16.2)

  No seam, an erroring seam, or a non-map return ⇒ `%{}` — every handle stays
  masked. The result is FILTERED to only the keys that were actually asked for
  (`handles`) and only string values are admitted — a permissive/leaky seam
  cannot smuggle extra handles or non-name values past this reader (the same
  discipline `validate_scope/1` applies to `scope_of/2`'s own seam).

  Seam shape: `config :my_app, :fleet_name_resolver, {MyApp.Fleet.Auth,
  :resolve_names, [:my_app]}`, called as `apply(mod, fun, args ++
  [principal_id, handles])`, returning `%{handle => name}` containing ONLY
  handles the principal is entitled to resolve (§16.2's "mask by omission" —
  a denied handle is ABSENT from the map, never present-with-a-mask).
  """
  @spec resolve(atom(), String.t() | nil, [String.t()]) :: %{String.t() => String.t()}
  def resolve(otp_app, principal_id, handles) when is_atom(otp_app) and is_list(handles) do
    case Application.get_env(otp_app, :fleet_name_resolver) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        apply(mod, fun, args ++ [principal_id, handles])
        |> filter_resolved(handles)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  def resolve(_otp_app, _principal_id, _handles), do: %{}

  # Phase-6 EDGE-LOW L1 — seam-trust boundary, documented on the record.
  #
  # This filter enforces SHAPE only (requested handles + string values) — it
  # deliberately does NOT re-check `scope_of/2` here. Scope-filtering is the
  # SEAM's job: the reference `resolve_via_org_scan/5` below composes
  # `Handle.matches?/4` with `scope_of/2` and returns ONLY in-scope names, so a
  # host wiring that reference (the shipped, tested path — see
  # `fleet_detail_scope_mask_test.exs`'s GREEN/RED/SABOTAGE 3-proof and
  # `fleet_resolution_resolve_test.exs`'s `resolve_via_org_scan/5` scope tests)
  # gets end-to-end scope safety. A host that wires a NAIVE `:fleet_name_resolver`
  # ignoring `scope_of/2` entirely would NOT be caught here — this framework
  # layer cannot re-derive scope from a bare `%{handle => name}` map (it has no
  # `org_id` to check `scope_of/2` against without ANOTHER seam call, which
  # would couple two independently-documented seams for a hardening that adds
  # real coupling risk for a case no shipped host exercises — the risk this
  # comment exists to keep on the record for the NEXT vertical's resolver
  # author to audit, per the Phase-6 EDGE-LOW dogfood finding). If a future
  # host's resolver needs re-verification here, prefer wiring
  # `resolve_via_org_scan/5` (or an equivalent that checks `scope_of/2` itself)
  # over widening this function's contract.
  defp filter_resolved(%{} = resolved, handles) do
    allowed = MapSet.new(handles)

    for {handle, name} <- resolved,
        is_binary(handle),
        handle in allowed,
        is_binary(name),
        into: %{},
        do: {handle, name}
  end

  defp filter_resolved(_non_map, _handles), do: %{}

  @doc """
  Reference `:fleet_name_resolver` implementation a host CAN wire: relate each
  handle to an org by SCANNING `org_rows` (a list of `%{id:, name:}` maps — the
  product's own org table, e.g. `Ash.read!(OrgResource)`) via
  `Samen.Fleet.Handle.matches?/4` (the product-local membership test, §5.3),
  then filters to `handle ∈ scope_of(principal, app_scope)` — the SAME
  `:fleet_resolution` answer that gates tier-2 name visibility (§16.2). O(n)
  in the org count; a host with a large org table may want a cached reverse
  index instead — this is the STRAIGHTFORWARD correct implementation, not a
  performance-tuned one.

  A host wires this as, e.g.:

      config :my_app, :fleet_name_resolver,
        {Samen.Fleet.Resolution, :resolve_via_org_scan, [:my_app, &MyApp.Fleet.orgs/0, MyApp.app_id()]}

  where the seam's own `args` supply `app_scope`, an org-row-listing zero-arity
  fn, and this product's own registered `app_id` (the key `fleet_handle`s were
  computed under).
  """
  @spec resolve_via_org_scan(atom(), (-> [map()]), String.t(), String.t() | nil, [String.t()]) ::
          %{String.t() => String.t()}
  def resolve_via_org_scan(app_scope, org_rows_fn, app_id, principal_id, handles)
      when is_function(org_rows_fn, 0) and is_binary(app_id) do
    scope = scope_of(app_scope, principal_id)
    handle_set = MapSet.new(handles)

    org_rows_fn.()
    |> Enum.reduce(%{}, fn org, acc ->
      cond do
        MapSet.size(handle_set) == map_size(acc) ->
          acc

        not in_scope?(scope, org.id) ->
          acc

        true ->
          case Enum.find(handles, &Samen.Fleet.Handle.matches?(app_id, org.id, &1)) do
            nil -> acc
            handle -> Map.put(acc, handle, org.name)
          end
      end
    end)
  rescue
    _ -> %{}
  end

  # ===========================================================================
  # T84b — the §5.3 tier-2 deep-link RESOLVE step (handle → org_id, NOT a name)
  # ===========================================================================

  @doc """
  Resolve ONE wire `handle` to its `org_id` — the §5.3 deep-link step: *"`/resolve`
  maps handle → org_id server-side and redirects to the canonical
  `/operator/deliverability/:org_id`. Resolution alone grants nothing: it is a
  lookup, and it happens behind the T146 gate."* Deliberately does NOT consult
  `scope_of/2` (unlike `resolve/3`'s name resolution) — §5.3 is explicit that a
  handle→org_id lookup grants no access; the CANONICAL drill-in's own
  `may_drill_in?` (T146 + scope + T150, `Samen.Web.Operator.Impersonation.
  gate/3`) is where access is actually decided, unchanged by resolution having
  happened. Fail-CLOSED: no seam, an erroring seam, or a non-binary return ⇒
  `:error` (never a fabricated org_id).

  Seam shape: `config :my_app, :fleet_handle_resolver, {MyApp.Fleet.Auth,
  :resolve_org_id, [:my_app]}`, called as `apply(mod, fun, args ++ [handle])`.
  """
  @spec resolve_org_id(atom(), String.t()) :: {:ok, String.t()} | :error
  def resolve_org_id(otp_app, handle) when is_atom(otp_app) and is_binary(handle) do
    case Application.get_env(otp_app, :fleet_handle_resolver) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        case apply(mod, fun, args ++ [handle]) do
          {:ok, org_id} when is_binary(org_id) -> {:ok, org_id}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  def resolve_org_id(_otp_app, _handle), do: :error

  @doc """
  Reference `:fleet_handle_resolver` implementation: scan `org_ids` (this
  product's own org id list — cheap, no PII, just ids) for the one whose
  `Samen.Fleet.Handle.matches?/4` under this product's OWN `app_id`. O(n); see
  `resolve_via_org_scan/5`'s moduledoc note on scale.
  """
  @spec resolve_org_id_via_scan((-> [String.t()]), String.t(), String.t()) :: {:ok, String.t()} | :error
  def resolve_org_id_via_scan(org_ids_fn, app_id, handle) when is_function(org_ids_fn, 0) and is_binary(app_id) do
    case Enum.find(org_ids_fn.(), &Samen.Fleet.Handle.matches?(app_id, &1, handle)) do
      nil -> :error
      org_id -> {:ok, org_id}
    end
  rescue
    _ -> :error
  end
end
