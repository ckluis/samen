defmodule Samen.Web.Reads.SwallowLint do
  @moduledoc """
  The SWALLOW ratchet (WP6) for samen_web, driftwood and pawchart: a read helper that ends in
  `rescue _ -> []` renders an outage as an empty workspace (audit P3, ARCH-14).
  `Samen.Web.Reads.Guard` is the fix; this lint stops the swallow from coming back, and from
  spreading, while the rest of the tree is converted.

  This module is the WEB-LAYER CONFIGURATION (roots, reviewed entries, baselines). The scanner itself is
  `Samen.Lint.Swallow` in samen_core — one implementation shared with the kernel's own ratchet
  (`Samen.Lint.KernelSwallow`, which runs in samen_core's suite without depending on samen_web). What
  counts as a swallow, the non-rescue `{:error, _} -> []` form and the reviewed-count pinning are
  documented there.

  ## The ratchet

  `baseline/0` is the per-file count of rescue-class swallows that still exist (EMPTY since WP6 phase 4).
  `error_arm_baseline/0` is the same for the non-rescue form (`{:error, _} -> []` in a function that calls an
  Ash / Ecto / Repo read or write); the scan found none in these roots. `check/1` and `check_error_arms/1`
  fail when a file has MORE than its baseline (a file not listed is allowed 0 — a NEW swallow fails the
  suite) or FEWER (the baseline must then be lowered: shrink-only).

  A reviewed helper is a swallow that is correct (an optional-scope probe, a fail-closed authorization
  lookup): list it by `{file, function}` WITH the number of swallowing clauses it contains and its reason —
  never a bare entry. The count is pinned: a clause ADDED to a reviewed function counts as an ordinary
  swallow and fails the ratchet; a clause removed leaves a stale pin that `reviewed_problems/0` names.

  The lint reads SOURCE only; it never compiles, runs or inspects a value.
  """

  @roots ["samen_web/lib", "driftwood/lib", "pawchart/lib"]

  # Reviewed-correct swallows, `{file, function} => {pinned clause count, reason}`. They are subtracted from the count.
  @reviewed %{
    {"samen_web/lib/samen/web/reads/guard.ex", :run} =>
      {2, "the exit/throw clauses funnel into failed/3, which Guard.report/3s — the lint cannot see through the call"},
    {"samen_web/lib/samen/web/reads/guard.ex", :write} =>
      {2, "the exit/throw clauses (and the rescue) funnel into write_failed/3 -> log_failure/4, which Logger.errors and emits the write-error event — the lint cannot see through the call"},
    {"samen_web/lib/samen/web/crm/reads.ex", :work_resource?} =>
      {1, "optional-scope probe: an unmounted Work scope IS 'absent' — the honest answer"},
    {"samen_web/lib/samen/web/crm/sequences_reads.ex", :live_resource?} =>
      {1, "optional-scope probe: an unmounted Outreach scope IS 'absent' — the honest answer"},
    {"samen_web/lib/samen/web/crm/sequences_reads.ex", :sends_configured?} =>
      {1, "fail-honest predicate: 'no sender configured' is the safe, truthful default"},
    {"samen_web/lib/samen/web/marketing/leads_live.ex", :crm_mount} =>
      {1, "optional-scope probe: no (or an unresolvable) :crm_namespace label means the Leads lens is not wired on this host, which the lens renders as inert — a host-configuration fact, not a read"},
    {"samen_web/lib/samen/web/settings/security_live.ex", :safe_csrf_token} =>
      {1, "no CSRF token available (outside a request) renders the revoke forms without one, which the server then rejects — fail-closed, nothing to report"},
    {"samen_web/lib/samen/web/settings/invitations_live.ex", :verified?} =>
      {1, "fail-CLOSED capability probe (ADR-035 §5 A2): an unresolvable principal is unverified on an armed host (the invite is refused), never an elevated default"},
    {"samen_web/lib/samen/web/replay/recorder.ex", :on_mount} =>
      {1, "best-effort observer: session capture must never crash or block the LiveView it observes (documented 'Never crashes, never blocks'); a capture failure turns capture off, it does not change what the user sees"},
    {"samen_web/lib/samen/web/replay/recorder.ex", :attach} =>
      {1, "best-effort observer: same contract as on_mount/4 — attaching the recorder can never break the LiveView"},
    {"samen_web/lib/samen/web/replay/recorder.ex", :guarded} =>
      {2, "best-effort observer: a failing recorder hook turns capture :off for that LiveView and returns the socket untouched (documented)"},
    {"samen_web/lib/samen/web/replay/recorder.ex", :off} =>
      {1, "best-effort observer: detaching hooks after a recorder failure must itself be total"},
    {"samen_web/lib/samen/web/replay/renderer.ex", :render_body} =>
      {2, "returns the honest tagged value {:error, :render_failed}, which the player renders as a failed replay — not a swallow"},
    {"samen_web/lib/samen/web/replay/renderer.ex", :view_mount} =>
      {1, "optional-scope probe: a view with no resolvable router mount has no live mount; nil is the honest answer the caller handles"},
    {"samen_web/lib/samen/web/ai/server.ex", :public_field_names} =>
      {1, "pure introspection of a resource module (no read): a module with no resource info yields no extra fields, which only narrows what the grounding preview shows"},
    {"samen_web/lib/samen/web/object_ref/catalog.ex", :catalogued_resource?} =>
      {1, "pure module introspection (no read): a module that is not a loaded Ash resource is not catalogued — the inert chip, no existence oracle"},
    {"samen_web/lib/samen/web/object_ref/default_card.ex", :public_attributes} =>
      {1, "pure resource introspection (no read): a module with no resource info shows no extra fields on the card"},
    {"samen_web/lib/samen/web/object_ref/registry.ex", :card_for} =>
      {1, "a host card override that raises falls back to the default card (which resolves through the same PiiResolution output) — presentation only, never data"},
    {"samen_web/lib/samen/web/object_ref.ex", :selectable_attrs} =>
      {1, "pure resource introspection (no read): no attributes means the default card shows only what it was handed"},
    {"samen_web/lib/samen/web/account_health.ex", :sibling_mount} =>
      {1, "optional-scope probe: an unmounted sibling Billing/Support scope IS 'not mounted' — the framework-level honest absence (documented 'billing_available? false')"},
    {"samen_web/lib/samen/web/account_health.ex", :resource?} =>
      {1, "optional-scope probe: a module that is not a compiled Ash resource is 'not mounted'"},
    {"samen_web/lib/samen/web/onboarding/wizard_live.ex", :verified?} =>
      {1, "fail-CLOSED capability probe (ADR-035 §5 A2): an unresolvable principal is unverified on an armed host, never an elevated default"},
    {"samen_web/lib/samen/web/first_run.ex", :any_rows?} =>
      {1, "fail-safe probe: a failed existence check answers 'has records' so the first-run sample-data offer is NOT shown (never offers sample data into a possibly populated org)"},
    {"samen_web/lib/samen/web/reads.ex", :safe_count} =>
      {1, "an exact-total aggregate that fails is nil = 'total unknown'; the CRM pipeline column header prints no number for it, and the three board totals that sum group counts (Work timeline, CRM pipeline, CRM calendar) become nil — an em dash — when any group count is nil, never a fabricated count or the loaded row count"},
    {"samen_web/lib/samen/web/operator/activity_reads.ex", :mask_value} =>
      {1, "fail-CLOSED masking: a vault-routed diff value that cannot be cast renders the literal mask \"••••\", never the stored value"},
    {"samen_web/lib/samen/ui/form.ex", :opt_to_string} =>
      {1, "guards rendering of a validation-message interpolation OPTION (a bound or count carried in the error tuple, not a database read): a value whose to_string raises falls back to its inspect text inside the message"},
    {"samen_web/lib/samen/ui/gantt.ex", :frac} =>
      {1, "guards rendering of one bar position: a point incomparable with the timeline range (mixed or malformed temporal types) is placed at the left edge (0.0) instead of crashing the render of every other bar — presentation of caller-supplied points, no read"},
    {"samen_web/lib/samen/ui/overlay.ex", :safe_call} =>
      {1, "guards a host-supplied hit-path function: a raising one yields nil, which same_origin_path drops, so the hit renders without a link instead of crashing the overlay"},
    {"samen_web/lib/samen/web/auth/totp_pending.ex", :fetch_or_create} =>
      {1, "documented degrade (moduledoc): when the pending-secret process is down the enrolment page gets a fresh unstored secret, which the live holds in its own assigns and confirms against — the pre-F14 behaviour; nothing is read or shown as empty"},
    {"samen_web/lib/samen/web/auth/totp_pending.ex", :drop} =>
      {1, "best-effort cleanup after a confirm/disable: a pending secret that is not dropped expires on its own 15-minute TTL and is never written anywhere; nothing is shown to the user"},
    {"samen_web/lib/samen/web/tenant_gate.ex", :resolved_env} =>
      {1, "fail-SECURE: an environment that cannot be resolved is :prod, which ARMS the tenant-auth gate — the strictest posture, never an open one"},
    {"samen_web/lib/samen/web/csv.ex", :emit_export_telemetry} =>
      {1, "best-effort telemetry (documented 'never fails an export'): observability must not break the export it observes; the export result is untouched"},
    {"samen_web/lib/samen/web/live.ex", :peer_data} =>
      {1, "get_connect_info raises outside the mount lifecycle and returns nil on a dead render: either way the caller uses the 'unknown' peer, which is a stricter global per-IP rate-limit bucket — fail-closed on the limiter, nothing shown as empty"},
    {"samen_web/lib/samen/web/onboarding/wizard_controller.ex", :verified?} =>
      {1, "fail-CLOSED capability probe (ADR-035 §5 A2): an unresolvable principal is unverified on an armed host, never an elevated default"}
  }

  # Swallows that still exist, per file, AFTER the reviewed ones are subtracted. EMPTY since WP6 phase 4: every
  # swallow in the tree is either converted (Guard.run/page/write/report) or a `@reviewed` entry with its
  # reason. The map and the shrink-only ratchet stay — a new bare `rescue _ -> []` in ANY file (a file absent
  # here is allowed 0) fails the suite, and nothing may be added back to this map to make it pass.
  @baseline %{}

  # The non-rescue form (`{:error, _} -> []/nil/0/false/:ok` in a function that calls an Ash/Ecto/Repo read or
  # write), per file. The scan found NONE in samen_web, driftwood or pawchart, so the map starts empty.
  @error_arm_baseline %{}

  alias Samen.Lint.Swallow

  def roots, do: @roots
  def baseline, do: @baseline
  def error_arm_baseline, do: @error_arm_baseline
  def reviewed, do: @reviewed

  @doc "Repo root, anchored on this file's compile-time path (cwd-independent)."
  def repo_root do
    __ENV__.file |> Path.dirname() |> Path.join("../../../../..") |> Path.expand()
  end

  @doc "Every `.ex` file under the scanned roots, as repo-relative paths."
  def files, do: Swallow.files(repo_root(), @roots)

  @doc """
  Scan one source and return the swallowing clauses as `[%{fun:, line:, kind:}]` (reviewed ones are NOT
  filtered here — `scan/1` does that, so a fixture can be linted without a path). `class` is `:rescue`
  (default) or `:error_arm`.
  """
  def scan_source(source, file \\ "nofile", class \\ :rescue), do: Swallow.scan_source(source, file, class)

  @doc "Swallow count per file for `files` (default `files/0`), reviewed helpers subtracted (up to their pinned count)."
  def scan(files \\ files()), do: Swallow.scan(repo_root(), files, @reviewed, :rescue)

  @doc "Non-rescue (`{:error, _} -> literal`) site count per file."
  def scan_error_arms(files \\ files()), do: Swallow.scan(repo_root(), files, %{}, :error_arm)

  @doc """
  Compare a `scan/1` result to `baseline/0`. `:ok`, or `{:error, [message]}` — each message names
  the file, the two counts and what to do.
  """
  def check(counts \\ scan(), baseline \\ @baseline) do
    Swallow.check(
      counts,
      baseline,
      "wrap it in Samen.Web.Reads.Guard.run/3 (docs/guides/cookbook.md), or log/report and re-raise; do NOT raise the baseline"
    )
  end

  @doc "`check/2` for the non-rescue class against `error_arm_baseline/0`."
  def check_error_arms(counts \\ scan_error_arms(), baseline \\ @error_arm_baseline) do
    Swallow.check(
      counts,
      baseline,
      "return a tagged {:error, :unavailable} through Samen.Web.Reads.Guard instead of a literal empty value; do NOT raise the baseline"
    )
  end

  @doc "Stale or inexact `reviewed/0` pins (`[]` when every pin is exact)."
  def reviewed_problems(files \\ files()), do: Swallow.reviewed_problems(repo_root(), files, @reviewed, :rescue)
end
