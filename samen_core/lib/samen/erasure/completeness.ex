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
      spec covers its table). The gate asserts BOTH governing mechanisms are live.
    * **(c) `storage_key` columns** — raw stored file blobs (outside the DEK envelope).
      A subject-linked blob (the resource carries a data-subject field, e.g.
      `uploaded_by_id`) must be covered by a `:file_erasure_specs` entry. An org-asset
      blob (no data-subject field) is not a per-subject-erasure residue; it is REPORTED
      as an org-lifecycle residual (named, not silently dropped).
    * **(d) regression floor** — the already-covered classes: `non_pii!` columns
      (redacted row-level inside `shred/2`) and DEK-keyed pseudonyms (unlinked for free
      by key-shred). Asserted still-wired so a refactor cannot drop them.

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

  # Physical attributes that mark a File-like resource's data subject (the uploader).
  # A `storage_key` resource carrying one of these is subject-linked (per-subject
  # erasable); one carrying none is an org-asset blob (org-lifecycle, not subject-shred).
  @subject_fields [:uploaded_by_id]

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
  Discover every out-of-envelope residue across `resources/1`.

  Returns `%{derived_linkable: [...], storage_key: [...], custom_bag: [...]}`.
  """
  @spec discover(keyword()) :: %{
          derived_linkable: [map()],
          storage_key: [map()],
          custom_bag: [map()]
        }
  def discover(opts \\ []) do
    resources = resources(opts)

    %{
      derived_linkable: DerivedLinkable.discover(resources),
      storage_key: discover_storage_key(resources),
      custom_bag: discover_custom_bag(resources)
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
    * `:skip_bag_guard?` — skip the live `pii_declared` guard probe (tests without a repo).
  """
  @spec check(keyword()) :: {:ok, map()} | {:error, term()}
  def check(opts \\ []) do
    residues = discover(opts)

    bidx_specs = opts[:bidx_specs] || Application.get_env(:samen_core, :blind_index_erasure_specs, [])
    file_specs = opts[:file_specs] || Application.get_env(:samen_core, :file_erasure_specs, [])

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
        {sk_violations, sk_report} = check_storage_key(residues.storage_key, file_specs)
        {bag_violations, bag_report} = check_custom_bag(residues.custom_bag, opts)
        floor = regression_floor()

        violations = dl_violations ++ sk_violations ++ bag_violations ++ floor.violations

        report = %{
          derived_linkable: dl_report,
          storage_key: sk_report,
          custom_bag: bag_report,
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
  defp check_storage_key(residues, specs) do
    {subject_linked, org_assets} = Enum.split_with(residues, & &1.subject_field)

    violations =
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

    report = %{
      count: length(residues),
      subject_linked: Enum.map(subject_linked, &"#{&1.table}.#{&1.column}"),
      org_assets: Enum.map(org_assets, &"#{inspect(&1.resource)} (#{&1.table}.#{&1.column})")
    }

    {violations, report}
  end

  defp file_covered?(r, specs) do
    Enum.any?(specs, fn spec -> Map.get(spec, :file_module) == r.resource end)
  end

  # (b) custom bag — masking automatic + erasure guaranteed at the define chokepoint.
  defp check_custom_bag(residues, opts) do
    masking_ok? = masking_arm_present?()
    guard_ok? = if opts[:skip_bag_guard?], do: true, else: define_guard_enforced?()

    violations =
      cond do
        residues == [] ->
          # Not fatal on its own (bags are optional), but if present must be governed.
          []

        not masking_ok? ->
          [
            "custom-bag MASKING arm missing: the universal `pii_declared` masking resolver " <>
              "(Samen.Api.PiiResolution) is not present — a pii_declared bag key could ship " <>
              "UNMASKED to an operator without a grant."
          ]

        not guard_ok? ->
          [
            "custom-bag ERASURE guard not enforced: `Samen.CustomFields.define_field/2` no " <>
              "longer REFUSES a `pii_declared: true` field on an un-covered table — a " <>
              "pii_declared bag could ship UN-ERASABLE (no `:custom_bag_erasure_specs` arm)."
          ]

        true ->
          []
      end

    {violations,
     %{
       count: length(residues),
       columns: Enum.map(residues, &"#{&1.table}.#{&1.column}"),
       masking_arm: masking_ok?,
       erasure_guard: guard_ok?
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
