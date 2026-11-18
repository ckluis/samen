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
      req = %Samen.Reveal.RevealRequest{id: Ecto.UUID.generate(), requestor_id: Ecto.UUID.generate()}

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
      assert {:ok, []} = Samen.Reveal.Grants.pending_for_org_result(Ecto.UUID.generate())
      assert {:ok, []} = Samen.Reveal.Grants.pending_for_org_result(Ecto.UUID.generate(), approval_resource: nil, repo: Repo)
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

    test "record/1 and check/2 failures are reported by name, without the exception message" do
      key = %{resource: "R-d2", cohort_key: "tier=Pro"}

      log =
        capture_log(fn ->
          assert {:ok, %{count: 0, warned: false}} = QueryBudget.record(Map.put(key, :cohort_key, :not_a_binary_key))
        end)

      assert log =~ "write=query_budget_record"
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

  # Replace the approvals engine wiring for this test only (restored on exit).
  defp put_approvals_env(config) do
    previous = Application.get_env(:samen_core, Samen.Approvals)
    Application.put_env(:samen_core, Samen.Approvals, config)
    on_exit(fn -> Application.put_env(:samen_core, Samen.Approvals, previous) end)
  end
end
