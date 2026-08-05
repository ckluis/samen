defmodule T68LeakySeedFixture do
  @moduledoc """
  A modeled leak (T68): a seam-shaped module (like `Samen.AI.Prompt`'s
  `samen_ai_prompt_template_bodies/0`) whose body embeds a `vt_` token NOT at the very
  start of the string — the exact shape a narrowed `String.starts_with?/2` scan (this
  suite's sabotage) would miss but a `String.contains?/2` scan catches. Proves the T68
  check-(c) binding is refutable (sabotage-refutable, anti-tautology).
  """
  def samen_ai_prompt_template_bodies do
    [{:leaky_default, "Reference account token: vt_" <> String.duplicate("b", 32)}]
  end
end

defmodule Samen.AI.PromptResourceTest do
  @moduledoc """
  T68 (ADR-043 §7.5) — the versioned `Samen.AI.Prompt` resource: versioning semantics
  (create/edit pins an immutable new version; old versions retained; a name+version
  reference returns the exact body written), write-time governance (a `vt_` sentinel or
  PII-shaped body is refused), org isolation, and the check-(c) structural-verifier seam
  binding (`samen_ai_prompt_template_bodies/0`) — clean on the real resource, flagged on a
  modeled leak.

  Sabotage-refutable: `scripts/sabotages/49-t68-ai-prompt-vt-scan-weaken.patch` narrows the
  verifier's `String.contains?/2` scan to `String.starts_with?/2`, which flips
  "T68 binds check (c) ..." below (the modeled leak's `vt_` token is not at the string
  start, so the narrowed scan silently passes it).
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.AiPromptMasking, as: V
  alias Samen.AI.Prompt
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  # ── versioning semantics ────────────────────────────────────────────────────────────

  describe "versioning: an edit pins a new immutable version; old versions retained" do
    test "the first write is version 1; a second write for the SAME name is version 2, and both persist unchanged" do
      org = Ash.UUID.generate()
      s = scope(org)
      name = "welcome.greeting.#{uniq()}"

      assert {:ok, v1} = Prompt.new_version(s, name, "Body v1")
      assert v1.version == 1
      assert v1.body == "Body v1"

      assert {:ok, v2} = Prompt.new_version(s, name, "Body v2")
      assert v2.version == 2
      assert v2.body == "Body v2"
      # A distinct row, not an update-in-place of v1.
      refute v2.id == v1.id

      # Referencing an EXACT version returns THAT version's exact body — v1 is retained
      # unchanged even after v2 was written (immutable history).
      assert {:ok, %Prompt{version: 1, body: "Body v1"}} = Prompt.fetch(s, name, 1)
      assert {:ok, %Prompt{version: 2, body: "Body v2"}} = Prompt.fetch(s, name, 2)

      # :latest resolves to the highest version.
      assert {:ok, %Prompt{version: 2, body: "Body v2"}} = Prompt.fetch(s, name, :latest)
    end

    test "a THIRD edit pins version 3 without touching versions 1 or 2 (multi-edit retention)" do
      org = Ash.UUID.generate()
      s = scope(org)
      name = "digest.#{uniq()}"

      {:ok, _} = Prompt.new_version(s, name, "A")
      {:ok, _} = Prompt.new_version(s, name, "B")
      assert {:ok, v3} = Prompt.new_version(s, name, "C")
      assert v3.version == 3

      assert {:ok, %Prompt{body: "A"}} = Prompt.fetch(s, name, 1)
      assert {:ok, %Prompt{body: "B"}} = Prompt.fetch(s, name, 2)
      assert {:ok, %Prompt{body: "C"}} = Prompt.fetch(s, name, 3)
    end

    test "versioning is per {org, name}: a DIFFERENT name in the SAME org starts fresh at version 1" do
      org = Ash.UUID.generate()
      s = scope(org)
      {:ok, _} = Prompt.new_version(s, "name.a.#{uniq()}", "a-body")

      assert {:ok, v1} = Prompt.new_version(s, "name.b.#{uniq()}", "b-body")
      assert v1.version == 1
    end

    test "there is no update/destroy action — Prompt exposes only :read and :new_version" do
      actions = Ash.Resource.Info.actions(Prompt) |> Enum.map(& &1.name)
      assert :read in actions
      assert :new_version in actions
      refute :update in actions
      refute :destroy in actions
    end

    test "the {org, name, version} unique identity exists as a real DB constraint (belt to the computed-version race)" do
      identity_names = Prompt |> Ash.Resource.Info.identities() |> Enum.map(& &1.name)
      assert :name_version in identity_names

      identity = Prompt |> Ash.Resource.Info.identities() |> Enum.find(&(&1.name == :name_version))
      assert identity.keys == [:org_id, :name, :version]
    end

    test "fetch/3 of a nonexistent name returns {:error, :not_found} (never a crash)" do
      org = Ash.UUID.generate()
      assert {:error, :not_found} = Prompt.fetch(scope(org), "nope.#{uniq()}", :latest)
      assert {:error, :not_found} = Prompt.fetch(scope(org), "nope.#{uniq()}", 1)
    end
  end

  # ── write-time governance (fail-closed) ─────────────────────────────────────────────

  describe "write-time governance: a vt_-sentinel or PII-shaped body is refused fail-closed" do
    test "a body carrying a vt_ vault-token sentinel is refused; nothing is written" do
      org = Ash.UUID.generate()
      s = scope(org)
      name = "leaky.#{uniq()}"
      body = "here is a token: vt_" <> String.duplicate("a", 32)

      assert {:error, _} = Prompt.new_version(s, name, body)
      assert {:error, :not_found} = Prompt.fetch(s, name, :latest)
    end

    test "a body that is itself a bare email/SSN/phone shape is refused (shared Samen.Pii.FreeTextScan chokepoint)" do
      org = Ash.UUID.generate()
      s = scope(org)
      assert {:error, _} = Prompt.new_version(s, "pii-shaped.#{uniq()}", "someone@example.com")
    end

    test "POSITIVE CONTROL: an ordinary clean body is accepted (the refusals are not blanket-failing)" do
      org = Ash.UUID.generate()
      s = scope(org)
      assert {:ok, %Prompt{version: 1}} =
               Prompt.new_version(s, "clean.#{uniq()}", "Summarize the ticket below concisely.")
    end
  end

  # ── org isolation ────────────────────────────────────────────────────────────────────

  describe "org isolation: one org cannot read or reference another org's prompts" do
    test "org B's fetch/3 of org A's prompt returns {:error, :not_found} — never a cross-org leak" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      name = "cross-org.#{uniq()}"

      assert {:ok, %Prompt{version: 1}} = Prompt.new_version(scope(org_a), name, "org A's secret prompt")

      # Same name, foreign org: the row does not EXIST for org B's scope (OrgScope FilterCheck
      # — not a 403, a genuine absence).
      assert {:error, :not_found} = Prompt.fetch(scope(org_b), name, :latest)
      assert {:error, :not_found} = Prompt.fetch(scope(org_b), name, 1)

      # Positive control: org A's OWN scope still resolves it (the refusal above is the org
      # filter, not a blanket lookup failure).
      assert {:ok, %Prompt{body: "org A's secret prompt"}} = Prompt.fetch(scope(org_a), name, :latest)
    end

    test "org B cannot enumerate org A's prompt via a raw Ash.read (belt: policy-level, not just the fetch/3 helper)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      name = "raw-read.#{uniq()}"
      {:ok, _} = Prompt.new_version(scope(org_a), name, "org A only")

      require Ash.Query

      assert {:ok, []} =
               Prompt
               |> Ash.Query.filter(name == ^name)
               |> Ash.read(scope: scope(org_b))
    end
  end

  # ── the T68 check-(c) structural-verifier seam ──────────────────────────────────────

  describe "the T68 check-(c) seam binds to a REAL Prompt resource" do
    test "the real Samen.AI.Prompt built-in seed templates are clean (no vt_ sentinel)" do
      assert V.prompt_body_vt_violations([Prompt]) == []

      # Non-vacuous: the seam actually returns the six verb defaults (not an empty/inert list).
      bodies = Prompt.samen_ai_prompt_template_bodies()
      assert length(bodies) == 6

      for verb <- Samen.AI.Verbs.verbs() do
        assert Enum.any?(bodies, fn {name, _} -> name == :"#{verb}_default" end),
               "missing built-in seed template for verb #{verb}"
      end
    end

    test "T68 binds check (c): the real Prompt seed templates are clean; a modeled vt_-in-body leak is flagged (sabotage-refutable)" do
      assert V.prompt_body_vt_violations([Prompt]) == []

      assert [msg] = V.prompt_body_vt_violations([T68LeakySeedFixture])
      assert msg =~ "vt_"
      assert msg =~ "T68LeakySeedFixture"
    end
  end
end
