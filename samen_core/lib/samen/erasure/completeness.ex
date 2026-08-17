defmodule Samen.Erasure.Completeness do
  @moduledoc """
  Erasure-completeness DISCOVERY + ASSERTION — the ADR-046 §6 capstone gate.

  ## The failure this exists to make impossible

  `Samen.Erasure.shred/2` is a KEY-destruction job: one `Samen.Kms.shred/1` makes every
  *vaulted* value for a subject undecryptable at once. But a plaintext-or-linkable value
  that lives **outside the per-subject-DEK envelope** is not reached by key destruction —
  and if no erasure arm touches it, a shredded subject's data survives, silently. The
  panel found the moduledoc's two-item carve-out list was actually FIVE. The `email_bidx`
  blind index slipped past every gate because `schema.dict.json` **grandfathers**
  pre-existing columns — the exact mechanism this gate refuses to use.

  ## What this module does instead (the QueueParity move)

  It **discovers** every out-of-envelope residue from the LIVE schema + registries
  (never `schema.dict`), and **asserts** a registered `subject_id`-keyed erasure arm
  reaches each. Residue classes:

    * **(a) derived-linkable columns** — blind-index / keyed-HMAC columns (`email_bidx`
      and any `_bidx` sibling), discovered via `Samen.DerivedLinkable` (the explicit
      marker registry) AND the structural `_bidx` backstop. Each must be REGISTERED in
      the marker AND covered by a `:blind_index_erasure_specs` entry. An unregistered
      `_bidx` column FAILS (a future blind index cannot ship un-erasable).
    * **(b) `pii_declared`-capable custom bags** — every `public?: true` `:map` `:custom`
      bag column. Masking is automatic-by-construction (the resolver reads every org's
      `tnt_field`), and erasure is guaranteed at the `Samen.CustomFields.define_field/2`
      chokepoint (a `pii_declared: true` field is REFUSED unless a `:custom_bag_erasure_specs`
      spec covers its table). The gate asserts BOTH governing mechanisms are live. The SAME
      define-time discipline covers the **custom-OBJECT record bag** (`tnt$obj$…`, ADR-046 §8
      residual #2): a `pii_declared: true` field on a tenant-defined object table is EQUALLY
      refused unless a `:record_bag_erasure_specs` arm covers the object, so a custom object
      cannot carry PII in its `tnt_record` bag with no erasure arm.
    * **(c) `storage_key` columns** — raw stored file blobs (outside the DEK envelope).
      A subject-linked blob (the resource carries a data-subject field — `uploaded_by_id`
      for a blob *uploaded BY* a subject, or a domain subject-FK like `person_id` for a
      blob *ABOUT* a subject, ADR-046 §7 #5) must be covered by a `:file_erasure_specs`
      entry. An org-asset blob (no data-subject field, e.g. CMS `Media`) is not a
      per-subject-erasure residue; it is REPORTED as an org-lifecycle residual (named, not
      silently dropped). Additionally, EVERY `storage_key` blob (subject-linked and org-asset)
      must have its RETENTION `:delete` generic-purge routed through the governed ref-counted
      `Samen.Files.delete_file/3` chokepoint (`Samen.Retention.blob_backed?/1`), never a raw
      `Ash.destroy!` that orphans the blob bytes (ADR-046 §8 residual #3).
    * **(d) regression floor** — the already-covered classes: `non_pii!` columns
      (redacted row-level inside `shred/2`) and DEK-keyed pseudonyms (unlinked for free
      by key-shred). Asserted still-wired so a refactor cannot drop them.
    * **(e) vault-routed transcripts** (ADR-047 §7.4, batch A2) — every resource whose
      `pii do` block declares a `:transcript` attribute. The transcript IS inside the
      DEK envelope (it is not an out-of-envelope residue, and classes (a)–(c) gain no
      member from it) — but its DEK is keyed on the ROW's own id, not on any person the
      run discussed, so **subject-level reach is by retention only**: the gate asserts a
      registered `:retention_specs` `:shred` arm (subject_field `:id`) covers each such
      resource, exactly as `Samen.Erasure.default_specs/1` derives it (90 days, operator
      decision ADR-047 §9#4 TAKEN). Without that arm a transcript would live until
      account erasure — the indefinite-liability window §7.4 exists to close. The
      broader "self-keyed vaulted free text" class (e.g. `Automation.Reminder.note`)
      remains the carried ADR-046 §7#5 residual, ruled on together with it — this arm
      deliberately covers the transcript class ADR-047 ships, not that open decision.

  ## Non-vacuity (the A2/X9/QueueParity lesson — MANDATORY)

  A discovery gate passes trivially when discovery finds nothing. This one FAILS CLOSED
  on an empty residue set: `email_bidx` + `storage_key` columns exist in every host that
  mounts identity + primitives, so an empty derived-linkable OR storage_key discovery is
  a broken verifier, never a green one. And every coverage assertion is REFUTABLE:
  `check/1` accepts injected spec lists, so a unit test hands it a set with one arm
  removed and the check must name the now-uncovered residue (proving it is not a tautology).

  ## Scope

  `resources/1` enumerates every Ash resource in the app's configured `:ash_domains`
  (like `Mix.Tasks.Samen.Verify.SameOrgFk`). Running under a host it covers that host's
  materialized identity + primitives + scope resources; the specs are activated at
  `application.ex` start by `Samen.Erasure.install_default_specs/1`, so each host checks
  its own live population against its own registered arms.
  """

  alias Samen.DerivedLinkable

  # Physical attributes that mark a File-like resource's DATA SUBJECT. This covers both a
  # blob *uploaded BY* a subject (`uploaded_by_id`) AND a blob *ABOUT* a subject named by a
  # domain subject-FK (`person_id` → a CRM Person, whose scanned ID / signed contract the
  # blob may be — ADR-046 §7 decision #5). A `storage_key` resource carrying ANY of these is
  # subject-linked (per-subject erasable → MUST have a `:file_erasure_specs` arm); one
  # carrying NONE is a genuinely org-owned asset (CMS `Media`) — an org-lifecycle residual,
  # not a per-subject-shred residue.
  @subject_fields [:uploaded_by_id, :person_id]

  # ---------------------------------------------------------------------------
  # Resource enumeration
  # ---------------------------------------------------------------------------

  @doc """
  Every Ash resource in the app's configured domains.

  Options:
    * `:resources` — an explicit resource list, bypassing domain resolution (tests).
    * `:domains`   — explicit domains (default: the otp_app's `:ash_domains`).
  """
  @spec resources(keyword()) :: [module()]
  def resources(opts \\ []) do
    case Keyword.fetch(opts, :resources) do
      {:ok, list} when is_list(list) ->
        list

      :error ->
        opts
        |> domains()
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Enum.uniq()
    end
  end

  defp domains(opts) do
    case Keyword.get(opts, :domains) do
      list when is_list(list) and list != [] ->
        list

      _ ->
        otp_app = Keyword.get(opts, :otp_app) || app()
        Application.get_env(otp_app, :ash_domains, [])
    end
  end

  defp app do
    case function_exported?(Mix.Project, :config, 0) and Mix.Project.config()[:app] do
      nil -> :samen_core
      false -> :samen_core
      app -> app
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery (from the LIVE schema — never schema.dict)
  # ---------------------------------------------------------------------------

  @doc """
  Discover every out-of-envelope residue across `resources/1` — plus class (e), the
  in-envelope-but-retention-reached vault-routed transcripts (ADR-047 §7.4).

  Returns `%{derived_linkable: [...], storage_key: [...], custom_bag: [...],
  transcript: [...]}`.
  """
  @spec discover(keyword()) :: %{
          derived_linkable: [map()],
          storage_key: [map()],
          custom_bag: [map()],
          transcript: [map()]
        }
  def discover(opts \\ []) do
    resources = resources(opts)

    %{
      derived_linkable: DerivedLinkable.discover(resources),
      storage_key: discover_storage_key(resources),
      custom_bag: discover_custom_bag(resources),
      transcript: discover_transcript(resources)
    }
  end

  defp discover_storage_key(resources) do
    for resource <- resources, attr = attribute(resource, :storage_key), attr != nil do
      %{
        resource: resource,
        table: table(resource),
        column: to_string(attr.source || attr.name),
        subject_field: subject_field(resource)
      }
    end
  end

  # The bag attribute is `attribute(:custom, :map, public?: true)` — the Tier-1 bag.
  defp discover_custom_bag(resources) do
    bag = Samen.CustomFields.bag_attr()

    for resource <- resources, attr = attribute(resource, bag), attr != nil, map_attr?(attr) do
      %{
        resource: resource,
        table: table(resource),
        column: to_string(attr.source || attr.name)
      }
    end
  end

  defp map_attr?(attr), do: attr.type in [:map, Ash.Type.Map] and attr.public? == true

  # (e) vault-routed transcripts (ADR-047 §7.4): a resource whose `pii do` block
  # declares a `:transcript` pii_attribute. Discovered from the LIVE pii declarations
  # (`Samen.Pii.Info.fields/1`), never schema.dict — the same no-grandfathering rule as
  # every other class. The physical column resolves through the materialized attribute
  # (`pii_<abbrev>_transcript`).
  defp discover_transcript(resources) do
    for resource <- resources,
        field <- pii_fields(resource),
        field.name == :transcript do
      attr = attribute(resource, :transcript)

      %{
        resource: resource,
        table: table(resource),
        column: to_string((attr && (attr.source || attr.name)) || :transcript),
        vault: field.vault
      }
    end
  end

  defp pii_fields(resource) do
    Samen.Pii.Info.fields(resource)
  rescue
    _ -> []
  end

  defp subject_field(resource) do
    Enum.find(@subject_fields, fn f -> attribute(resource, f) != nil end)
  end

  # ---------------------------------------------------------------------------
  # Assertion
  # ---------------------------------------------------------------------------

  @doc """
  Assert every discovered residue is reached by a registered erasure arm.

  Returns `{:ok, report}` on success or `{:error, {:no_residues_discovered, ...} |
  {:incomplete, violations, report}}`.

  Options (all optional; the defaults read the registered config so the gate checks the
  RUNTIME arms):

    * `:resources` / `:domains` / `:otp_app` — passed to `resources/1`.
    * `:bidx_specs`      — override `:blind_index_erasure_specs` (refutability).
    * `:file_specs`      — override `:file_erasure_specs` (refutability).
    * `:retention_specs` — override `:retention_specs` (transcript-arm refutability).
    * `:skip_bag_guard?` — skip the live `pii_declared` guard probe (tests without a repo).
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(opts \\ []) do
    residues = discover(opts)

    bidx_specs = opts[:bidx_specs] || Application.get_env(:samen_core, :blind_index_erasure_specs, [])
    file_specs = opts[:file_specs] || Application.get_env(:samen_core, :file_erasure_specs, [])

    retention_specs =
      opts[:retention_specs] || Application.get_env(:samen_core, :retention_specs, [])

    cond do
      # NON-VACUITY floor: the two hard residue classes exist in every real host
      # (email_bidx via identity, storage_key via primitives). An empty set is a
      # broken discovery, never a pass (A2/X9/QueueParity).
      residues.derived_linkable == [] ->
        {:error, {:no_residues_discovered, :derived_linkable}}

      residues.storage_key == [] ->
        {:error, {:no_residues_discovered, :storage_key}}

      true ->
        {dl_violations, dl_report} = check_derived_linkable(residues.derived_linkable, bidx_specs)
        {sk_violations, sk_report} = check_storage_key(residues.storage_key, file_specs, opts)
        {bag_violations, bag_report} = check_custom_bag(residues.custom_bag, opts)
        {tr_violations, tr_report} = check_transcript(residues.transcript, retention_specs)
        floor = regression_floor()

        violations =
          dl_violations ++ sk_violations ++ bag_violations ++ tr_violations ++ floor.violations

        report = %{
          derived_linkable: dl_report,
          storage_key: sk_report,
          custom_bag: bag_report,
          transcript: tr_report,
          regression_floor: floor.report,
          org_asset_residuals: sk_report.org_assets
        }

        case violations do
          [] -> {:ok, report}
          _ -> {:error, {:incomplete, violations, report}}
        end
    end
  end

  # (a) derived-linkable — must be marker-registered AND spec-covered.
  defp check_derived_linkable(residues, specs) do
    violations =
      Enum.flat_map(residues, fn r ->
        cond do
          not r.registered? ->
            [
              "UNREGISTERED derived-linkable column #{r.table}.#{r.column} " <>
                "(#{inspect(r.resource)}): a `_bidx`-shaped blind index that is NOT in " <>
                "`Samen.DerivedLinkable` — an equality oracle over its input space that " <>
                "crypto-shred cannot reach. Register it (logical name → owning-principal " <>
                "subject column) AND add a :blind_index_erasure_specs arm."
            ]

          not bidx_covered?(r, specs) ->
            [
              "UNREACHED derived-linkable column #{r.table}.#{r.column} " <>
                "(#{inspect(r.resource)}): registered as derived-linkable but NO " <>
                "`:blind_index_erasure_specs` entry covers it — a shredded subject's value " <>
                "stays confirmable via the equality oracle. Register a tombstone arm " <>
                "(subject_column: #{inspect(r.subject_column)})."
            ]

          true ->
            []
        end
      end)

    {violations, %{count: length(residues), columns: Enum.map(residues, &"#{&1.table}.#{&1.column}")}}
  end

  defp bidx_covered?(r, specs) do
    Enum.any?(specs, fn spec ->
      to_string(Map.get(spec, :table_name)) == r.table and
        to_string(Map.get(spec, :bidx_column, "email_bidx")) == r.column
    end)
  end

  # (c) storage_key — subject-linked blobs need a file spec; org-asset blobs are residual.
  # PLUS: the RETENTION `:delete` generic-purge arm must route EVERY storage_key blob (subject
  # -linked AND org-asset) through the governed, ref-counted `Samen.Files.delete_file/3`
  # chokepoint — never a raw `Ash.destroy!` that drops the row and ORPHANS the blob bytes
  # (ADR-046 §8 residual #3). `Samen.Retention.blob_backed?/1` is the LIVE routing predicate the
  # `:delete` sweep itself branches on, so asserting it here ties the gate to the real behavior:
  # neuter the predicate and both the sweep (raw destroy, blob survives) AND this arm flip.
  # Injectable (`:retention_blob_backed_fun`) so a unit test models the gap and proves detection.
  defp check_storage_key(residues, specs, opts) do
    {subject_linked, org_assets} = Enum.split_with(residues, & &1.subject_field)
    blob_backed_fun = opts[:retention_blob_backed_fun] || (&Samen.Retention.blob_backed?/1)

    file_violations =
      Enum.flat_map(subject_linked, fn r ->
        if file_covered?(r, specs) do
          []
        else
          [
            "UNREACHED storage_key blob on #{inspect(r.resource)} (#{r.table}.#{r.column}, " <>
              "subject field #{inspect(r.subject_field)}): NO `:file_erasure_specs` entry " <>
              "names this file_module — a shredded subject's raw file bytes are never " <>
              "deleted. Register a file-erasure arm (subject_field: #{inspect(r.subject_field)})."
          ]
        end
      end)

    retention_violations =
      Enum.flat_map(residues, fn r ->
        if blob_backed_fun.(r.resource) do
          []
        else
          [
            "UN-PURGED storage_key blob on #{inspect(r.resource)} (#{r.table}.#{r.column}): " <>
              "`Samen.Retention`'s `:delete` generic-purge does NOT route this blob through the " <>
              "governed ref-counted `Samen.Files.delete_file/3` chokepoint — an expired-retention " <>
              "`:delete` would drop the row via a raw destroy and ORPHAN the blob bytes (never " <>
              "deleted, never ref-count-checked). Route it through the chokepoint (ADR-046 §8 #3)."
          ]
        end
      end)

    retention_blob_aware? = retention_violations == []

    report = %{
      count: length(residues),
      subject_linked: Enum.map(subject_linked, &"#{&1.table}.#{&1.column}"),
      org_assets: Enum.map(org_assets, &"#{inspect(&1.resource)} (#{&1.table}.#{&1.column})"),
      retention_blob_aware: retention_blob_aware?
    }

    {file_violations ++ retention_violations, report}
  end

  defp file_covered?(r, specs) do
    Enum.any?(specs, fn spec -> Map.get(spec, :file_module) == r.resource end)
  end

  # (b) custom bag — masking automatic + erasure guaranteed at the define chokepoint.
  #
  # Two rungs of the SAME discipline are asserted here:
  #   * FIRST-CLASS bag (`:custom` column on a catalog resource) — masking resolver live +
  #     `define_field/2` refuses a `pii_declared: true` field on an un-covered table.
  #   * CUSTOM-OBJECT record bag (`tnt$obj$…`, ADR-046 §8 residual #2) — the analogue rung:
  #     `define_field/2` must EQUALLY refuse a `pii_declared: true` field on a `tnt$obj$…`
  #     object table unless a `:record_bag_erasure_specs` arm covers the object. Without this
  #     a custom object could carry PII in its `tnt_record` bag with no erasure arm — the exact
  #     escape the E6 first-class rung closes. Refutable: restore the blanket `tnt$obj$` exempt
  #     (or inject `:object_guard_fun`) and the object-bag rung is named un-enforced.
  defp check_custom_bag(residues, opts) do
    masking_ok? = masking_arm_present?()
    guard_fun = opts[:object_guard_fun] || (&define_object_guard_enforced?/0)

    {guard_ok?, object_guard_ok?} =
      if opts[:skip_bag_guard?] do
        {true, true}
      else
        {define_guard_enforced?(), guard_fun.()}
      end

    violations =
      []
      |> add_if(
        residues != [] and not masking_ok?,
        "custom-bag MASKING arm missing: the universal `pii_declared` masking resolver " <>
          "(Samen.Api.PiiResolution) is not present — a pii_declared bag key could ship " <>
          "UNMASKED to an operator without a grant."
      )
      |> add_if(
        residues != [] and masking_ok? and not guard_ok?,
        "custom-bag ERASURE guard not enforced: `Samen.CustomFields.define_field/2` no " <>
          "longer REFUSES a `pii_declared: true` field on an un-covered table — a " <>
          "pii_declared bag could ship UN-ERASABLE (no `:custom_bag_erasure_specs` arm)."
      )
      |> add_if(
        not object_guard_ok?,
        "custom-OBJECT record-bag ERASURE guard not enforced: `Samen.CustomFields.define_field/2` " <>
          "no longer REFUSES a `pii_declared: true` field on a `tnt$obj$…` object table — a " <>
          "custom object's `tnt_record` bag could ship UN-ERASABLE (no `:record_bag_erasure_specs` " <>
          "arm), escaping the discipline first-class resources cannot (ADR-046 §8 residual #2)."
      )

    {violations,
     %{
       count: length(residues),
       columns: Enum.map(residues, &"#{&1.table}.#{&1.column}"),
       masking_arm: masking_ok?,
       erasure_guard: guard_ok?,
       object_bag_guard: object_guard_ok?
     }}
  end

  # The universal masking resolver that omits/masks pii_declared bag keys on a masked plane.
  defp masking_arm_present? do
    loaded_exported?(Samen.Api.PiiResolution, :resolve, 4)
  end

  defp loaded_exported?(mod, fun, arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  # Prove the define-time erasability guard is LIVE: a `pii_declared: true` field on a
  # table no `:custom_bag_erasure_specs` entry covers MUST be refused. The guard runs
  # BEFORE any DB insert (it only reads config), so this probe needs no live row — a
  # throwaway repo is never used because the guard short-circuits first. If the guard is
  # neutered, define_field proceeds and either returns {:ok, _} or raises reaching the
  # insert; either way it is NOT the refusal, so the guard is reported un-enforced.
  defp define_guard_enforced? do
    probe = %{
      org_id: "erasure-completeness-probe",
      table_name: "__erasure_completeness_probe__",
      field_name: "probe",
      type: :string,
      pii_declared: true
    }

    match?(
      {:error, {:pii_declared_unerasable, "__erasure_completeness_probe__"}},
      Samen.CustomFields.define_field(probe, __probe_repo__())
    )
  rescue
    _ -> false
  end

  # A non-nil placeholder repo so define_field does not call default_repo!/0; the guard
  # refuses before the repo is ever touched (the insert is never reached).
  defp __probe_repo__, do: Application.get_env(:samen_core, :vault_repo) || :__erasure_completeness_no_repo__

  # Prove the CUSTOM-OBJECT record-bag erasability guard is LIVE (ADR-046 §8 residual #2):
  # a `pii_declared: true` field on a `tnt$obj$…` object table that no `:record_bag_erasure_specs`
  # entry covers MUST be refused, exactly as the first-class rung refuses on an un-covered
  # physical table. Like `define_guard_enforced?/0` the guard short-circuits before any DB
  # insert (it only reads config), so this probe needs no live row. If the blanket `tnt$obj$`
  # exemption is restored, define_field returns `{:ok, _}` (or raises reaching the insert) —
  # either way NOT the refusal, so the object-bag guard is reported un-enforced.
  defp define_object_guard_enforced? do
    object_table = Samen.CustomObjects.object_table("__erasure_completeness_probe__")

    probe = %{
      org_id: "erasure-completeness-probe",
      table_name: object_table,
      field_name: "probe",
      type: :string,
      pii_declared: true
    }

    match?(
      {:error, {:pii_declared_unerasable, ^object_table}},
      Samen.CustomFields.define_field(probe, __probe_repo__())
    )
  rescue
    _ -> false
  end

  # (e) vault-routed transcripts (ADR-047 §7.4) — each discovered transcript resource
  # must be covered by a registered retention `:shred` arm keyed on the row's OWN id
  # (the per-row crypto-shred unit). Refutable: `check/1` accepts `:retention_specs`,
  # so a test hands it an empty list and the check must NAME the uncovered transcript.
  # No hard non-vacuity floor here (a host that mounts no agent domain legitimately
  # discovers zero transcripts); non-vacuity is proven by the unit red-path instead.
  defp check_transcript(residues, retention_specs) do
    violations =
      Enum.flat_map(residues, fn r ->
        if transcript_covered?(r, retention_specs) do
          []
        else
          [
            "UNREACHED vault-routed transcript #{r.table}.#{r.column} " <>
              "(#{inspect(r.resource)}): inside the DEK envelope but keyed on the ROW's " <>
              "own id, so subject-level reach is by retention ONLY (ADR-047 §7.4) — and " <>
              "NO registered `:retention_specs` `:shred` arm (subject_field :id) covers " <>
              "this resource. Without it the transcript lives until account erasure. " <>
              "Register the arm (Samen.Erasure.default_specs/1 derives the ratified " <>
              "90-day spec — §9#4)."
          ]
        end
      end)

    {violations,
     %{
       count: length(residues),
       columns: Enum.map(residues, &"#{&1.table}.#{&1.column}"),
       covered:
         residues
         |> Enum.filter(&transcript_covered?(&1, retention_specs))
         |> Enum.map(&"#{&1.table}.#{&1.column}")
     }}
  end

  defp transcript_covered?(r, retention_specs) do
    Enum.any?(retention_specs, fn spec ->
      spec = Samen.Retention.Spec.normalize(spec)

      spec.resource == r.resource and spec.action == :shred and spec.subject_field == :id and
        is_integer(spec.ttl_seconds) and spec.ttl_seconds > 0
    end)
  end

  # (d) regression floor — the already-covered classes must stay wired.
  defp regression_floor do
    non_pii_wired? = loaded_exported?(Samen.NonPii, :redact_for_subject, 3)
    pseudonym_dek_keyed? = loaded_exported?(Samen.Vault, :pseudonym, 1)

    violations =
      []
      |> add_if(not non_pii_wired?, "regression floor: Samen.NonPii.redact_for_subject/3 missing (non_pii! carve-out unwired).")
      |> add_if(not pseudonym_dek_keyed?, "regression floor: Samen.Vault.pseudonym/1 missing (DEK-keyed pseudonym carve-out unwired).")

    %{report: %{non_pii: non_pii_wired?, dek_pseudonym: pseudonym_dek_keyed?}, violations: violations}
  end

  defp add_if(list, true, msg), do: [msg | list]
  defp add_if(list, false, _msg), do: list

  # ---------------------------------------------------------------------------

  defp attribute(resource, name) do
    Ash.Resource.Info.attribute(resource, name)
  rescue
    _ -> nil
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)
end
