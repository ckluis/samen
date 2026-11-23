defmodule Demo.AiGroundingCatalogTest do
  @moduledoc """
  T66 — the D9 runtime catalog (`Samen.AI.Catalog`, ADR-043 §8) wired into demo, the
  API-only dogfood host. Demo authors ZERO new lines for this (the leverage guard,
  INV-5): `Samen.AI.Catalog.schema/1`'s default entry point reads the SAME cross-host
  `config :samen_core, :ash_domains` registry demo already sets in
  `demo/config/config.exs` for `mix samen.verify.catalog_parity` and friends (see
  `Demo.E6CatalogAdoptionProbeTest` for the sibling adoption-probe precedent) — so a
  host that already registered its domains for the shipped verifiers gets AI
  grounding for free.

  Proves, from the ACTUAL host app (not samen_core's isolated fixtures):

    * the ≈0-LOC claim — `Samen.AI.Catalog.schema()` with NO arguments surfaces
      demo's own PII-bearing resource (`Demo.Crm.Contact` / `cnt_contact`), because
      demo's existing config already registers it;
    * `Samen.AI.complete/4` (the kernel) auto-populates `:grounding` from that same
      catalog inside demo's own process — the "kernel consumes it for grounding"
      done-criterion, proven at the host, not just in samen_core.
  """
  use ExUnit.Case, async: true

  alias Samen.AI
  alias Samen.AI.{Catalog, MaskedPayload, Provider}

  setup do
    Provider.Fake.reset()
    :ok
  end

  test "Samen.AI.Catalog.schema/0 surfaces demo's cnt_contact table with NO authored wiring" do
    dict = Catalog.schema()
    table_names = dict["tables"] |> Enum.map(& &1["table_name"])

    assert "cnt_contact" in table_names,
           "demo's own PII-bearing Contact resource must appear via the ambient " <>
             ":samen_core, :ash_domains registry — no new wiring authored for T66"

    [contact_table] = Enum.filter(dict["tables"], &(&1["table_name"] == "cnt_contact"))
    by_col = Map.new(contact_table["fields"], fn f -> {f["column_name"], f["pii"]} end)

    # Plane-aware metadata (pii flag), NO sample values (same probe as samen_core's).
    assert by_col["cnt_full_name"] == true
    assert by_col["cnt_emails"] == true
    assert by_col["cnt_id"] == false

    for field <- contact_table["fields"] do
      refute Map.has_key?(field, "sample")
      refute Map.has_key?(field, "value")
    end
  end

  test "Samen.AI.complete/4 auto-populates :grounding from the catalog inside demo, unwired" do
    assert {:ok, %AI.Completion{}} = AI.complete(:demo_actor_scope, "summarize this contact", %{})

    assert [{:complete, %MaskedPayload{grounding: grounding}}] = Provider.Fake.sent_payloads()

    table_names = grounding.schema["tables"] |> Enum.map(& &1["table_name"])
    assert "cnt_contact" in table_names

    # Derived, not hand-written: matches a fresh direct catalog call byte-for-byte.
    assert grounding.schema == Catalog.schema()
  end

  test "the CRM blueprint's meaning reaches demo's catalog with zero host code (ADR-043 §8a)" do
    [opp] = Enum.filter(Catalog.schema()["tables"], &(&1["table_name"] == "opp_opportunity"))
    by_name = Map.new(opp["fields"], &{&1["logical_name"], &1})

    assert opp["description"] =~ "sales deal"
    assert opp["synonyms"] == ["deal"]

    assert by_name["value"]["description"] =~ "Expected value"
    assert "amount" in by_name["value"]["synonyms"]
    assert by_name["value"]["units"] =~ "ISO 4217"
    assert by_name["status"]["allowed_values"] == ["open", "won", "lost", "on_hold"]
    # the belongs_to source attribute is described by its relationship
    assert by_name["company_id"]["description"] == "The company this deal is with, if any."
    # framework-injected
    assert is_binary(by_name["org_id"]["description"])
  end

  test "every description in demo's catalog is plain schema text: 3+ words, at most 300 chars, no vt_" do
    texts =
      for table <- Catalog.schema()["tables"],
          text <-
            [table["description"]] ++
              Enum.map(table["fields"], & &1["description"]) ++ Enum.map(table["relationships"], & &1["description"]),
          is_binary(text),
          do: text

    assert length(texts) > 100

    for text <- texts do
      assert length(String.split(text)) >= 3, "too short: #{inspect(text)}"
      assert String.length(text) <= 300, "too long: #{inspect(text)}"
      refute String.contains?(text, "vt_"), "carries a vault-token prefix: #{inspect(text)}"
    end
  end
end
