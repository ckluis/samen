defmodule Mix.Tasks.Samen.Verify.ErasureCompleteness do
  @shortdoc "Fail build when an out-of-DEK-envelope residue has no erasure arm (ADR-046 §6)."

  @moduledoc """
  `mix samen.verify.erasure_completeness` — the ADR-046 §6 CAPSTONE gate.

  ## What it checks

  `Samen.Erasure.shred/2` is a KEY-destruction job: it makes every *vaulted* value for a
  subject undecryptable at once. A plaintext-or-linkable value that lives OUTSIDE the
  per-subject-DEK envelope is NOT reached by key destruction — so it needs an explicit
  erasure arm, or a shredded subject's data survives silently. This task DISCOVERS every
  such residue from the LIVE schema + registries (never `schema.dict.json`, which
  grandfathers pre-existing columns — the exact mechanism that let `email_bidx` ship
  un-erasable) and ASSERTS a registered `subject_id`-keyed arm reaches each:

    * derived-linkable (`_bidx`) columns → a `:blind_index_erasure_specs` tombstone arm,
      via the `Samen.DerivedLinkable` marker registry (an unregistered `_bidx` FAILS);
    * `storage_key` columns (subject-linked) → a `:file_erasure_specs` blob-delete arm;
    * `pii_declared`-capable `:custom` bag columns → the universal masking resolver AND
      the `define_field` erasability guard (masked AND erasable, by construction);
    * regression floor — `non_pii!` redaction and DEK-keyed pseudonyms stay wired.

  The specs are ACTIVATED framework-first: `Samen.Erasure.install_default_specs/1` derives
  them from the host's own materialized resources (the `Samen.Jobs.install_defaults/1`
  twin), so a fresh `gen.app` passes by construction. This task installs them, then checks.

  ## Non-vacuity

  A discovery gate passes trivially when discovery finds nothing. This task FAILS CLOSED
  on an empty residue set — `email_bidx` + `storage_key` columns exist in every host that
  mounts identity + primitives, so an empty discovery is a broken verifier, not a pass.

  The third hard class, `derived_summary` (ADR-048 §7.3), carries the same floor with a
  DECLARED scope: it binds a host that mounts the AI plane (`Samen.AI.Domain` in the host's
  own `:ash_domains`). Such a host discovering zero is a FAILURE, exactly as before. A host
  that does not mount the plane has no agent-run fold ledger; the class is scoped out and
  the task SAYS SO on its own output line. The predicate reads the host's domain list, never
  the transcript attribute the class discovers — so no edit inside the guarded surface can
  switch the floor off.

  ## Exit codes

  - `0` — every discovered residue has a registered erasure arm
  - `1` — a residue is unreached, an arm is missing, or discovery was empty
  """

  use Mix.Task

  alias Samen.Erasure.Completeness

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")

    # Activate the arms framework-first (derived from this host's live schema), exactly
    # as application.ex does at runtime, so the gate checks the REGISTERED arms.
    Samen.Erasure.install_default_specs()

    case Completeness.check() do
      {:ok, report} ->
        dl = report.derived_linkable.count
        sk = report.storage_key.count
        bag = report.custom_bag.count
        tr = report.transcript.count
        ds = report.derived_summary.count

        Mix.shell().info(
          "[erasure-completeness] #{dl} derived-linkable + #{sk} storage_key + #{bag} custom-bag " <>
            "+ #{tr} vaulted-transcript residues discovered — every one reached by a registered " <>
            "erasure arm. ✓"
        )

        # ADR-048 §7.3 (C4). Printed on its OWN line and ALWAYS, because this class is the
        # one whose scope is derived from another class: a reader must be able to see the
        # number, not infer it.
        #
        # C4I4 / the Q-01 ruling: the class's hard floor binds a host that MOUNTS the AI
        # plane (`Samen.AI.Domain` in the host's `:ash_domains`). In such a host zero can
        # never reach here — `check/1`'s hard floor refuses it — so the line is a positive
        # enumeration. In a host that does NOT mount the plane the class is scoped out, and
        # that is stated EXPLICITLY on this same line. A gate that quietly declines to run
        # is indistinguishable from one that passed, so "not applicable" is REPORTED here,
        # never inferred from a missing line or from a bare `0`.
        if report.derived_summary.applicable do
          Mix.shell().info(
            "[erasure-completeness] derived_summary: #{ds} discovered — " <>
              "#{Enum.join(report.derived_summary.columns, ", ")} (ADR-048 §7.3 withdrawal arm " <>
              "wired: #{report.derived_summary.arm_wired})"
          )
        else
          Mix.shell().info(
            "[erasure-completeness] derived_summary: NOT APPLICABLE — this host does not mount the " <>
              "AI plane (Samen.AI.Domain is absent from its :ash_domains), so it has no agent-run " <>
              "fold ledger and the ADR-048 §7.3 hard non-vacuity floor is SCOPED OUT here. This is " <>
              "a declared skip, not a pass: a host that DOES mount the AI plane and discovers zero " <>
              "still FAILS this gate."
          )
        end

        report_transcripts(report.transcript)
        report_org_assets(report.org_asset_residuals)

      {:error, {:no_residues_discovered, class}} ->
        Mix.shell().error(
          "[erasure-completeness] FAIL: discovered ZERO #{class} residues."
        )

        Mix.shell().error(
          "A completeness check that discovers nothing verifies nothing — this is a FAILURE, not a pass. " <>
            "Every host that mounts identity + primitives has email_bidx + storage_key columns; an empty " <>
            "#{class} discovery is a broken verifier (fail-closed, ADR-046 §6 non-vacuity floor)."
        )

        Mix.raise("erasure-completeness: empty #{class} discovery — exit 1")

      {:error, {:incomplete, violations, report}} ->
        Mix.shell().error("[erasure-completeness] FAIL: out-of-envelope residues with NO erasure arm:")

        Enum.each(violations, fn v -> Mix.shell().error("  - #{v}") end)

        Mix.shell().error(
          "A shredded subject's value in these classes survives crypto-shred. Register the arm " <>
            "(Samen.DerivedLinkable + :blind_index_erasure_specs / :file_erasure_specs / " <>
            ":custom_bag_erasure_specs) so `Samen.Erasure.shred/2` reaches it."
        )

        report_org_assets(report.org_asset_residuals)

        Mix.raise("erasure-completeness: unreached residues — exit 1")
    end
  end

  # Vault-routed transcripts (ADR-047 §7.4, batch A2): in-envelope, keyed on the row's
  # own id, reached by the registered retention :shred arm — listed so the coverage is
  # visible, never inferred.
  defp report_transcripts(%{count: 0}), do: :ok

  defp report_transcripts(%{columns: columns}) do
    Mix.shell().info(
      "[erasure-completeness] vault-routed transcript(s) reached by the retention :shred arm " <>
        "(ADR-047 §7.4, 90d §9#4):"
    )

    Enum.each(columns, fn c -> Mix.shell().info("    · #{c}") end)
  end

  # Org-asset blobs (no data-subject field) are NOT per-subject-erasure residues — they
  # are named here as an org-lifecycle residual so the honest gap is visible, never
  # silently dropped (ADR-046 §4.3 out-of-scope note; STOP+REPORT discipline).
  defp report_org_assets([]), do: :ok

  defp report_org_assets(org_assets) do
    Mix.shell().info(
      "[erasure-completeness] NOTE: #{length(org_assets)} org-asset storage_key blob(s) carry no " <>
        "data-subject field, so they are an ORG-LIFECYCLE residual (deleted on row destroy / retention), " <>
        "not a per-subject-erasure residue:"
    )

    Enum.each(org_assets, fn a -> Mix.shell().info("    · #{a}") end)
  end
end
