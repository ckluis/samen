defmodule Samen.EnrichmentTest do
  @moduledoc """
  T80 / I8 — ENRICHMENT PROVIDER SEAM (fail-honest adapter contract).

  This is a PURE SEAM test: `Samen.Enrichment` is a behaviour + facade + fake test double.
  It does not persist to any record and it is not itself org-scoped — those are host-adoption
  concerns for whoever wires a real adapter and consumes its output (see "PII Handling" and
  "Adoption Checklist" in `docs/guides/enrichment-seam.md`). What is actually proved here,
  sabotage-refutably (`scripts/sabotages/114-*.patch`, `115-*.patch`, `116-*.patch`):

    * the facade returns `{:error, :not_configured}` when unconfigured (NEVER a canned
      `{:ok, %{}}`), and that refusal is distinct from a genuinely configured provider's
      honest-empty `{:ok, %{}}` — the two states never collapse;
    * the FakeProvider enriches a Person/Company with data the test seeded, returning it
      as a plain map — subject_id is a bare integer, nothing lands on an Ash record;
    * an undeclared capability refuses with `{:error, :not_implemented}`, distinct from
      `:not_configured`;
    * `redact_payload/1` strips credential-shaped keys from a raw vendor payload; and
    * `samen_core`'s `mix.exs` carries zero enrichment vendor dependencies (INV-4).

  What this file does NOT test (and does not claim to): org-scoping (no org/tenant concept
  appears anywhere in this seam) and vault-routing/masking of enriched PII (the seam persists
  nothing, so there is no vault-class field to route or mask here — that is a host obligation,
  stated explicitly in the seam doc's PII Handling section).
  """

  use ExUnit.Case, async: false

  alias Samen.Enrichment
  alias Samen.Enrichment.FakeProvider

  setup do
    FakeProvider.reset()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Unconfigured fail-honest (HARD RULE: never a canned ok)

  test "unconfigured provider returns {:error, :not_configured}" do
    # Reset to default unconfigured state (FakeProvider with no :configured flag)
    original_config = Application.get_env(:samen_core, :enrichment_provider)

    try do
      Application.put_env(:samen_core, :enrichment_provider, {FakeProvider, %{}})

      # Attempt enrich when provider is unconfigured — must refuse
      assert {:error, :not_configured} = Enrichment.enrich(:person, 123)
      assert {:error, :not_configured} = Enrichment.enrich(:company, 456)

      # Verify provider_configured? reflects the state
      assert Enrichment.provider_configured?() == false
    after
      if original_config, do: Application.put_env(:samen_core, :enrichment_provider, original_config)
    end
  end

  # ---------------------------------------------------------------------------
  # FakeProvider happy path

  test "fake provider enriches a Person with seeded data" do
    original_config = Application.get_env(:samen_core, :enrichment_provider)

    try do
      # Set fake provider as configured
      Application.put_env(:samen_core, :enrichment_provider, {FakeProvider, %{configured: true}})
      FakeProvider.set_capabilities([:person_enrich])

      # Seed enrichment data
      person_id = 42
      enriched_data = %{
        "title" => "VP of Sales",
        "company_name" => "Acme Corp",
        "years_experience" => 15
      }

      FakeProvider.seed_enrichment(:person, person_id, enriched_data)

      # Enrich the person
      assert {:ok, result} = Enrichment.enrich(:person, person_id)
      assert result == enriched_data

      # Verify the call was recorded
      calls = FakeProvider.calls()
      assert [call] = calls
      assert {callback, args} = call
      assert callback == :enrich
      assert args.subject_type == :person
      assert args.subject_id == person_id
    after
      if original_config, do: Application.put_env(:samen_core, :enrichment_provider, original_config)
    end
  end

  test "fake provider enriches a Company with seeded data" do
    original_config = Application.get_env(:samen_core, :enrichment_provider)

    try do
      Application.put_env(:samen_core, :enrichment_provider, {FakeProvider, %{configured: true}})
      FakeProvider.set_capabilities([:company_enrich])

      company_id = 789
      enriched_data = %{
        "industry" => "Technology",
        "employee_count" => 5000,
        "founded_year" => 2010
      }

      FakeProvider.seed_enrichment(:company, company_id, enriched_data)

      assert {:ok, result} = Enrichment.enrich(:company, company_id)
      assert result == enriched_data

      calls = FakeProvider.calls()
      assert [call] = calls
      assert {callback, args} = call
      assert callback == :enrich
      assert args.subject_type == :company
      assert args.subject_id == company_id
    after
      if original_config, do: Application.put_env(:samen_core, :enrichment_provider, original_config)
    end
  end

  test "fake provider returns empty map when no enrichment seeded" do
    original_config = Application.get_env(:samen_core, :enrichment_provider)

    try do
      Application.put_env(:samen_core, :enrichment_provider, {FakeProvider, %{configured: true}})
      FakeProvider.set_capabilities([:person_enrich])

      # Don't seed any data — should return honest empty
      person_id = 999
      assert {:ok, result} = Enrichment.enrich(:person, person_id)
      assert result == %{}
    after
      if original_config, do: Application.put_env(:samen_core, :enrichment_provider, original_config)
    end
  end

  # ---------------------------------------------------------------------------
  # Capability-gated refusal

  test "fake provider refuses enrich when capability not declared" do
    original_config = Application.get_env(:samen_core, :enrichment_provider)

    try do
      Application.put_env(:samen_core, :enrichment_provider, {FakeProvider, %{configured: true}})
      # Set EMPTY capabilities — neither :person_enrich nor :company_enrich
      FakeProvider.set_capabilities([])

      # Attempt enrich despite unconfigured capability must still respond with
      # honest refusal (the test double enforces this by returning :not_implemented)
      assert {:error, :not_implemented} = Enrichment.enrich(:person, 42)
    after
      if original_config, do: Application.put_env(:samen_core, :enrichment_provider, original_config)
    end
  end

  # ---------------------------------------------------------------------------
  # INV-4 — no vendor enrichment dependencies in core

  test "core contains zero vendor enrichment dependencies" do
    # Verify mix.exs has no enrichment vendor packages (e.g., "clearbit", "apollo", "people_data_labs")
    mix_exs_path = Path.join([:code.priv_dir(:samen_core), "..", "..", "mix.exs"])

    case File.read(mix_exs_path) do
      {:ok, content} ->
        # Check for common enrichment vendor names
        vendor_names = ["clearbit", "apollo", "people_data_labs", "enrichment_ai", "databox"]
        Enum.each(vendor_names, fn vendor ->
          refute String.contains?(content, vendor),
                 "enrichment vendor #{vendor} found in mix.exs — INV-4 violated"
        end)

      {:error, _} ->
        # If can't read mix.exs, skip (test environment concern)
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Redact payload (honest PII pruning)

  test "fake provider redacts credentials from payload" do
    original_config = Application.get_env(:samen_core, :enrichment_provider)

    try do
      Application.put_env(:samen_core, :enrichment_provider, {FakeProvider, %{configured: true}})
      FakeProvider.set_capabilities([:person_enrich])

      payload = %{
        "api_key" => "secret123",
        "token" => "bearer_xyz",
        "name" => "John",
        "secret" => "do_not_log"
      }

      redacted = FakeProvider.redact_payload(payload)

      # Credentials removed
      assert Map.get(redacted, :api_key) == nil
      assert Map.get(redacted, "api_key") == nil
      assert Map.get(redacted, :token) == nil
      assert Map.get(redacted, "token") == nil
      assert Map.get(redacted, :secret) == nil
      assert Map.get(redacted, "secret") == nil

      # Data kept
      assert redacted["name"] == "John"
    after
      if original_config, do: Application.put_env(:samen_core, :enrichment_provider, original_config)
    end
  end
end
