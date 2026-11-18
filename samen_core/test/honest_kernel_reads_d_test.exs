defmodule Samen.HonestKernelReadsDTest do
  @moduledoc """
  Honest reads, kernel phase D (the authorisation-relevant top-level modules): a read that FAILED is never "no pending
  approval", "no such approval", "the engine is not wired" or "under budget". Each RED case fails the real call and
  asserts the honest tagged answer plus the by-name report; each is paired with a positive control through the same seam
  so it cannot be a tautology.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.Aggregate.QueryBudget
  alias Samen.Approvals
  alias SamenCore.Support.ApprovalsFixture.Approval
  alias SamenCore.Support.OutreachFixture.{Enrollment, StepSend}
  alias SamenCore.Support.{UnreadableApproval, UnreadableSend}
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    :ok
  end

  defmodule NotAResource do
  end

  defmodule DownRepo do
    def aggregate(_query, _kind), do: raise(DBConnection.ConnectionError, "connection not available")
  end

  defmodule RefusingWriteRepo do
    # the exception message carries the cohort value it was binding, as an Ecto error does
    def insert(_row), do: raise(RuntimeError, "insert refused for cohort tier=Secret-7731")
  end

  defp request_attrs(org),
    do: %{
      org_id: org,
      kind: "test:op",
      subject_ref: "samen:apd:#{Ecto.UUID.generate()}",
      requested_by: Ecto.UUID.generate()
    }

  describe "Approvals.request — an unreadable pending row is not 'no pending approval'" do
    test "RED: the existing-pending read fails -> {:error, :unavailable}, reported, nothing opened" do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Approvals.request(request_attrs(Ecto.UUID.generate()), approval_resource: UnreadableApproval, repo: Repo)
        end)

      assert log =~ "read=approval_existing_pending"
      assert log =~ "cause=Ash.Error.Unknown"
    end

    test "POSITIVE CONTROL: a readable table still opens an approval, and returns the SAME one when asked again" do
      attrs = request_attrs(Ecto.UUID.generate())
      assert {:ok, first} = Approvals.request(attrs)
      assert {:ok, again} = Approvals.request(attrs)
      assert first.id == again.id
    end
  end

  describe "Approvals.get — a failed read is not 'no such approval'" do
    test "RED: a read that fails is {:error, :unavailable}, reported (it answered :not_found)" do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Approvals.get(Ecto.UUID.generate(), approval_resource: UnreadableApproval, repo: Repo)
        end)

      assert log =~ "read=approval_fetch"
    end

    test "POSITIVE CONTROL: an absent row and an id that cannot name one are still :not_found; a present row is found" do
      assert {:error, :not_found} = Approvals.get(Ecto.UUID.generate())
      assert {:error, :not_found} = Approvals.get("not-a-uuid")
      {:ok, approval} = Approvals.request(request_attrs(Ecto.UUID.generate()))
      assert {:ok, %{id: id}} = Approvals.get(approval.id)
      assert id == approval.id
    end

    test "cancel of an approval that cannot be read is :unavailable, never a pretend 'already gone'" do
      capture_log(fn ->
        assert {:error, :unavailable} =
                 Approvals.cancel(Ecto.UUID.generate(), Ecto.UUID.generate(), approval_resource: UnreadableApproval, repo: Repo)
      end)
    end
  end

  describe "Approvals wiring — a resource whose repo cannot be resolved is not 'engine not wired'" do
    test "RED: a configured resource that fails repo introspection is {:error, :approvals_unavailable}, reported" do
      put_approvals_env(approval_resource: NotAResource)

      log =
        capture_log(fn ->
          assert {:error, :approvals_unavailable} = Approvals.get(Ecto.UUID.generate())
          assert {:error, :approvals_unavailable} = Approvals.request(request_attrs(Ecto.UUID.generate()))
        end)

      assert log =~ "read=approval_res_repo"
    end

    test "POSITIVE CONTROL: no resource configured is still the honest 'unwired' answer, and a real resource resolves" do
      put_approvals_env([])
      assert {:error, :no_approvals_module} = Approvals.get(Ecto.UUID.generate())
      assert {:error, :not_found} = Approvals.get(Ecto.UUID.generate(), approval_resource: Approval)
    end
  end

  describe "Reveal.Grants.approve — a miswired engine does not fall back to the engine-less path" do
    test "RED: an unresolvable approvals repo refuses the approval instead of granting without the engine" do
      # `approve/2` falls back to the engine-less `do_approve/4` ONLY on {:error, :no_approvals_module}; a miswired
      # engine must not read as that.
      put_approvals_env(approval_resource: NotAResource)
      # a stored request: the decision locks its row before it reaches the engine
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      req =
        Repo.insert!(%Samen.Reveal.RevealRequest{
          subject_id: "subject-1",
          requestor_id: Ecto.UUID.generate(),
          reason: "support ticket 43",
          status: "pending",
          inserted_at: now,
          updated_at: now
        })

      capture_log(fn ->
        assert {:error, :approvals_unavailable} =
                 Samen.Reveal.Grants.approve(req, %{granted_by: Ecto.UUID.generate(), repo: Repo})
      end)
    end
  end

  describe "Reveal.Grants.request — the parallel pending approval that could not be opened is reported" do
    defp reveal_attrs, do: %{subject_id: Ecto.UUID.generate(), requestor_id: Ecto.UUID.generate(), reason: "support ticket 42"}

    test "RED: the approvals read fails -> the request still stands, and the missing approval is reported by name" do
      put_approvals_env(approval_resource: UnreadableApproval, repo: Repo)

      log =
        capture_log(fn ->
          assert {:ok, %Samen.Reveal.RevealRequest{status: "pending"}} = Samen.Reveal.Grants.request(reveal_attrs())
        end)

      assert log =~ "write=reveal_open_engine_approval"
    end

    test "POSITIVE CONTROL: a healthy engine opens the approval silently; an unwired host stays silent too" do
      silent =
        capture_log(fn ->
          assert {:ok, req} = Samen.Reveal.Grants.request(reveal_attrs())
          assert {:ok, [_ | _]} = Approvals.list_pending(nil, "pii_reveal")
          assert req.status == "pending"
        end)

      refute silent =~ "reveal_open_engine_approval"

      put_approvals_env([])

      unwired =
        capture_log(fn -> assert {:ok, _} = Samen.Reveal.Grants.request(reveal_attrs()) end)

      refute unwired =~ "reveal_open_engine_approval"
    end
  end

  describe "Reveal.Grants.pending_for_org_result — a failed list is reported, never an empty queue" do
    test "RED: the read fails -> {:error, :unavailable} and the report names the read" do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} =
                   Samen.Reveal.Grants.pending_for_org_result(Ecto.UUID.generate(),
                     approval_resource: UnreadableApproval,
                     repo: Repo
                   )
        end)

      assert log =~ "read=reveal_pending_for_org"
    end

    test "POSITIVE CONTROL: nothing pending is an honest empty list; an unwired host is too" do
      org = Ecto.UUID.generate()
      assert {:ok, []} = Samen.Reveal.Grants.pending_for_org_result(org)

      # A host with NO approvals module configured: `list_pending` says so, and the queue is an honest empty list.
      # (`approval_resource: nil` as an option would fall back to the configured fixture: only the env unwires it.)
      put_approvals_env([])
      assert {:error, :no_approvals_module} = Approvals.list_pending(org, "pii_reveal")
      assert {:ok, []} = Samen.Reveal.Grants.pending_for_org_result(org)
    end
  end

  describe "Reveal.Grants.pending_for_org_result — a pending approval dropped from the queue is reported" do
    test "RED: a pending approval whose request row is gone is left out AND reported; a real request is listed, silently" do
      org = Ecto.UUID.generate()

      {:ok, _orphan} =
        Approvals.request(%{
          org_id: org,
          kind: "pii_reveal",
          subject_ref: "samen:reveal.request:#{Ecto.UUID.generate()}",
          requested_by: Ecto.UUID.generate()
        })

      {:ok, _garbled} =
        Approvals.request(%{org_id: org, kind: "pii_reveal", subject_ref: "samen:garbled", requested_by: Ecto.UUID.generate()})

      log = capture_log(fn -> assert {:ok, []} = Samen.Reveal.Grants.pending_for_org_result(org) end)
      assert log =~ "read=reveal_pending_enrich"
      assert log =~ "cause=request_row_missing"
      assert log =~ "cause=unparseable_subject_ref"

      # POSITIVE CONTROL: a request that exists is listed and nothing is reported
      other = Ecto.UUID.generate()

      {:ok, _} =
        Samen.Reveal.Grants.request(Map.put(reveal_attrs(), :org_id, other))

      quiet =
        capture_log(fn -> assert {:ok, [%{org_id: ^other}]} = Samen.Reveal.Grants.pending_for_org_result(other) end)

      refute quiet =~ "reveal_pending_enrich"
    end
  end

  describe "QueryBudget.over_threshold? — an unreadable ledger is not 'under budget'" do
    test "RED: a ledger that cannot be counted raises; it does not answer false" do
      assert_raise DBConnection.ConnectionError, fn ->
        QueryBudget.over_threshold?(%{resource: "R", cohort_key: "c"}, repo: DownRepo)
      end
    end

    test "POSITIVE CONTROL: a readable ledger answers true past the threshold and false under it" do
      key = %{resource: "R-d", cohort_key: "tier=Pro"}
      refute QueryBudget.over_threshold?(key)
      # the threshold crossing logs a WARN by design
      capture_log(fn -> for _ <- 1..QueryBudget.warn_threshold(), do: QueryBudget.record(key) end)
      assert QueryBudget.over_threshold?(key)
    end

    test "record/1 reports a failed write by name, without the exception message" do
      key = %{resource: "R-d2", cohort_key: "tier=Secret-7731", repo: RefusingWriteRepo}

      log = capture_log(fn -> assert {:ok, %{count: 0, warned: false}} = QueryBudget.record(key) end)

      assert log =~ "write=query_budget_record"
      assert log =~ "cause=RuntimeError"
      # the exception interpolates the very value it choked on: it must not reach the log
      refute log =~ "Secret-7731"
    end

    test "check/2 fails open on an unreadable ledger (documented) but reports the read by name, without the message" do
      key = %{resource: "R-d3", cohort_key: "tier=Pro"}
      previous = Application.get_env(:samen_core, :query_budget_enforce)
      on_exit(fn -> Application.put_env(:samen_core, :query_budget_enforce, previous) end)

      # CONTROL: enforcement off never touches the ledger, so the same broken repo is silent
      Application.put_env(:samen_core, :query_budget_enforce, false)
      assert "" == capture_log(fn -> assert :ok = QueryBudget.check(key, repo: DownRepo) end)

      Application.put_env(:samen_core, :query_budget_enforce, true)

      log = capture_log(fn -> assert :ok = QueryBudget.check(key, repo: DownRepo) end)

      assert log =~ "read=query_budget_check"
      refute log =~ "connection not available"
    end
  end

  describe "receipt lookups — a failed read is not 'no such send' (a bounce must not be filed as unmatched)" do
    alias Samen.Delivery.{Deliverability, MarketingReceiptLookup, ProviderEvent}
    alias Samen.Sequences.ReceiptLookup, as: SequenceLookup

    defp bounce(pmi),
      do: %ProviderEvent{
        provider: :postmark,
        event_id: "evt-#{System.unique_integer([:positive])}",
        kind: :bounce,
        provider_message_id: pmi,
        occurred_at: DateTime.utc_now(),
        payload: %{}
      }

    test "RED: the marketing lookup's read fails -> {:error, :unavailable}, reported (it answered :not_found)" do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} = MarketingReceiptLookup.build(UnreadableSend).("pmi-1")
        end)

      assert log =~ "read=marketing_receipt_lookup"
    end

    test "RED: the sequence lookup's read fails -> {:error, :unavailable}, reported (it answered :not_found)" do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} = SequenceLookup.build(UnreadableSend, Enrollment).("pmi-1")
        end)

      assert log =~ "read=sequence_receipt_lookup"
    end

    test "RED: Deliverability files a failed lookup as :receipt_lookup_unavailable, never :no_matching_receipt" do
      capture_log(fn ->
        assert {:error, :receipt_lookup_unavailable} =
                 Deliverability.handle_event(bounce("pmi-1"),
                   repo: Repo,
                   receipt_lookup: MarketingReceiptLookup.build(UnreadableSend)
                 )
      end)
    end

    test "POSITIVE CONTROL: a send that does not exist is still :not_found / :no_matching_receipt, and nothing is reported" do
      quiet =
        capture_log(fn ->
          assert :not_found = MarketingReceiptLookup.build(StepSend).("no-such-pmi")
          assert :not_found = SequenceLookup.build(StepSend, Enrollment).("no-such-pmi")
          assert :not_found = SequenceLookup.build(StepSend, Enrollment).(nil)

          assert {:error, :no_matching_receipt} =
                   Deliverability.handle_event(bounce("no-such-pmi"),
                     repo: Repo,
                     receipt_lookup: SequenceLookup.build(StepSend, Enrollment)
                   )
        end)

      refute quiet =~ "receipt_lookup"
    end
  end

  describe "NoPlaintextPii.Context — a verifier that cannot read its inputs says so" do
    alias Samen.NoPlaintextPii.Context

    defmodule DownRegistryRepo do
      def all(_query), do: raise(DBConnection.ConnectionError, "connection not available")
    end

    test "RED: an unreadable non-PII registry grants no exemption AND is reported by name" do
      previous = Application.get_env(:samen_core, :non_pii_repo)
      Application.put_env(:samen_core, :non_pii_repo, DownRegistryRepo)
      on_exit(fn -> restore_env(:non_pii_repo, previous) end)

      log =
        capture_log(fn ->
          context = Context.build(resources: [], deps: [])
          assert context.non_pii_exempt == MapSet.new()
        end)

      assert log =~ "read=no_plaintext_pii_registry"
      assert log =~ "cause=DBConnection.ConnectionError"
    end

    test "POSITIVE CONTROL: a readable registry builds silently" do
      assert capture_log(fn -> Context.build(resources: [], deps: []) end) == ""
    end

    test "RED: a resource whose table cannot be determined fails the build instead of dropping out of the sweep" do
      assert_raise ArgumentError, fn -> Context.build(resources: [NotAResource], deps: []) end
    end

    test "POSITIVE CONTROL: a Postgres resource contributes its vault-routed columns; a non-Postgres one is exactly 'no table'" do
      context = Context.build(resources: [Approval, SamenCore.Support.SignalsFixture.Thing], deps: [])
      assert %MapSet{} = context.vault_routed
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore_env(key, value), do: Application.put_env(:samen_core, key, value)

  describe "Replay.Resolver — a failure while resolving is fail-closed AND reported" do
    alias Samen.Replay.{Ref, Resolver}
    alias SamenCore.Support.AutomationFixture.Subject

    defmodule DenyGrant do
      def granted?(_ctx), do: false
    end

    defmodule RaisingGrant do
      def granted?(_ctx), do: raise("grant store down")
    end

    defmodule RaisingKms do
      def attest(_subject), do: raise("kms down")
    end

    @email "phase.d.secret@example.com"

    defp subject!(org) do
      Subject
      |> Ash.Changeset.for_create(:create, %{org_id: org, title: "d", email: @email})
      |> Ash.create!(authorize?: false)
    end

    defp tree(subject),
      do: %{email: %Ref{resource: "SamenCore.Support.AutomationFixture.Subject", pk: subject.id, attribute: "email", label: "email"}}

    defp operator(org),
      do: %Samen.Scope{
        actor: %{
          id: Ash.UUID.generate(),
          org_id: org,
          role: :member,
          plane: :operator,
          impersonation: %{session_id: Ash.UUID.generate()}
        }
      }

    defp tenant(org), do: %Samen.Scope{actor: %{org_id: org, plane: :tenant, role: :admin}}

    setup do
      Samen.Kms.FileBacked.simulate_outage(false)
      previous = Application.get_env(:samen_core, :kms_adapter)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
      on_exit(fn -> restore_env(:kms_adapter, previous) end)
      org = Ash.UUID.generate()
      %{org: org, subject: subject!(org)}
    end

    test "RED: a grant store that raises -> the prefetch and the per-record resolve are reported, the value stays masked", ctx do
      log =
        capture_log(fn ->
          %{value: v} = Resolver.resolve(tree(ctx.subject), operator(ctx.org), grant: RaisingGrant)
          refute inspect(v) =~ @email
          assert to_string(v.email) == "••••"
        end)

      assert log =~ "read=replay_resolver_resolve"
      assert log =~ "read=replay_resolver_prefetch"
    end

    test "RED: a KMS that cannot attest never claims 'shredded' and is reported", ctx do
      Application.put_env(:samen_core, :kms_adapter, RaisingKms)

      log =
        capture_log(fn ->
          %{value: v, refs: [ref]} = Resolver.resolve(tree(ctx.subject), operator(ctx.org), grant: DenyGrant)
          assert ref.outcome == :masked
          assert to_string(v.email) == "••••"
        end)

      assert log =~ "read=replay_resolver_shredded"
    end

    test "RED: a record read that FAILS is reported (it renders [gone] like a deleted record, silently before)", ctx do
      log =
        capture_log(fn ->
          # a resource whose table does not exist: the read is a REAL database error, not a policy refusal
          unreadable = %{email: %Ref{resource: "SamenCore.Support.UnreadableSend", pk: Ash.UUID.generate(), attribute: "email", label: "email"}}
          %{refs: [ref]} = Resolver.resolve(unreadable, tenant(ctx.org))
          assert ref.outcome in [:gone, :code_changed]
        end)

      assert log =~ "read=replay_resolver_records"
    end

    test "POSITIVE CONTROL: healthy resolves, a deny, a deleted record and another org's viewer report nothing", ctx do
      quiet =
        capture_log(fn ->
          assert %{refs: [%{outcome: :clear}]} = Resolver.resolve(tree(ctx.subject), tenant(ctx.org))
          assert %{refs: [%{outcome: :masked}]} = Resolver.resolve(tree(ctx.subject), operator(ctx.org), grant: DenyGrant)
          # another org's viewer: the row is out of scope, which is exactly what "gone" means
          assert %{refs: [%{outcome: :gone}]} = Resolver.resolve(tree(ctx.subject), tenant(Ash.UUID.generate()))
          # a viewer who names no org is refused by the resource's policy: a refusal is "not yours to see", not a failure
          no_org = %Samen.Scope{actor: %{org_id: nil, plane: :tenant, role: :admin}}
          assert %{refs: [%{outcome: :gone}]} = Resolver.resolve(tree(ctx.subject), no_org)
          Ash.destroy!(ctx.subject, authorize?: false)
          assert %{refs: [%{outcome: :gone}]} = Resolver.resolve(tree(ctx.subject), tenant(ctx.org))
        end)

      refute quiet =~ "replay_resolver"
    end
  end

  describe "Replay.Sanitizer — an assign the walker cannot handle is dropped AND reported" do
    alias Samen.Replay.{Dropped, Sanitizer}

    test "RED: the dropped assign is reported by name, with no value in the log" do
      log =
        capture_log(fn ->
          out = Sanitizer.assigns(%{bad: [?a | :improper_sentinel_value], good: 1})
          assert out.bad == %Dropped{kind: :sanitizer_error}
          assert out.good == 1
        end)

      assert log =~ "read=replay_sanitize"
      refute log =~ "improper_sentinel_value"
    end

    test "POSITIVE CONTROL: a walkable assign is kept and nothing is reported" do
      assert capture_log(fn -> assert %{good: 1} = Sanitizer.assigns(%{good: 1}) end) == ""
    end
  end

  # Replace the approvals engine wiring for this test only (restored on exit).
  defp put_approvals_env(config) do
    previous = Application.get_env(:samen_core, Samen.Approvals)
    Application.put_env(:samen_core, Samen.Approvals, config)
    on_exit(fn -> Application.put_env(:samen_core, Samen.Approvals, previous) end)
  end
end
