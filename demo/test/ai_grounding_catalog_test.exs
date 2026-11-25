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

  test "the Identity blueprint's descriptions reach demo's catalog and say what the code enforces (B1)" do
    tables = Map.new(Catalog.schema()["tables"], &{&1["table_name"], &1})
    key = Map.fetch!(tables, "key_api_key")
    by_name = Map.new(key["fields"], &{&1["logical_name"], &1})

    assert key["description"] =~ "SHA-256 digest of the key is stored"
    # the synonym "api token" was dropped: in driftwood it lands on a table the API does not authenticate against
    refute Map.has_key?(key, "synonyms")

    # a credential stores a digest, never the key; the description must say so
    assert by_name["token_digest"]["description"] =~ "the raw key is never stored"
    # the belongs_to source attribute is described by its relationship
    assert by_name["membership_id"]["description"] =~ "membership that minted the key"

    # secrets: a vault reference is named, never a value; the resource refuses every actor
    totp = tables |> Map.fetch!("crd_credential") |> Map.fetch!("fields") |> Enum.find(&(&1["logical_name"] == "totp_secret"))
    assert totp["description"] =~ "stored in the pii_secret vault, never in this row"
    assert totp["description"] =~ "its policies refuse every actor"
  end

  # A described security rule is only as good as the behaviour behind it. Each pair below names the existing
  # behavioural test (file + test name) that exercises the rule through the real policy path: if that test is
  # renamed or removed, the text no longer has a witness and this test fails until the pairing is repaired.
  defp assert_witness!(path, name) do
    full = Path.expand("../../" <> path, __DIR__)
    assert File.exists?(full), "witness file missing: #{path}"
    assert File.read!(full) =~ ~s(test "#{name}"), "witness test missing from #{path}: #{name}"
  end

  test "the Identity security sentences in demo's catalog match the rules their witnesses prove (B1)" do
    tables = Map.new(Catalog.schema()["tables"], &{&1["table_name"], &1})
    fields = fn table -> tables |> Map.fetch!(table) |> Map.fetch!("fields") |> Map.new(&{&1["logical_name"], &1}) end
    key = fields.("key_api_key")
    invitation = fields.("inv_invitation")
    membership = fields.("mbs_membership")
    org = fields.("ido_org")
    authz = "samen_web/test/samen/web/identity_authz_test.exs"

    # --- key expiry: clamped at create, only shortened by update, refused by the shared lookup at or past it
    expires = key["expires_at"]["description"]
    assert expires =~ "Create clamps it to at most 365 days ahead (90 days when empty)"
    assert expires =~ "an update that sets it can only shorten it and refuses a revoked or expired key"
    assert expires =~ "Samen.Scope.ApiKey.active_query refuses a key at or past it"
    assert Samen.Scope.ApiKey.max_ttl_seconds() == 365 * 24 * 60 * 60
    assert Samen.Scope.ApiKey.default_ttl_seconds() == 90 * 24 * 60 * 60
    now = ~U[2026-01-01 00:00:00Z]
    assert Samen.Scope.ApiKey.expired?(%{expires_at: now}, now)
    refute Samen.Scope.ApiKey.expired?(%{expires_at: DateTime.add(now, 1, :second)}, now)
    assert_witness!(authz, "RED: expiry is clamped on every write that sets it (default create and update)")
    assert_witness!(authz, "RED: an admin cannot EXTEND a live key by update (a later time, or nil) — update may only shorten")
    assert_witness!(authz, "RED: an expired key cannot be revived by update, and the shared lookup still refuses it")
    assert_witness!(authz, "RED: a revoked key and an expired key are never resolved; CONTROL: a live key and a legacy nil-expiry key are")

    # --- key revocation: one-way, one action
    revoked = key["revoked_at"]["description"]
    assert revoked =~ "No action accepts it as input; the revoke action sets it once"
    assert revoked =~ "keeps the original instant on a repeat"
    assert_witness!(authz, "RED: an admin cannot un-revoke a key (revocation is one-way)")

    # --- effective role: the lower of the stored role and the membership's current one; non-active refused
    role = key["minter_role"]["description"]
    assert role =~ "effective_role takes the lower of this and that membership's current role, refusing a non-active one"
    org_id = "6f1c5b3a-1111-4111-8111-000000000001"
    keyrow = %{org_id: org_id, minter_role: :admin}
    assert {:ok, :member} = Samen.Scope.ApiKey.effective_role(keyrow, %{org_id: org_id, role: :member, status: "active"})
    assert {:ok, :admin} = Samen.Scope.ApiKey.effective_role(keyrow, %{org_id: org_id, role: :owner, status: "active"})
    assert :error = Samen.Scope.ApiKey.effective_role(keyrow, %{org_id: org_id, role: :owner, status: "suspended"})

    assert_witness!(
      "samen_core/test/scope_api_key_effective_role_test.exs",
      "RED: a membership in another org (or with no/unloaded org) yields no role; CONTROL: the same org yields the capped role"
    )

    assert_witness!(authz, "RED: minter_role may not exceed the bound membership's CURRENT role (an admin claiming :owner via an owner-scoped actor)")

    # --- key scopes: the wording gives the key's authority as its effective role and must not claim a scope check;
    # no key-auth request path may call one (if one does, the `scopes` description is wrong and must be updated)
    scopes = key["scopes"]["description"]
    assert scopes =~ "A key's authority at use is its effective role (see minter_role)"
    refute scopes =~ ~r/checked against|intersect/i

    root = Path.expand("../..", __DIR__)

    scanned =
      Enum.flat_map(
        ["samen_web/lib/**/*.ex", "demo/lib/**/*.ex", "driftwood/lib/**/*.ex", "pawchart/lib/**/*.ex", "samen_core/priv/templates/*.eex"],
        &Path.wildcard(Path.join(root, &1))
      )

    # anti-tautology: the scan reaches the real key-auth request paths
    for path <- ["demo/lib/demo_web/api/key_auth_plug.ex", "pawchart/lib/pawchart_web/api/mcp_key_resolver.ex", "driftwood/lib/driftwood_web/api/key_auth_plug.ex", "samen_core/priv/templates/api_key_auth_plug_ex.eex"] do
      assert Path.join(root, path) in scanned, "the scopes scan no longer reaches #{path}"
    end

    # code only: heredoc docs and `#` comments are stripped, but a `#{}` interpolation is not a comment
    code = fn file ->
      file
      |> File.read!()
      |> String.replace(~r/@(?:module)?doc\s+(?:~[sS])?"""\n.*?"""/s, "")
      |> String.replace(~r/(?<!")#(?!\{).*$/m, "")
    end

    request_paths =
      for full <- scanned, Regex.match?(~r/\.authorized\?\(/, code.(full)), do: Path.relative_to(full, root)

    assert request_paths == [],
           "a key-auth request path now calls Samen.Scope.ApiKey.authorized?/4, so scopes may be enforced: update the `scopes` " <>
             "description of key_api_key in the Identity blueprint to say what is checked, then this assertion: #{inspect(request_paths)}"

    # --- mark_used is system-only
    assert key["last_used_at"]["description"] =~ "through the system-only mark_used action"
    assert_witness!(authz, "RED: an authorized admin (or owner) cannot forge last_used_at; CONTROL: the auth path (no actor) still stamps it")

    # --- invitation: pending with a 14-day expiry on every create, role rule, no edits afterwards
    invited = invitation["role"]["description"]
    assert invited =~ "Creating needs a verified admin or owner and a role strictly below their own"
    assert invited =~ "no actor can edit it afterwards"
    assert invitation["expires_at"]["description"] =~ "14 days after creation, set by every create"
    refute Samen.Scope.Role.may_manage?(:admin, :admin)
    assert Samen.Scope.Role.may_manage?(:owner, :admin)

    assert_witness!("samen_web/test/samen/web/auth/invitation_test.exs", "RED: an admin cannot invite another admin (the offered role must be STRICTLY below the inviter's own)")
    assert_witness!(authz, "RED: even an owner has no generic update (role/status/email are not actor-writable after creation)")
    assert_witness!(authz, "RED: status is not an input of the generic create (accepted, revoked, junk); CONTROL: without one the row is pending with a 14-day expiry")
    assert_witness!(authz, "RED: a direct create (not through Invite.create) always carries the 14-day expiry")

    # --- membership: out-rank the stored role and the new one; one membership per user and org; only active counts
    assert membership["role"]["description"] =~ "changing or deleting a row also needs its stored role strictly below"
    assert tables["mbs_membership"]["description"] =~ "a create is refused when the user already has a membership there"
    assert membership["status"]["description"] =~ "Only an active membership resolves a role in the organization for a signed-in session or an API key"
    assert_witness!(authz, "RED: an admin cannot demote or suspend an owner or a peer admin (role, status, or both in one write); CONTROL: it can demote a member")
    assert_witness!(authz, "RED: an admin cannot add a second :viewer row for the owner or a peer admin; CONTROL: the owner still resolves as owner, and a fresh user can be added")
    assert_witness!(authz, "RED: a suspended member's EXISTING session resolves no actor and no access to the org; CONTROL: active, and active again after reactivation")

    # --- org: slug check, session cap counts live sessions only
    assert org["slug"]["description"] =~ "refuse a non-empty slug that matches another organization's slug (trimmed, ignoring case) or id"
    assert org["max_concurrent_sessions"]["description"] =~ "live (unrevoked, unexpired) sessions"
    assert_witness!(authz, "RED: `Acme`, ` acme ` and `ACME` collide with `acme`, on update and on create; CONTROL: a different slug is free")
    assert_witness!(authz, "RED: an abandoned EXPIRED session does not occupy a slot, so the live session is not evicted; CONTROL: two live sessions still evict the oldest")

    # --- demo mounts Identity with the public API, so the vault-field wording names the planes PiiResolution implements
    user = fields.("usr_user")
    assert user["full_name"]["description"] =~ "A tenant-plane actor reads it in clear"
    assert user["full_name"]["description"] =~ "an operator only under a reveal grant (else omitted; masked while impersonating)"
    assert user["full_name"]["description"] =~ "AI egress masks it; only a completion call can carry it in clear"
    # the egress sentence's behaviour: a live grant reveals on :complete only (:mcp masks it, :embed refuses a vault field)
    assert_witness!("samen_core/test/ai/mcp_test.exs", "(b) the SAME live grant reveals on :complete but MASKS on :mcp; browse masks despite grant opts")
    assert_witness!("samen_core/test/ai_eval/ai_plane_redteam_test.exs", "embed_field on a 🔒 field is refused and the vector store carries no canary; a non-PII body embeds")
    # (the behaviours behind the Org, ApiKey, Invitation, Membership and User sentences run in
    # `Demo.IdentityCatalogBehaviourTest`; the witnesses above pin the samen_web suites that prove the rest)
  end

  test "every description in demo's catalog is plain schema text: 3+ words, at most 300 chars" do
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
    end
  end

  test "no string anywhere in demo's catalogue carries the vault-token sentinel the chokepoint refuses" do
    leaves = Samen.AI.VtSentinel.leaves(Catalog.schema())

    # anti-tautology: the walk really reaches names, descriptions, labels, synonyms, units and allowed values
    assert length(leaves) > 5_000
    assert Enum.any?(leaves, fn {path, _} -> "allowed_values" in path end)

    offenders = for {path, text} <- leaves, Samen.AI.VtSentinel.in_string?(text), do: {path, text}
    assert offenders == [], "strings the AI chokepoint would refuse: #{inspect(Enum.take(offenders, 5))}"
  end
end
