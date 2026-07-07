defmodule Driftwood.CryptoShredGameday do
  @moduledoc """
  T5.4 — THE CRYPTO-SHRED GAME-DAY against the LIVE Driftwood app.

  This is the machinery the vision doc says you show an auditor: erase a REAL
  Driftwood driver subject whose PII is spread across EVERY tier, run the destruction
  oracle (`mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all`), and prove
  the driver is unrecoverable while the tamper-evident audit/impersonation chain still
  VERIFIES.

  ## The subject and its PII spread (clause: "spread across EVERY tier")

  `seed_driver_across_tiers/2` seeds ONE real `Driftwood.Freight.Driver` and spreads
  its PII across every key-reachable + carve-out tier:

    * **domain rows** — `drv_driver`: full_name/emails/phones (CorePerson composite
      vaults) + `pii_drv_cdl_number` (the scalar CDL vault). The physical columns hold
      only `vt_` tokens; the plaintext is in `pii_vault`.
    * **vault** — `pii_vault` rows for `pii_name` / `pii_email` / `pii_phone` /
      `pii_cdl`, all ciphertext under the driver's per-subject DEK.
    * **aud_event** — dispatch-class + reveal-lifecycle + erasure rows keyed on the
      driver `subject_id` (the append-only event tier).
    * **rollup** — `drl_driver_load_count`: per-driver dispatch counts over aud_event
      (the derived aggregate a pre-shred rollup could resurrect the driver from).
    * **oban job args** — a `Driftwood.Jobs.DispatchWorker` job carrying the driver id
      in its args (token-only).
    * **audit chain** — a second-party REVEAL on the driver (request → approve →
      reveal) drives `aud_chain` entries; the erasure appends the `erasure` entry.
    * **registered non_pii!** — `drv_cdl_state` / `drv_cdl_expiry` (the carve-out
      key-shred cannot reach; erased by row-level redaction).
    * **wide-event sink / trace-sink** — schema-level (token/bounded-id/pseudonym
      only); the pseudonym unlinks on shred.

  ## Running the oracle (the auditor CLI contract)

  `run_oracle_cli/2` shells out to the REAL mix task exactly as an auditor would:

      mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all \\
        --replica none --domain Driftwood.Crm --domain Driftwood.Freight \\
        --domain Driftwood.Aggregate

  It returns `{output, exit_code}`. Post-shred a properly-erased driver EXITS 0 with a
  full slate of positive `:pass` attestations; a leak in any tier EXITS 1.

  ## KMS keystore sharing (why the game-day pins the store)

  The seed+shred and the oracle CLI are SEPARATE OS processes. The KMS attestation
  tier reads the wrapped-DEK / tombstone store as the system of record — so both
  processes MUST read the SAME FileBacked store, or the CLI sees a fresh never-keyed
  store and mis-reports `:absent`. The game-day script pins `:kms_key_dir` to a fixed
  project-local scratch dir and exports `DRIFTWOOD_KMS_KEY_DIR` so the subprocess's
  `config/test.exs` picks up the identical store. (Deploy seam: real AWS KMS is an
  operator TODO — the store is external to Postgres either way, so the ADR-001
  key-absence-from-PITR guarantee is identical.)
  """

  alias Driftwood.Repo
  alias Samen.Reveal.Grants

  @doc """
  Seed ONE real Driftwood driver and spread its PII across every tier. Returns a map:

      %{
        org_id: <uuid>, driver_id: <uuid>, carrier_id: <uuid>, load_id: <uuid>,
        cdl_plaintext: "CDL-…", name: %{first, last}, email: "…", phone: "…",
        reveal_grant_id: <uuid>, oban_job_id: <int>
      }

  All writes go through the SAME substrate paths the app uses (Ash create, the vault
  seam, the reveal-grant multi, the aud_event/aud_chain writers). Nothing is faked.
  """
  @spec seed_driver_across_tiers(keyword()) :: map()
  def seed_driver_across_tiers(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    :ok = Driftwood.NonPiiSetup.register_all()

    org_id = Keyword.get(opts, :org_id, Ecto.UUID.generate())
    actor = %{org_id: org_id, role: :admin}

    # Tier-1 custom fields this scenario writes (T3.8 rejects a custom-bag value
    # without a tnt_field definition).
    define_custom_fields(org_id, repo)
    seed_pipeline(org_id, actor)

    carrier = create_company(org_id, "Blue Ridge Carriers", %{"company_role" => "carrier"})
    load = create_load(org_id, "Dallas -> Los Angeles dry van", 480_000, "TX->CA")

    # The real subject. Unique, obviously-PII plaintext so the oracle red paths can
    # grep for a leak.
    cdl_plaintext = "CDL-GAMEDAY-#{unique()}"
    name = %{first: "Marisol", last: "Gameday-#{unique()}"}
    email = "marisol.gameday.#{unique()}@driftwood.test"
    phone = "+1-555-#{:rand.uniform(900_000) + 100_000}"

    driver =
      Driftwood.Freight.Driver
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          carrier_id: carrier.id,
          full_name: name,
          emails: [email],
          phones: [phone],
          cdl_number: cdl_plaintext,
          cdl_state: "TX",
          cdl_expiry: Date.utc_today() |> Date.add(365) |> Date.to_iso8601(),
          medical_card_expiry: Date.add(Date.utc_today(), 180),
          eld_provider: :samsara,
          status: :available
        },
        authorize?: false
      )
      |> Ash.create!()

    driver_id = to_string(driver.id)

    # --- aud_event: dispatch-class events keyed on the driver subject (the raw
    #     stream the load-count rollup summarises). Three loads dispatched.
    for i <- 1..3 do
      {:ok, _} =
        Samen.AuditEvent.insert(repo, %{
          event_type: "dispatch",
          subject_id: driver_id,
          correlation_id: org_id,
          detail: "dispatch load ##{i} (ticket DW-#{unique()})",
          occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        })
    end

    # --- rollup: materialise the per-driver load-count rollup from the raw events.
    {:ok, _} = Samen.Rollup.rebuild_all(repo)

    # --- oban job args: enqueue a dispatch worker carrying the driver id (token-only
    #     args). Manual Oban in test — the row is visible, not auto-executed.
    {:ok, job} = Driftwood.Jobs.DispatchWorker.enqueue(driver_id, load.id, org_id)

    # --- audit chain: a SECOND-PARTY reveal on the driver (request → distinct
    #     approval → reveal) writes aud_event + aud_chain entries keyed on the driver.
    # The reveal capability binds to the REQUESTOR (the desk agent who files the
    # request), under a DISTINCT-party approval by a second operator. The requestor is
    # the party who then unmasks the CDL through the single decrypt chokepoint.
    requestor = "operator:desk-agent"
    approver = "operator:auditor-demo"

    {:ok, request} =
      Grants.request(%{
        subject_id: driver_id,
        requestor_id: requestor,
        reason: "Carrier onboarding CDL verification, ticket DW-#{unique()}",
        resource: Driftwood.Freight.Driver,
        action: :reveal_driver,
        repo: repo
      })

    {:ok, grant} = Grants.approve(request, %{granted_by: approver, repo: repo})

    # Drive the actual reveal through the single decrypt chokepoint (proves the CDL
    # is decryptable PRE-shred — the anti-tautology anchor for the CDL red path).
    # The requestor reveals under the distinct-party grant.
    {:ok, revealed_cdl} = Driftwood.OperatorReveal.reveal_cdl(requestor, driver_id)

    unless revealed_cdl == cdl_plaintext do
      raise "seed sanity check failed: revealed CDL #{inspect(revealed_cdl)} != #{inspect(cdl_plaintext)}"
    end

    %{
      org_id: org_id,
      driver_id: driver_id,
      carrier_id: carrier.id,
      load_id: to_string(load.id),
      cdl_plaintext: cdl_plaintext,
      name: name,
      name_last: name.last,
      email: email,
      phone: phone,
      reveal_request_id: request.id,
      reveal_grant_id: grant.id,
      oban_job_id: job.id,
      requestor: requestor,
      approver: approver,
      # `operator` kept as an alias for the party that reveals (the requestor), so
      # callers/tests reference one field for "who unmasks the CDL".
      operator: requestor
    }
  end

  @doc """
  Run the destruction oracle CLI exactly as an auditor would (a separate OS process).
  Returns `{output, exit_code}`.
  """
  @spec run_oracle_cli(binary(), keyword()) :: {String.t(), non_neg_integer()}
  def run_oracle_cli(driver_id, opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    extra = Keyword.get(opts, :extra_args, [])

    args =
      [
        "samen.verify.no_plaintext_pii",
        "--subject",
        driver_id,
        "--tiers",
        "all",
        "--replica",
        "none",
        "--domain",
        "Driftwood.Crm",
        "--domain",
        "Driftwood.Freight",
        "--domain",
        "Driftwood.Aggregate"
      ] ++ extra

    System.cmd("mix", args,
      cd: project_dir,
      env: oracle_env(),
      stderr_to_stdout: true
    )
  end

  # The env the oracle subprocess needs: MIX_ENV=test + the shared KMS keystore.
  defp oracle_env do
    [{"MIX_ENV", "test"}] ++
      case System.get_env("DRIFTWOOD_KMS_KEY_DIR") do
        nil -> []
        dir -> [{"DRIFTWOOD_KMS_KEY_DIR", dir}]
      end
  end

  # -- builders (seed harness; all authorize?: false) ------------------------

  defp define_custom_fields(org_id, repo) do
    for {table, field} <- [{"fcm_company", "company_role"}, {"fop_opportunity", "lane"}] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: org_id, table_name: table, field_name: field, type: :string},
          repo
        )
    end

    :ok
  end

  defp seed_pipeline(org_id, actor) do
    Enum.each(Driftwood.Seeds.load_stages(), fn stage ->
      Driftwood.Crm.Pipeline
      |> Ash.Changeset.for_create(:create, Map.put(stage, :org_id, org_id),
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()
    end)

    :ok
  end

  defp create_company(org_id, name, custom) do
    Driftwood.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, custom: custom},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp create_load(org_id, name, value_cents, lane) do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, name: name, value_cents: value_cents, status: :open, custom: %{"lane" => lane}},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp unique, do: :erlang.unique_integer([:positive]) |> Integer.to_string()
end
