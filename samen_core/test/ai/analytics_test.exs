defmodule Samen.AI.AnalyticsTest do
  @moduledoc """
  T71 (ADR-043 §6.4, D7) — AI analytics over the token-blind AGGREGATE plane, the
  samen_core-level (schema/structural) half of the proof. The full end-to-end
  narration-over-suppressed-rows proof (real Postgres, real k-anonymity floor, real
  fake-provider recording — the aggregate-non-leak red-team + its positive control) is
  `demo/test/ai_analytics_test.exs`. THIS file proves the SCHEMA-LEVEL guarantee §6.4
  states verbatim: "the actor's queryable schema has no vault-routed/pii_* columns",
  non-vacuously (a resource that legitimately HAS PII is the one being refused, not an
  already-PII-free one) and with the discriminator cutting both ways (a genuine
  aggregate-plane resource IS admitted).

    * **RED: a non-aggregate (PII-bearing) resource is refused before any row is read** —
      `Samen.AI.Analytics.ask/4` pointed at `SamenCore.Support.CrmScopeFixture.Person`
      (a REAL CRM resource with vault-routed full_name/emails/phones) returns
      `{:error, :not_aggregate_resource}` — the module can never be pointed at a
      PII-bearing resource, full stop; `Samen.Aggregate.read_all/2`'s FIRST check
      (`Samen.Aggregate.Info.aggregate_plane?/1`) refuses it before any `Ash.read` runs.
    * **non-vacuity control** — the refused resource DOES carry vault-routed columns (so
      the refusal is meaningfully protecting something, not a no-op check against an
      already-PII-free resource).
    * **anti-tautology (the discriminator cuts both ways)** — a freshly-compiled, SCHEMA-
      PURE aggregate-plane resource (no PII column at all — the C7 `NoPiiTransformer`
      guarantee) IS admitted by the same gate that refused the CRM resource above. This is
      self-contained (`Code.compile_string/1` + purge, the `no_pii_columns_red_path_test.exs`
      idiom) rather than reaching into another test file's nested fixture — ExUnit may run
      async test files before a same-named module in a DIFFERENT file has been required, so
      cross-file nested-module references are load-order-fragile; a self-contained compile
      has no such dependency.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.Analytics
  alias SamenCore.Support.CrmScopeFixture.Person

  @clean_mod SamenCore.Support.AnalyticsFixture.CleanAggregate
  @clean_src """
  defmodule #{@clean_mod} do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "aac"

    postgres do
      table "aac_thing"
      repo SamenCore.TestRepo
    end

    attributes do
      attribute :tier, :string, public?: true
      attribute :tenant_count, :integer, public?: true
    end

    actions do
      defaults [:read]
    end
  end
  """

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end

  defp scope(org) do
    %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org, role: :member, plane: :tenant}}
  end

  describe "RED: Samen.AI.Analytics.ask/4 refuses a non-aggregate (PII-bearing) resource" do
    test "a real CRM resource (vault-routed full_name/emails/phones) is refused BEFORE any read" do
      assert {:error, :not_aggregate_resource} =
               Analytics.ask(scope(Ash.UUID.generate()), Person, "how many contacts do we have?")
    end

    test "non-vacuity: the refused resource DOES carry vault-routed columns" do
      assert Samen.Pii.Info.vault_routed_columns(Person) != []
      refute Samen.Aggregate.Info.aggregate_plane?(Person)
    end
  end

  describe "anti-tautology: a genuine schema-pure aggregate resource IS admitted (self-contained)" do
    test "a freshly-compiled use Samen.Aggregate.Resource fixture passes the SAME gate that refused the PII resource" do
      purge(@clean_mod)
      modules = Code.compile_string(@clean_src)
      assert Enum.any?(modules, fn {m, _} -> m == @clean_mod end)

      assert Samen.Aggregate.Info.aggregate_plane?(@clean_mod)
      assert Samen.Pii.Info.vault_routed_columns(@clean_mod) == []
    after
      purge(@clean_mod)
    end
  end
end
