defmodule Samen.AI.CrmTest do
  @moduledoc """
  T71 (ADR-043 §6.4, D6) — AI on CRM: the T68 intelligence verbs applied to CRM objects.
  Proves the CRUX invariants over `SamenCore.Support.CrmScopeFixture.Person` (the REAL CRM
  scope blueprint mounted in samen_core's own test suite — full_name/emails/phones
  vault-routed, exactly the shape any host's CRM mount carries):

    * **(a) CRM AI egress is MASKED** — a 🔒 canary email in the CRM object is `••••` in the
      provider payload for EACH of the four D6 surfaces (timeline summary, inbound
      classify — no binding, proven separately — next-step recommend, sequence draft),
      never plaintext, never a `vt_*` token. Non-vacuous positive control: the mask token IS
      present (the field was resolved-then-masked, not omitted).
    * **(b) a sequence draft NEVER sends** — `draft_sequence/5` returns a plain
      `%{status: :draft}` map; `Samen.Delivery.FakeProvider.calls() == []` after drafting;
      the module's source references no `Samen.Delivery` at all (structural proof).
    * **(c) org-scope isolation** — org B cannot ground on org A's CRM object
      (`{:error, :source_not_found}`), with the same-org positive control.
    * **(d) the four surfaces execute via the T68 verbs against the fake provider** — the
      done-criteria "spot red test": `classify_inbound/3` (no CRM binding) and
      `recommend_next_step/4` (masked-path CRM binding) both return
      `{:ok, %Completion{}}`.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.{Completion, Crm, Provider}
  alias Samen.Delivery.FakeProvider
  alias SamenCore.Support.CrmScopeFixture.Person
  alias SamenCore.TestRepo

  # A unique 🔒 canary seeded into the CRM person's vault-routed `emails` field.
  @canary "canary-crm-ai-7q2z@leak.example"
  @mask Samen.Masked.mask()

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Provider.Fake.reset()
    FakeProvider.reset()
    :ok
  end

  # The calling actor's scope (tenant plane), serving `org`.
  defp scope(org) do
    %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org, role: :member, plane: :tenant}}
  end

  # A CRM person with a vault-routed 🔒 canary email, in `org`.
  defp person!(org, email \\ @canary) do
    attrs =
      Map.merge(
        %{org_id: org, display_name: "Canary Contact"},
        Samen.Factory.person("Canary", "Contact", email: email)
      )

    Samen.Factory.create!(Person, attrs, authorize?: false)
  end

  defp provider_payload_text do
    Provider.Fake.sent_payloads()
    |> Enum.flat_map(fn {_cb, p} -> Enum.map(p.segments, &to_string/1) end)
    |> Enum.join(" ")
  end

  # ==========================================================================
  # (a) CRM AI egress is masked — the canary never reaches the provider
  # ==========================================================================

  describe "(a) CRM AI egress is masked through the chokepoint" do
    test "summarize_timeline/4: the 🔒 canary is MASKED to the provider; the mask IS present (non-vacuous)" do
      org = Ash.UUID.generate()
      person = person!(org)

      assert {:ok, %Completion{}} = Crm.summarize_timeline(scope(org), Person, person.id)

      payload = provider_payload_text()
      assert payload =~ @mask, "the vault field must resolve-then-mask, not be omitted"
      refute payload =~ @canary, "the 🔒 canary reached the AI provider payload"
      refute payload =~ "vt_", "a vault token reached the AI provider payload"
    end

    test "recommend_next_step/4: the 🔒 canary is MASKED to the provider" do
      org = Ash.UUID.generate()
      person = person!(org)

      assert {:ok, %Completion{}} = Crm.recommend_next_step(scope(org), Person, person.id)

      payload = provider_payload_text()
      assert payload =~ @mask
      refute payload =~ @canary
      refute payload =~ "vt_"
    end

    test "draft_sequence/5: the 🔒 canary is MASKED in the provider payload AND the returned draft body" do
      org = Ash.UUID.generate()
      person = person!(org)

      assert {:ok, %{status: :draft, body: body}} =
               Crm.draft_sequence(scope(org), Person, person.id, "draft a friendly check-in")

      assert is_binary(body)
      refute body =~ @canary, "the drafted body must never carry the canary plaintext"
      refute body =~ "vt_", "the drafted body must never carry a vault token"

      payload = provider_payload_text()
      assert payload =~ @mask
      refute payload =~ @canary
      refute payload =~ "vt_"
    end
  end

  # ==========================================================================
  # (b) a sequence draft NEVER sends
  # ==========================================================================

  describe "(b) a sequence draft never reaches Delivery" do
    test "draft_sequence/5 returns a plain :draft map and sends NOTHING" do
      org = Ash.UUID.generate()
      person = person!(org)

      assert {:ok, %{status: :draft}} =
               Crm.draft_sequence(scope(org), Person, person.id, "draft an outreach sequence")

      assert FakeProvider.calls() == []
    end

    test "STRUCTURAL: samen/ai/crm.ex contains no CODE-level reference to Samen.Delivery (prose in the moduledoc is not code)" do
      path = Path.join(Path.expand("../..", __DIR__), "lib/samen/ai/crm.ex")
      assert File.exists?(path), "sanity: crm.ex must exist at the expected path"

      {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

      {_ast, offenders} =
        Macro.prewalk(ast, [], fn
          {:__aliases__, _, [:Samen, :Delivery | _]} = node, acc -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      assert offenders == [],
             "Samen.AI.Crm must contain no code-level reference to Samen.Delivery — found: #{inspect(offenders)}"
    end
  end

  # ==========================================================================
  # (c) org-scope isolation
  # ==========================================================================

  describe "(c) org-scope isolation" do
    test "org B cannot ground on org A's CRM object (positive control: org A can)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      person = person!(org_a)

      # Positive control — org A grounds on ITS OWN object.
      assert {:ok, %Completion{}} = Crm.summarize_timeline(scope(org_a), Person, person.id)

      # The crux: org B — same tool, same object id — cannot reach org A's object.
      assert {:error, :source_not_found} = Crm.summarize_timeline(scope(org_b), Person, person.id)
      assert {:error, :source_not_found} = Crm.recommend_next_step(scope(org_b), Person, person.id)

      assert {:error, :source_not_found} =
               Crm.draft_sequence(scope(org_b), Person, person.id, "draft something")
    end

    test "an org-less scope is refused fail-closed" do
      assert {:error, :no_org} =
               Crm.summarize_timeline(%Samen.Scope{actor: %{id: "u", org_id: nil}}, Person, "x")
    end
  end

  # ==========================================================================
  # (d) the four D6 surfaces execute via the T68 verbs (spot red test)
  # ==========================================================================

  describe "(d) the four D6 surfaces execute via T68 verbs against the fake provider" do
    test "classify_inbound/3 (no CRM binding — the caller's own free text) executes via the Classify verb" do
      org = Ash.UUID.generate()

      assert {:ok, %Completion{text: text}} =
               Crm.classify_inbound(scope(org), "I would like a refund for my last invoice",
                 params: %{labels: "billing, support, sales"}
               )

      assert is_binary(text)
    end

    test "recommend_next_step/4 (masked-path CRM binding) executes via the Recommend verb" do
      org = Ash.UUID.generate()
      person = person!(org)

      assert {:ok, %Completion{}} = Crm.recommend_next_step(scope(org), Person, person.id)
    end

    test "summarize_timeline/4 and draft_sequence/5 both execute via their verbs" do
      org = Ash.UUID.generate()
      person = person!(org)

      assert {:ok, %Completion{}} = Crm.summarize_timeline(scope(org), Person, person.id)
      assert {:ok, %{status: :draft}} = Crm.draft_sequence(scope(org), Person, person.id, "hi")
    end
  end
end
