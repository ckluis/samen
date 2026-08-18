defmodule AllowGrantForMcp do
  @moduledoc "Test grant checker: approves every reveal context (grant-holding actor)."
  @behaviour Samen.Reveal.Grant
  @impl true
  def granted?(_context), do: true
end

defmodule VaultStubForMcp do
  @moduledoc "Keyless vault double: on the grant path, reveal/3 returns the canary plaintext."
  # MUST match @rvp_canary below.
  def reveal(%Samen.Masked{}, _repo, _opts), do: {:ok, "canary-mcp-grant-9z8y@leak.example"}
end

defmodule Samen.AI.McpTest do
  @moduledoc """
  RP-T69 — the D4 MCP server (ADR-043 §9): the four tools (browse / search / drafts /
  action-proposals), the JSON-RPC protocol surface, and the EG4 security invariants that are
  the crux of this task:

    * **(a) canary MASKED at the MCP boundary** — a vault-routed field in a browse/drafts MCP
      response is `••••`, never plaintext, never a `vt_*` token. Non-vacuous: a positive
      control asserts a non-PII field is returned CLEAR (the projection is not blanket-masking).
    * **(b) grants NEVER unlock MCP** — a browse handed a live reveal grant + the host opt-in
      STILL masks; and the SAME grant that reveals plaintext on a `:complete` seal masks on
      `:mcp` (the §7.2 categorical rule, non-vacuously proven live).
    * **(c) org-scope** — an MCP session for org B can never browse/search org A's data
      (both browse's hard org filter and the embeddings plane's org filter), with the same-org
      positive control.
    * **(d) action-proposals cannot auto-execute** — proposing a mutating action opens a
      PENDING approval and changes nothing on the subject; only a human (distinct party)
      approving in the UI runs it (the positive control), as the requester.
  """
  use ExUnit.Case, async: false

  alias Samen.AI.{Chokepoint, Mcp, Provider}
  alias Samen.Approvals
  alias Samen.Masked
  alias SamenCore.Support.ApprovalsFixture.{Approval, Document}
  alias SamenCore.Support.EmbeddingsDomain.Article
  alias SamenCore.Support.RevealDomain.RevealPerson
  alias SamenCore.TestRepo

  @rvp_canary "canary-mcp-grant-9z8y@leak.example"
  @doc_canary "canary-mcp-doc-7x6w@leak.example"
  @vt_token "vt_" <> String.duplicate("b", 32)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Provider.Fake.reset()
    :ok
  end

  defp scope(org, opts \\ []) do
    %Samen.Scope{
      actor: %{
        id: Keyword.get(opts, :id, Ash.UUID.generate()),
        org_id: org,
        role: :member,
        plane: Keyword.get(opts, :plane, :tenant)
      }
    }
  end

  defp document(org, secret \\ "ordinary") do
    Samen.Factory.create!(
      Document,
      %{org_id: org, title: "Roadmap", secret: secret},
      authorize?: false
    )
  end

  defp opts, do: [resources: [Document], repo: TestRepo]

  # ==========================================================================
  # Protocol surface (JSON-RPC / tools/list)
  # ==========================================================================

  describe "MCP protocol surface" do
    test "tools/list advertises exactly the four read-or-propose tools" do
      {:reply, resp} = Mcp.handle_rpc(scope(Ash.UUID.generate()), %{"method" => "tools/list", "id" => 1}, [])
      names = resp["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["action_proposals", "browse", "drafts", "search"]
    end

    test "initialize returns the protocol version + serverInfo + tools capability" do
      {:reply, resp} = Mcp.handle_rpc(scope(Ash.UUID.generate()), %{"method" => "initialize", "id" => 1}, [])
      assert resp["result"]["protocolVersion"] == Mcp.protocol_version()
      assert resp["result"]["serverInfo"]["name"] == "samen-mcp"
      assert Map.has_key?(resp["result"]["capabilities"], "tools")
    end

    test "notifications/initialized is a no-reply; an unknown method is a JSON-RPC error" do
      assert :noreply = Mcp.handle_rpc(scope(Ash.UUID.generate()), %{"method" => "notifications/initialized"}, [])

      {:reply, resp} = Mcp.handle_rpc(scope(Ash.UUID.generate()), %{"method" => "frobnicate", "id" => 9}, [])
      assert resp["error"]["code"] == -32_601
    end

    test "a tools/call for an unknown tool returns an isError result (never a transport error)" do
      {:reply, resp} =
        Mcp.handle_rpc(scope(Ash.UUID.generate()), %{
          "method" => "tools/call",
          "id" => 3,
          "params" => %{"name" => "delete_everything", "arguments" => %{}}
        }, [])

      assert resp["result"]["isError"] == true
    end
  end

  # ==========================================================================
  # browse — catalog (metadata only) + records (masked)
  # ==========================================================================

  describe "browse — catalog navigation (metadata only, §8)" do
    test "no `resource` arg serves the runtime catalog with no sample values" do
      {:ok, data} = Mcp.browse(scope(Ash.UUID.generate()), %{}, opts())
      assert data["kind"] == "catalog"
      assert is_map(data["schema"])
    end
  end

  describe "browse — records (EG4 masking, the crux)" do
    test "(a) a vault-routed field is MASKED and a non-PII field is CLEAR (non-vacuous)" do
      org = Ash.UUID.generate()
      document(org, @doc_canary)

      {:ok, data} = Mcp.browse(scope(org), %{"resource" => "apd_document"}, opts())

      assert [rec] = data["records"]
      # Positive control: the non-PII field is returned CLEAR (projection is not blanket-masking).
      assert rec["title"] == "Roadmap"
      # The vault-routed field is masked at the boundary.
      assert rec["secret"] == Masked.mask()

      dump = inspect(data)
      refute dump =~ @doc_canary, "the canary plaintext reached the MCP boundary"
      refute dump =~ "vt_", "a vt_* token reached the MCP boundary"
    end

    test "(c) org-scope: org B's browse never returns org A's records (positive control: A sees its own)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      document(org_a, @doc_canary)

      # Positive control — org A browses its own row.
      {:ok, a_data} = Mcp.browse(scope(org_a), %{"resource" => "apd_document"}, opts())
      assert a_data["count"] == 1

      # RP-T69 (c): org B — same tool, same resource — sees NOTHING.
      {:ok, b_data} = Mcp.browse(scope(org_b), %{"resource" => "apd_document"}, opts())
      assert b_data["count"] == 0
      assert b_data["records"] == []
    end

    test "a scope with no org is refused fail-closed (never a cross-org guess)" do
      assert {:error, :no_org} =
               Mcp.browse(%Samen.Scope{actor: %{id: "u", org_id: nil}}, %{"resource" => "apd_document"}, opts())
    end
  end

  # ==========================================================================
  # (b) grants NEVER unlock MCP (ADR-043 §7.2, INV-7)
  # ==========================================================================

  describe "grants never unlock MCP plaintext (§7.2)" do
    test "(b) the SAME live grant reveals on :complete but MASKS on :mcp; browse masks despite grant opts" do
      op = %{plane: :operator}
      field = RevealPerson |> Samen.Pii.Info.pii_attributes() |> Enum.at(0) |> Map.get(:name)

      rec =
        RevealPerson
        |> struct(id: Ash.UUID.generate(), display_name: "Canary Corp")
        |> Map.put(field, Masked.new(@vt_token, field))

      grant_on = [
        actor: op,
        bindings: [{[rec], RevealPerson}],
        grant_egress?: true,
        grant: AllowGrantForMcp,
        vault: VaultStubForMcp,
        repo: :fake_repo
      ]

      # Positive control — the grant IS live: on a :complete seal it egresses the plaintext.
      assert {:ok, complete_payload} = Chokepoint.seal(:complete, ["ctx"], grant_on)
      assert @rvp_canary in complete_payload.segments

      # RP-T69 (b): the IDENTICAL grant on the :mcp seal MASKS — grants never apply to :mcp.
      assert {:ok, mcp_payload} = Chokepoint.seal(:mcp, [], grant_on)
      refute Enum.any?(mcp_payload.segments, &(to_string(&1) =~ @rvp_canary))
      assert Enum.all?(mcp_payload.segments, &(&1 == Masked.mask()))

      # And the browse TOOL, handed the same grant opts, still masks a real record.
      org = Ash.UUID.generate()
      document(org, @doc_canary)

      browse_opts = opts() ++ [grant_egress?: true, grant: AllowGrantForMcp, vault: VaultStubForMcp]
      {:ok, data} = Mcp.browse(scope(org, plane: :operator), %{"resource" => "apd_document"}, browse_opts)

      assert [%{"secret" => mask}] = data["records"]
      assert mask == Masked.mask()
      refute inspect(data) =~ @doc_canary
    end
  end

  # ==========================================================================
  # search — semantic, org-scoped (EG4 + org isolation)
  # ==========================================================================

  describe "search — org-scoped semantic search" do
    test "(c) org B's search never returns org A's vectors (positive control: A finds its own)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      doc = struct(Article, id: Ash.UUID.generate(), body: "the quick brown fox jumps over the lazy dog")
      assert {:ok, 1} = Samen.AI.Embeddings.embed_record(scope(org_a), doc, Article, repo: TestRepo)

      # Positive control — org A finds its own document.
      {:ok, a} = Mcp.search(scope(org_a), %{"query" => "quick brown fox"}, repo: TestRepo)
      assert a["count"] >= 1
      assert [%{"id" => sid} | _] = a["hits"]
      assert sid == doc.id

      # RP-T69 (c): org B — same query — sees nothing (the row does not exist for it).
      {:ok, b} = Mcp.search(scope(org_b), %{"query" => "quick brown fox"}, repo: TestRepo)
      assert b["count"] == 0
      assert b["hits"] == []
    end

    test "a scope with no org is refused fail-closed" do
      assert {:error, :no_org} =
               Mcp.search(%Samen.Scope{actor: %{id: "u", org_id: nil}}, %{"query" => "x"}, repo: TestRepo)
    end
  end

  # ==========================================================================
  # drafts — compose via the T68 verbs, grounded on a masked record
  # ==========================================================================

  describe "drafts — compose content, masked source (EG1 + EG4)" do
    test "(a) a draft grounded on a vaulted record: source preview masked, provider sees no canary" do
      org = Ash.UUID.generate()
      doc = document(org, @doc_canary)

      {:ok, data} =
        Mcp.drafts(
          scope(org),
          %{"verb" => "summarize", "input" => "summarize the account", "resource" => "apd_document", "record_id" => doc.id},
          opts()
        )

      assert data["kind"] == "draft"
      assert is_binary(data["draft"])
      # The masked source preview the agent sees carries no plaintext / token.
      assert [%{"secret" => mask, "title" => "Roadmap"}] = data["source"]
      assert mask == Masked.mask()
      refute inspect(data) =~ @doc_canary

      # EG1: the model prompt the provider received masked the vaulted binding.
      recorded =
        Provider.Fake.sent_payloads()
        |> Enum.map(fn {_cb, p} -> Enum.map_join(p.segments, " ", &to_string/1) end)
        |> Enum.join(" ")

      refute recorded =~ @doc_canary
      refute recorded =~ "vt_"
    end

    test "an ungrounded draft still composes (keyless Fake) and routes through :mcp" do
      org = Ash.UUID.generate()
      {:ok, data} = Mcp.drafts(scope(org), %{"verb" => "generate", "input" => "a welcome email"}, opts())
      assert data["kind"] == "draft"
      assert is_binary(data["draft"])
    end
  end

  # ==========================================================================
  # (d) action-proposals — HUMAN-GATED, never auto-executes
  # ==========================================================================

  describe "action-proposals cannot auto-execute a mutation (human-gate)" do
    setup do
      kind = Approvals.Gate.kind_for(Document, :publish)
      registry = %{kind => {:tenant, Samen.Approvals.Gate}}

      proposal_opts = [
        resources: [Document],
        approval_resource: Approval,
        repo: TestRepo,
        kinds: registry
      ]

      %{kind: kind, proposal_opts: proposal_opts}
    end

    test "(d) proposing :publish opens a PENDING approval and changes NOTHING; a human then executes it",
         %{proposal_opts: proposal_opts} do
      org = Ash.UUID.generate()
      requester = scope(org, id: Ash.UUID.generate())
      doc = document(org)

      # The MCP agent PROPOSES the mutation.
      {:ok, data} =
        Mcp.action_proposals(
          requester,
          %{"resource" => "apd_document", "action" => "publish", "record_id" => doc.id, "reason" => "ship it"},
          proposal_opts
        )

      assert data["status"] == "pending"
      assert data["executed"] == false
      approval_id = data["approval_id"]
      assert is_binary(approval_id)

      # NOTHING happened to the subject — the proposal alone cannot mutate.
      reloaded = Ash.get!(Document, doc.id, authorize?: false)
      assert reloaded.status == :draft
      assert is_nil(reloaded.published_by)

      # Positive control (requester ≠ approver): a HUMAN, distinct party, approves in the UI —
      # only NOW does the Gate re-invoke :publish, as the requester.
      approver_id = Ash.UUID.generate()
      assert approver_id != requester.actor.id

      assert {:ok, _approval, _meta} =
               Approvals.approve(approval_id, approver_id, approval_resource: Approval, repo: TestRepo, kinds: proposal_opts[:kinds])

      published = Ash.get!(Document, doc.id, authorize?: false)
      assert published.status == :published
      # Ran as the REQUESTER, never the approver (approval adds consent, not privilege).
      assert published.published_by == requester.actor.id
    end

    test "a proposal is idempotent while pending (a second propose returns the same approval)",
         %{proposal_opts: proposal_opts} do
      org = Ash.UUID.generate()
      requester = scope(org, id: Ash.UUID.generate())
      doc = document(org)

      args = %{"resource" => "apd_document", "action" => "publish", "record_id" => doc.id}
      {:ok, a} = Mcp.action_proposals(requester, args, proposal_opts)
      {:ok, b} = Mcp.action_proposals(requester, args, proposal_opts)
      assert a["approval_id"] == b["approval_id"]

      # Still nothing executed.
      assert Ash.get!(Document, doc.id, authorize?: false).status == :draft
    end
  end
end
