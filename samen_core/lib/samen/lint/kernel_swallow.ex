defmodule Samen.Lint.KernelSwallow do
  @moduledoc """
  The SWALLOW ratchet over the kernel (`samen_core/lib`) — the configuration half; the scanner is
  `Samen.Lint.Swallow` (shared with `Samen.Web.Reads.SwallowLint`, which configures it for samen_web,
  driftwood and pawchart).

  The kernel is web-dependency-free, so its ratchet lives here and runs in samen_core's own suite.

  Two ratchets, each with its OWN shrink-only baseline (exact match: more fails, fewer fails until lowered):

    * `baseline/0` — catch-all (or typed, literal-returning) `rescue` / `catch` clauses that neither log, report,
      re-raise nor hand the exception on (the original swallow);
    * `error_arm_baseline/0` — the non-rescue form: `{:error, _} -> <swallow literal>` (and `_ ->` over an I/O
      scrutinee) in a function that calls an Ash / Ecto / Repo read or write, directly or through a local def.

  Each baseline also has a HARD CEILING (`ceilings/0`): the committed total its rows must sum to, which a PR cannot
  raise without a visible, separately-tested edit (see `Samen.Lint.Swallow.check_ceiling/3`).

  A site that is genuinely total is a `reviewed/0` entry: `{file, function} => {count, hash, reason}`, pinned to the
  number AND the normalised source (hash) of the swallowing clauses in that function, with a reason that is
  literally true. Never a bare entry, never an unpinned one. A swallow added to — or a clause replaced in — a
  reviewed function fails the ratchet. `Samen.Lint.Swallow.reviewed_hash/5` computes the hash.

  Kernel failures are reported through `Samen.Observability.Failure` (value-free: name + exception module).
  """

  alias Samen.Lint.Swallow

  @roots ["samen_core/lib"]

  @reviewed %{
    {"samen_core/lib/mix/tasks/samen.verify.agent_coverage.ex", :alias_bindings} =>
      {1, "02d9c199936e0922",
       "Module.split/1 raises ArgumentError only for a non-Elixir atom (`:lists`), which binds no alias: [] is the exact answer, and the lexical alias scan is otherwise unaffected"},
    {"samen_core/lib/mix/tasks/samen.verify.prefixes.ex", :abbrev_for_resource} =>
      {1, "86db75e4fafd8744",
       "Spark raises ArgumentError only when get_opt is called on a module that is not a DSL; nil (no declared abbrev) is the documented answer there, any other failure is not rescued"},
    {"samen_core/lib/samen/replay/decoder.ex", :existing_atom} =>
      {1, "a50587893bc4a03e",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; nil (never an atom minted from a stored string) is the exact answer"},
    {"samen_core/lib/samen/replay/frame_schema.ex", :existing_atom?} =>
      {1, "32f1ebea56bcdcdc",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; `false` (not a known key) is the exact answer, and it fails closed (the frame is invalid)"},
    {"samen_core/lib/samen/replay/sanitizer.ex", :existing_atom?} =>
      {1, "bb288b2d27a84544",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; `false` (not a known key) is the exact answer, and it fails closed (the key is not kept)"},
    {"samen_core/lib/samen/replay/monitor.ex", :start_finalize} =>
      {1, "18d1f9bd2a93adea",
       "Task.Supervisor.async_nolink raises RuntimeError exactly when the supervisor is at max_children; the caller drops that session (frees its buffer row via Buffer.take/1) and counts it as :dropped in the [:samen, :replay, :session] telemetry; it never waits, never persists and never retries"},
    {"samen_core/lib/samen/webhook/payload.ex", :allowlisted_fields} =>
      {1, "fc34072590cb09ca",
       "AshJsonApi's show_fields/1 raises ArgumentError only for a module that is not a Spark DSL (no JSON:API block); an empty allowlist is then the exact, fail-CLOSED answer (nothing auto-published); any other failure is not rescued"},
    {"samen_core/lib/samen/webhook/payload.ex", :declared_abbrev} =>
      {1, "848313246b5847d0",
       "Samen.Info.abbrev/1 raises ArgumentError only for a module that is not a Spark DSL (a plain struct); nil (no abbrev, only the pii_ storage guard applies) is its documented answer; any other failure is not rescued"},
    {"samen_core/lib/samen/billing/ash_checkout_mirror.ex", :safe_feature_atom} =>
      {1, "e1de1bd8d249449e",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; nil (skip that feature key, never mint an atom from a plan's feature map) is the exact answer, documented in the moduledoc"},
    {"samen_core/lib/samen/billing/webhook_dispatch.ex", :safe_atom} =>
      {1, "43b8d623939c4410",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; an unknown event kind is the bounded :unhandled, which the reconciler ignores (never a mint, never a success claim)"},
    {"samen_core/lib/samen/delivery/throttle.ex", :safe_to_string} =>
      {1, "b970d136135b4c9c",
       "List.to_string/1 raises only for a list that is not chardata (a header name that is not a string); \"\" (no such header) is the exact answer — a pure parse of a header name, no read is involved"},
    {"samen_core/lib/samen/delivery/throttle.ex", :rfc1123} =>
      {1, "3fdfc53a35af2d63",
       ":httpd_util.convert_request_date (and String.to_charlist/1) raise only for a Retry-After value that is not a date; :error (no usable date) is the exact answer, which the caller turns into the default backoff — a pure parse of an untrusted header value, no read is involved"},
    {"samen_core/lib/samen/delivery/webhook_dispatch.ex", :safe_atom} =>
      {1, "43b8d623939c4410",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; an unknown provider or event kind is the bounded :unhandled, which Deliverability no-ops (never a mint, never a success claim)"},
    {"samen_core/lib/samen/no_plaintext_pii.ex", :safe_name} =>
      {1, "662a59cf525fc730",
       "tier.tier_name/0 raises only for a module that is not a tier; the name is a LABEL on the finding, and the crash of that very tier is already a fail-closed :violation (run_tier/2), so :unknown_tier changes no verdict"},
    {"samen_core/lib/samen/api/pii_resolution.ex", :ash_postgres_repo} =>
      {1, "b6837f16a1747c85",
       "AshPostgres.DataLayer.Info.repo/2 returns nil for a resource on another data layer (nothing to raise); it raises only for a module that is not a Spark resource, or a repo function that itself raises: nil falls through to the configured :vault_repo, and with no repo at all the value stays masked — never decrypted"},
    {"samen_core/lib/samen/api/pii_resolution.ex", :table_name} =>
      {1, "e7b81d12cc48f77e",
       "AshPostgres.DataLayer.Info.table/1 returns nil for a resource without a table and raises only for a module that is not a Spark resource; nil is the INDETERMINATE answer, which bag_context/5 turns into :mask_all — the whole custom bag is masked on every masking plane, never emitted in the clear"},
    {"samen_core/lib/samen/feature_flags/cache.ex", :lookup} =>
      {1, "a00d815c30b6517c",
       ":ets.lookup raises ArgumentError only when the named table does not exist; :no_table is the exact answer, and its caller starts the table owner and loads the flag (a failure of THAT is reported and reads OFF) — no read has failed"},
    {"samen_core/lib/samen/auth/org_actor.ex", :authorized_org_ids} =>
      {1, "8dec17dbf590e324",
       "the LEGACY shape of authorized_org_ids_result/2: a raised read answers [] (no org: never an org the credential was not shown to hold; no lib code calls this legacy shape, every live path uses the tagged _result) and is logged by name and exception module (report/2, never the message or a value); a caller that must tell an outage from 'no org' uses the tagged authorized_org_ids_result/2"},
    {"samen_core/lib/samen/auth/org_actor.ex", :resolve} =>
      {1, "21b85f2b299a7589",
       "the LEGACY shape of resolve_result/3: a raised read answers :error (no actor: never an actor the credential was not shown to hold). Its one caller, CurrentOrg.resolve_actor/3, hands nil to TenantRole.membership_role/3, which maps nil to :member, the LEAST privilege and exactly what a credential with no membership row gets: an outage can lower a real admin to :member, never raise anyone, and org membership itself is gated elsewhere (OrgScope / the mount), not by this role and is logged by name and exception module (report/2, never the message or a value); a caller that must tell an outage from a denial uses the tagged resolve_result/3"},
    {"samen_core/lib/samen/catalog.ex", :destination_table} =>
      {1, "56231105dbe1ce2d",
       "AshPostgres.DataLayer.Info.table/1 returns nil for a resource on another data layer and raises only for a module that is not a Spark resource, which Ash does not reject at compile time (the relationship `destination` option only checks that it is an atom, and the attribute verifier skips manual, no_attributes? and unvalidated relationships and destinations that are not yet loaded, so only such a relationship can carry one): nil (no physical table to record for that relationship) is the exact answer for it, and nothing is read from the database"},
    {"samen_core/lib/samen/catalog.ex", :has_postgres_table?} =>
      {1, "85f6e8d53606e3bc",
       "AshPostgres.DataLayer.Info.table/1 returns nil for a resource on another data layer and raises only for a module that is not a Spark resource: false (no physical table) is the exact answer, and nothing is read from the database"},
    {"samen_core/lib/samen/cdc/projection.ex", :table_name} =>
      {1, "1dfd9df7807e27b9",
       "AshPostgres.DataLayer.Info.table/1 returns nil for a resource on another data layer and raises only for a module that is not a Spark resource, which none of its callers can pass today (the resources come from domain discovery, `Catalog.resource_modules/1` or an explicit resource list): nil (no table) means no table-scoped non_pii! clearance applies, so classify_columns/2 keeps every freeform column refused (default-deny, never an opened projection); the other callers read nil as 'not a Postgres table' (Cdc.normalize/1 pairs it with the projection, the freeform audit lists the column with no table, and the cdc_mirror tier skips the resource, i.e. asserts nothing for it)"},
    {"samen_core/lib/samen/search.ex", :existing_attribute} =>
      {1, "894cc28a4af210b6",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; nil (a registered field that is not an attribute of the resource is never searched, and no atom is minted from registry data) is the exact, fail-closed answer"},
    {"samen_core/lib/samen/replay/resolver.ex", :repo} =>
      {1, "be3694e4bcedc7a2",
       "AshPostgres.DataLayer.Info.repo/2 returns nil for a resource on another data layer (nothing to raise); it raises only for a module that is not a Spark resource, or a repo function that itself raises: nil (no repo, so the value stays masked — never decrypted) is the fail-closed answer"},
    {"samen_core/lib/samen/replay/resolver.ex", :ref_attribute} =>
      {1, "0de297393d69e1cc",
       "the vault/plan introspection raises only for a module that is no longer a resource (or has no replay plan): :code_changed is exactly that fact, it renders `[changed]`, and nothing resolves"},
    {"samen_core/lib/samen/replay/resolver.ex", :build_struct} =>
      {1, "6e7f9bdb6c0fb164",
       "a defensive guard: Kernel.struct/2 never checks @enforce_keys (only struct!/2 does) so a stored row cannot make it raise; only a module with a hand-written __struct__ that raises can, and that module is by definition not what was recorded: a :code_changed placeholder is the fail-closed answer and no stored value reaches the render"},
    {"samen_core/lib/samen/replay/resolver.ex", :dropped} =>
      {1, "f0004dfcb7a5dd80",
       "a defensive guard: Kernel.struct/1 never checks @enforce_keys (only struct!/1 does), so it raises only for a module with a hand-written __struct__ that raises; the dropped value was never data, so nil (nothing) is the fail-closed answer"},
    {"samen_core/lib/samen/replay/row_guard.ex", :check} =>
      {1, "55ebcd6e8afb4706",
       "a frame-schema validator that raises REFUSES the payload: the guard hands the caller the same changeset refusal it gives an invalid frame, never :ok — fail closed, and the caller handles the error"},
    {"samen_core/lib/samen/ai/chokepoint.ex", :charlist_sentinel?} =>
      {1, "0b17c23d9eddf284",
       "List.to_string/1 raises only for a list that is not chardata; a vt sentinel is a UTF-8 binary and can only be spelled by valid chardata, so for such a list `false` (no sentinel) is the exact answer — the element-wise allowlist (`safe_segment?/1`) still applies to it"},
    {"samen_core/lib/samen/ai.ex", :resolved_env} =>
      {1, "6e5f8d3527e06c4e",
       "fail-SECURE: an environment that cannot be resolved reads as :prod, the posture that refuses simulated providers and unconfigured adapters — never the permissive :dev/:test"},
    {"samen_core/lib/samen/automation/actions/support.ex", :safe_atom} =>
      {1, "d2422b22143b5a61",
       "String.to_existing_atom/1 raises ArgumentError only for a name that is not an existing atom; nil (no such key or module) is the exact, total answer and never mints an atom from row or model data — the one shared helper the automation actions and the run worker use"},
    {"samen_core/lib/samen/kms.ex", :resolved_env} =>
      {1, "4f80883edc8535bc",
       "fail-SECURE: an environment that cannot be resolved reads as :prod, the posture that refuses an unimplemented skeleton adapter — never the permissive :dev/:test"},
    {"samen_core/lib/samen/fleet/crypto.ex", :verify_ed25519} =>
      {1, "3edb3c5dd1080096",
       ":crypto.verify raises for a malformed public key or signature (wrong size/type); a signature that cannot be verified is not valid, so `false` (reject) is the exact answer, never an accept"},
    {"samen_core/lib/samen/observability/failure.ex", :report} =>
      {1, "24d21c6c6a87560b",
       "the failure reporter itself: observability must never break the operation it observes, and a reporter that raised would turn every handled failure into a crash — the clause is the last line, there is nothing left to report to"},
    {"samen_core/lib/samen/observability/failure.ex", :emit} =>
      {1, "15b438c33ee4efe2", "best-effort telemetry: observability must never break the read or write it observes"}
  }

  @baseline %{
    "samen_core/lib/mix/tasks/samen.doctor.ex" => 1,
    "samen_core/lib/mix/tasks/samen.verify.tool_actor_identity.ex" => 1,
    "samen_core/lib/samen/adapter_conformance_case.ex" => 6,
    "samen_core/lib/samen/aggregate/extension.ex" => 2,
    "samen_core/lib/samen/analytics.ex" => 1,
    "samen_core/lib/samen/analytics/sources.ex" => 1,
    "samen_core/lib/samen/backup/verification.ex" => 1,
    "samen_core/lib/samen/clone.ex" => 1,
    "samen_core/lib/samen/context/info.ex" => 1,
    "samen_core/lib/samen/context/transformers/no_storage.ex" => 1,
    "samen_core/lib/samen/crm/account_link.ex" => 2,
    "samen_core/lib/samen/custom_fields/change.ex" => 1,
    "samen_core/lib/samen/data_map.ex" => 1,
    "samen_core/lib/samen/delivery/provider_conformance_case.ex" => 2,
    "samen_core/lib/samen/files.ex" => 1,
    "samen_core/lib/samen/fleet/attention.ex" => 1,
    "samen_core/lib/samen/fleet/nonce_cache.ex" => 1,
    "samen_core/lib/samen/fleet/registry.ex" => 1,
    "samen_core/lib/samen/fleet/report/schema.ex" => 1,
    "samen_core/lib/samen/gen/app.ex" => 1,
    "samen_core/lib/samen/jobs/queue_parity.ex" => 1,
    "samen_core/lib/samen/marketing/consent_change.ex" => 2,
    "samen_core/lib/samen/metrics.ex" => 1,
    "samen_core/lib/samen/metrics/contention_handlers.ex" => 1,
    "samen_core/lib/samen/migration.ex" => 1,
    "samen_core/lib/samen/migration/expand_contract.ex" => 1,
    "samen_core/lib/samen/notifications/engine.ex" => 1,
    "samen_core/lib/samen/notifications/status_change.ex" => 2,
    "samen_core/lib/samen/pii/classification.ex" => 1,
    "samen_core/lib/samen/pii/info.ex" => 2,
    "samen_core/lib/samen/pii_classify.ex" => 1,
    "samen_core/lib/samen/scopes/identity/notify.ex" => 1,
    "samen_core/lib/samen/scopes/marketing/blueprint.ex" => 2,
    "samen_core/lib/samen/scopes/marketing/send_worker.ex" => 1,
    "samen_core/lib/samen/scopes/support/sla_breach_worker.ex" => 1,
    "samen_core/lib/samen/sequences.ex" => 1,
    "samen_core/lib/samen/test_sandbox.ex" => 1,
    "samen_core/lib/samen/transformers/materialize_pii.ex" => 1,
    "samen_core/lib/samen/versioning/select_for_version.ex" => 1,
    "samen_core/lib/samen/webhook/event.ex" => 1
  }

  @error_arm_baseline %{
    "samen_core/lib/samen/custom_objects.ex" => 1,
    "samen_core/lib/samen/fleet/registry.ex" => 3,
    "samen_core/lib/samen/identity/invite.ex" => 1,
    "samen_core/lib/samen/non_pii.ex" => 1,
    "samen_core/lib/samen/operator_plane.ex" => 3,
    "samen_core/lib/samen/support/inbound/ingest.ex" => 2,
    "samen_core/lib/samen/support/inbound/threading.ex" => 2
  }

  # The HARD CEILING per class and root: the baseline above must sum to exactly this. A PR that raises a baseline row
  # has to raise this number too (and `SwallowLintTest` compares it with the merge base, so it can only go down). Lower
  # it together with the baseline when a swallow is converted; never raise it.
  @ceilings %{
    rescue: %{"samen_core/lib" => 52},
    error_arm: %{"samen_core/lib" => 13}
  }

  def roots, do: @roots
  def baseline, do: @baseline
  def error_arm_baseline, do: @error_arm_baseline
  def reviewed, do: @reviewed
  def ceilings, do: @ceilings

  @doc "Repo root, anchored on this file's compile-time path (cwd-independent)."
  def repo_root, do: __ENV__.file |> Path.dirname() |> Path.join("../../../..") |> Path.expand()

  @doc "Every `.ex` file under the kernel root, as repo-relative paths."
  def files, do: Swallow.files(repo_root(), @roots)

  @doc "Unreviewed rescue-class swallow count per file."
  def scan(files \\ files()), do: Swallow.scan(repo_root(), files, @reviewed, :rescue)

  @doc "Non-rescue (`{:error, _} -> literal`) site count per file."
  def scan_error_arms(files \\ files()), do: Swallow.scan(repo_root(), files, %{}, :error_arm)

  def scan_source(source, file \\ "nofile", class \\ :rescue), do: Swallow.scan_source(source, file, class)

  @doc "`:ok` or `{:error, [message]}` for the rescue class."
  def check(counts \\ scan(), baseline \\ @baseline),
    do:
      Swallow.check(
        counts,
        baseline,
        "report it through Samen.Observability.Failure.report/3 and return a tagged {:error, :unavailable} " <>
          "(or log/re-raise); do NOT raise the baseline"
      )

  @doc "`:ok` or `{:error, [message]}` for the non-rescue class."
  def check_error_arms(counts \\ scan_error_arms(), baseline \\ @error_arm_baseline),
    do:
      Swallow.check(
        counts,
        baseline,
        "return a tagged {:error, :unavailable} (or the error itself) instead of a literal empty value; do NOT raise the baseline"
      )

  @doc "`:ok` or `{:error, [message]}`: each baseline sums to its committed ceiling (see `ceilings/0`)."
  def check_ceilings do
    with :ok <- Swallow.check_ceiling(@baseline, @ceilings.rescue, @roots),
         :ok <- Swallow.check_ceiling(@error_arm_baseline, @ceilings.error_arm, @roots) do
      :ok
    end
  end

  @doc "Stale/inexact `reviewed/0` pins (`[]` when exact)."
  def reviewed_problems(files \\ files()), do: Swallow.reviewed_problems(repo_root(), files, @reviewed, :rescue)
end
