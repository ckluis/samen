defmodule Samen.Crm.SequenceSendTest do
  @moduledoc """
  T75 (spec §I2) — CRM sequences actually send, via the C2 delivery chokepoint
  (T28), with reply-detection pause wired to the REAL T74 Mailbox seam.

  Mounted via `test/support/outreach_fixture.ex` (the new `Samen.Scopes.Outreach`
  blueprint) and `test/support/mailbox_fixture.ex` (a SECOND materialization of
  the existing T74 `Samen.Scopes.Mailbox` blueprint — proves reply-detection
  reads REAL `MailMessage` rows, never a third inbound path).

  Every guarantee has a green path AND a discriminating/red twin
  (`Samen.RedPath` anti-tautology discipline — CLAUDE.md):

    1. **Scheduled sends via C2** — an enrolled contact receives step 1 then step
       2 ON SCHEDULE (time-travel: `next_send_at` is genuinely in the future
       after step 1, a same-instant re-scan is a negative control, backdating it
       is what makes step 2 fire) — every delivery attempt goes through
       `Samen.Delivery.Chokepoint.send/2`, proven via the SAME
       `Samen.Delivery.FakeProvider` double the C2 suite uses.
    2. **Suppression is honored — PERMANENTLY** — a suppressed recipient's step
       NEVER reaches the provider (`FakeProvider.calls() == []` for that org);
       the enrollment stops `:stopped`/`:suppressed` and a SECOND due-scan
       proves it never resumes. An unsuppressed contact in the SAME org (the
       positive control) still delivers.
    3. **Reply-detection pause** — an inbound `MailMessage` (T74 Mailbox seam)
       pauses the enrollment before the next step is ever queued; a no-reply
       control in the same org proceeds and completes. Org-pinned: a
       same-`person_id` reply recorded under a DIFFERENT org is invisible.
    4. **Fail-honest keyless send** — with no adapter configured in a non-`:test`
       delivery env, the step outcome is `:blocked` (never `:delivered`) and
       `current_step` never advances past it.
    5. **Org-scope pins** — Sequence/Enrollment/StepSend reads are invisible
       across a two-org boundary (a positive control same-org read still works).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Delivery.{Chokepoint, Deliverability, FakeProvider, ProviderEvent, Suppression, SuppressionCheck}
  alias Samen.Sequences
  alias Samen.Sequences.ReceiptLookup
  alias SamenCore.Support.MailboxFixture
  alias SamenCore.Support.OutreachFixture.{Enrollment, Sequence, StepSend}
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    prev_send_worker = Application.get_env(:samen_core, Samen.Sequences.SendWorker)
    prev_reply_check = Application.get_env(:samen_core, Samen.Sequences.ReplyCheck)
    prev_mailbox_reply_check = Application.get_env(:samen_core, Samen.Sequences.MailboxReplyCheck)
    prev_chokepoint = Application.get_env(:samen_core, Chokepoint)
    prev_suppression_check = Application.get_env(:samen_core, SuppressionCheck)
    prev_delivery_env = Application.get_env(:samen_core, :delivery_env)

    Application.put_env(:samen_core, Samen.Sequences.SendWorker,
      sequence_resource: Sequence,
      enrollment_resource: Enrollment,
      step_send_resource: StepSend,
      adapter: FakeProvider,
      adapter_config: %{configured: true}
    )

    Application.put_env(:samen_core, Samen.Sequences.ReplyCheck, module: Samen.Sequences.MailboxReplyCheck)

    Application.put_env(:samen_core, Samen.Sequences.MailboxReplyCheck,
      message_resource: MailboxFixture.MailMessage
    )

    Application.delete_env(:samen_core, Chokepoint)
    Application.delete_env(:samen_core, :delivery_env)
    FakeProvider.reset()

    on_exit(fn ->
      restore(Samen.Sequences.SendWorker, prev_send_worker)
      restore(Samen.Sequences.ReplyCheck, prev_reply_check)
      restore(Samen.Sequences.MailboxReplyCheck, prev_mailbox_reply_check)
      restore(Chokepoint, prev_chokepoint)
      restore(SuppressionCheck, prev_suppression_check)
      restore(:delivery_env, prev_delivery_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  # ── helpers ──────────────────────────────────────────────────────────────

  defp tenant_scope(org_id, role \\ :admin) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: role, kind: :tenant, plane: :tenant}}
  end

  defp new_sequence(scope, org, steps, attrs \\ %{}) do
    Sequence
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, name: "Outbound intro", status: :active, steps: steps}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp enroll(scope, org, sequence_id, person_id \\ nil) do
    Enrollment
    |> Ash.Changeset.for_create(
      :enroll,
      %{org_id: org, sequence_id: sequence_id, person_id: person_id || Ash.UUID.generate()},
      scope: scope
    )
    |> Ash.create!()
  end

  defp reload_enrollment(id), do: Ash.get!(Enrollment, id, authorize?: false)

  defp step_sends_for(enrollment_id) do
    StepSend
    |> Ash.Query.filter(enrollment_id == ^enrollment_id)
    |> Ash.Query.sort(step_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp scan_and_drain do
    AshOban.Test.schedule_and_run_triggers(Enrollment)
    Oban.drain_queue(queue: :automation_timers, with_recursion: true)
  end

  defp inbound_reply!(org, person_id, occurred_at \\ DateTime.utc_now()) do
    mail_message!(org, person_id, direction: :inbound, occurred_at: occurred_at)
  end

  # MED-1 (T75 fix round): a generic mail-message writer so the direction and
  # subject_key conjuncts can each be pinned independently — `inbound_reply!/3`
  # stays the (unchanged) happy-path helper above.
  defp mail_message!(org, person_id, opts) do
    direction = Keyword.get(opts, :direction, :inbound)
    subject_key = Keyword.get(opts, :subject_key, "crm.person")
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    MailboxFixture.MailMessage
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        direction: direction,
        external_id: "msg-#{Ash.UUID.generate()}",
        subject_key: subject_key,
        subject_id: person_id,
        occurred_at: DateTime.truncate(occurred_at, :second),
        subject: "Re: intro",
        body: "Thanks, I'm interested — let's talk.",
        counterparty_address: "contact@example.com"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  @two_steps [
    %{"delay_hours" => 0, "subject" => "Step 1", "body" => "First touch"},
    %{"delay_hours" => 24, "subject" => "Step 2", "body" => "Follow-up"}
  ]

  # ---------------------------------------------------------------------------
  # 1. Scheduled sends via the C2 chokepoint (time-travel)

  describe "scheduled sends route through the C2 chokepoint" do
    test "an enrolled contact receives step 1 then step 2 ON SCHEDULE, both through Chokepoint.send" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)
      enrollment = enroll(scope, org, seq.id)

      assert enrollment.status == :active
      assert enrollment.current_step == 0
      # Step 1 has delay_hours: 0 — due immediately.
      assert DateTime.compare(enrollment.next_send_at, DateTime.utc_now()) in [:lt, :eq]

      scan_and_drain()

      [send_1] = step_sends_for(enrollment.id)
      assert send_1.step_index == 0
      assert send_1.status == :delivered
      assert send_1.provider_message_id != nil
      assert send_1.sent_at != nil

      after_step_1 = reload_enrollment(enrollment.id)
      assert after_step_1.status == :active
      assert after_step_1.current_step == 1
      # Step 2 has delay_hours: 24 — genuinely scheduled in the future.
      hours_out = DateTime.diff(after_step_1.next_send_at, DateTime.utc_now(), :second) / 3600
      assert hours_out > 23.0 and hours_out < 25.0

      # Negative control: re-scanning RIGHT NOW must NOT fire step 2 early.
      scan_and_drain()
      assert length(step_sends_for(enrollment.id)) == 1
      assert reload_enrollment(enrollment.id).current_step == 1

      # Time-travel: simulate 24h elapsing by backdating next_send_at directly
      # (the same "past = DateTime.add(-N)" idiom Samen.Automation.ReminderTest
      # uses for its own AshOban time-travel proof).
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(after_step_1, %{next_send_at: past})

      scan_and_drain()

      sends = step_sends_for(enrollment.id)
      assert length(sends) == 2
      [_send_1, send_2] = sends
      assert send_2.step_index == 1
      assert send_2.status == :delivered

      completed = reload_enrollment(enrollment.id)
      assert completed.status == :completed
      assert completed.current_step == 2
      assert completed.next_send_at == nil
      assert completed.completed_at != nil

      # Every delivery attempt genuinely reached the chokepoint's configured
      # adapter (Chokepoint.send/2 is the ONLY caller of adapter.deliver/2 —
      # T28's anti-tautology grep; this is the runtime witness of that fact).
      assert length(FakeProvider.calls()) == 2
    end

    test "a sequence with NO steps enrolls straight to :completed (honest: nothing to send)" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, [])
      enrollment = enroll(scope, org, seq.id)

      assert enrollment.status == :completed
      assert enrollment.next_send_at == nil
      assert enrollment.completed_at != nil

      scan_and_drain()
      assert step_sends_for(enrollment.id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # MED-2 (T75 fix round): a stalled in-flight send (the worker never got to
  # run — crashed, discarded, vanished) is NOT a permanent silent stall. The
  # watchdog `next_send_at` (never `nil`) + `find_or_create_step_send/2`'s
  # REUSE of the SAME unresolved row is what makes recovery possible.

  describe "a stalled in-flight send recovers via the watchdog re-scan" do
    test "the enrollment is NEVER unselectable (next_send_at stays non-nil) and self-heals with NO duplicate StepSend row" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)
      enrollment = enroll(scope, org, seq.id)

      # Simulate "the worker never got to run": queue the step via the
      # due-scan trigger, but do NOT drain the Oban queue — modeling a
      # crashed/vanished job with nothing left to show for it.
      AshOban.Test.schedule_and_run_triggers(Enrollment)

      [in_flight_send] = step_sends_for(enrollment.id)
      assert in_flight_send.status == :queued

      in_flight = reload_enrollment(enrollment.id)
      assert in_flight.status == :active
      # MED-2: NEVER nil — a stalled enrollment is still due-scan-selectable.
      refute is_nil(in_flight.next_send_at)
      assert DateTime.compare(in_flight.next_send_at, DateTime.utc_now()) == :gt

      # Time-travel the watchdog window elapsing.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(in_flight, %{next_send_at: past})

      # This time, actually drain — the worker (finally) runs.
      scan_and_drain()

      # Self-healed: exactly ONE StepSend row for step 0 (reused, not
      # duplicated), now genuinely delivered.
      sends = step_sends_for(enrollment.id) |> Enum.filter(&(&1.step_index == 0))
      assert length(sends) == 1
      [resolved] = sends
      assert resolved.id == in_flight_send.id
      assert resolved.status == :delivered

      recovered = reload_enrollment(enrollment.id)
      assert recovered.status == :active
      assert recovered.current_step == 1
    end
  end

  # ---------------------------------------------------------------------------
  # L8 (Phase-6 EDGE-LOW, documented) — at-least-once, not exactly-once

  describe "L8 — a StepSend left non-terminal after a GENUINE send is re-delivered (at-least-once, honestly documented, bounded)" do
    test "the watchdog re-selects and genuinely re-sends with the SAME send_id (the adapter's idempotency key) -- then stops once the write succeeds" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, [%{"delay_hours" => 0, "subject" => "S1", "body" => "B1"}])
      enrollment = enroll(scope, org, seq.id)

      scan_and_drain()

      enrollment = reload_enrollment(enrollment.id)
      assert enrollment.status == :completed
      assert enrollment.current_step == 1

      [delivered_send] = step_sends_for(enrollment.id)
      assert delivered_send.status == :delivered
      assert length(FakeProvider.calls()) == 1
      [{:deliver, %{message: first_message}}] = FakeProvider.calls()

      # Reconstruct the send_worker.ex moduledoc's documented boundary state:
      # a genuine send happened (the delivery above IS genuine — FakeProvider
      # really recorded it), but suppose the FOLLOW-ON writes (`mark/4`'s
      # StepSend update AND `resolve_outcome/3`'s enrollment `current_step`
      # advance) both failed to persist (a correlated DB blip within that
      # SAME `perform/1` call — `mark/4`'s own `rescue` swallows exactly this
      # to `:ok`, so Oban never sees a retryable error). The reachable
      # end-state left behind is: the StepSend row stays non-terminal, and
      # the enrollment stays on the SAME step with a past next_send_at (the
      # in-flight watchdog window that was already set BEFORE the send ran —
      # `Samen.Sequences.queue_step_send/3` — having simply elapsed). We
      # reconstruct that exact end-state directly via the SAME resource
      # actions the real code path uses (`:mark`, `Sequences.transition/2`),
      # not a mock -- this is a genuinely reachable row/enrollment shape,
      # not a hypothetical one.
      FakeProvider.reset()

      {:ok, _} =
        delivered_send
        |> Ash.Changeset.for_update(:mark, %{status: :queued}, authorize?: false)
        |> Ash.update()

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      {:ok, _} = Sequences.transition(enrollment, %{status: :active, current_step: 0, next_send_at: past})

      # The watchdog cycle legitimately re-selects the SAME row (find_or_create_step_send/2's
      # REUSE branch — status :queued) and genuinely re-delivers.
      scan_and_drain()

      assert length(FakeProvider.calls()) == 1
      [{:deliver, %{message: second_message}}] = FakeProvider.calls()

      # THE idempotency key an ESP adapter needs is already stable across the
      # duplicate: send_id is the StepSend row's OWN id, reused (never
      # re-minted) by find_or_create_step_send/2's REUSE path.
      assert second_message.send_id == first_message.send_id
      assert second_message.send_id == delivered_send.id

      # Bounded, not a runaway loop: THIS attempt's mark+transition writes
      # succeed normally (no injected failure this time), so the enrollment
      # reaches :completed and a THIRD due-scan cycle sends nothing further.
      recovered = reload_enrollment(enrollment.id)
      assert recovered.status == :completed

      [only_send] = step_sends_for(enrollment.id)
      assert only_send.id == delivered_send.id
      assert only_send.status == :delivered

      # An HONEST duplicate, not a cached/replayed response: the row's
      # provider_message_id now reflects the SECOND genuine chokepoint call's
      # OWN receipt, distinct from the first.
      refute only_send.provider_message_id == delivered_send.provider_message_id

      FakeProvider.reset()
      scan_and_drain()
      assert FakeProvider.calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Suppression is honored — PERMANENTLY (spec I2 done-criterion 3)

  describe "suppression at the C2 chokepoint stops the enrollment permanently" do
    test "a suppressed recipient's step NEVER reaches the provider; the enrollment stops for good" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)

      suppressed_person = Ash.UUID.generate()
      clean_person = Ash.UUID.generate()

      Application.put_env(:samen_core, Chokepoint, suppression_module: SuppressionCheck)
      Application.put_env(:samen_core, SuppressionCheck, repo: TestRepo)

      assert {:ok, _} =
               Suppression.suppress(TestRepo, %{
                 org_id: org,
                 subscriber_id: suppressed_person,
                 reason: "manual"
               })

      suppressed_enrollment = enroll(scope, org, seq.id, suppressed_person)
      clean_enrollment = enroll(scope, org, seq.id, clean_person)

      scan_and_drain()

      # RED: the suppressed contact's step is refused BEFORE the provider is
      # ever called.
      [suppressed_send] = step_sends_for(suppressed_enrollment.id)
      assert suppressed_send.status == :suppressed

      stopped = reload_enrollment(suppressed_enrollment.id)
      assert stopped.status == :stopped
      assert stopped.paused_reason == :suppressed
      assert stopped.next_send_at == nil
      # current_step untouched — the refused step never counts as sent.
      assert stopped.current_step == 0

      # ANTI-TAUTOLOGY / positive control: an unsuppressed contact in the SAME
      # org, same sequence, genuinely delivers.
      [clean_send] = step_sends_for(clean_enrollment.id)
      assert clean_send.status == :delivered

      # The FakeProvider recorded exactly ONE deliver call — the clean contact's.
      # The suppressed contact's send NEVER reached adapter.deliver/2.
      deliver_calls = Enum.filter(FakeProvider.calls(), fn {cb, _} -> cb == :deliver end)
      assert length(deliver_calls) == 1

      # PERMANENCE: a second due-scan must NOT resume sending — :stopped is not
      # :active, so the AshOban where-clause never selects this row again (unlike
      # the fail-honest :blocked path above, there is no retry backoff here: the
      # row is inert forever until an operator/tenant explicitly re-enrolls).
      scan_and_drain()
      assert reload_enrollment(suppressed_enrollment.id).status == :stopped
      assert length(step_sends_for(suppressed_enrollment.id)) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Reply-detection pause (spec I2 done-criterion 2) — the REAL T74 seam

  describe "an inbound reply pauses the sequence before the next step ever queues" do
    test "a reply pauses enrollment A; a no-reply control (same org) proceeds to completion" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)

      replier = Ash.UUID.generate()
      no_reply = Ash.UUID.generate()

      replier_enrollment = enroll(scope, org, seq.id, replier)
      no_reply_enrollment = enroll(scope, org, seq.id, no_reply)

      # Step 1 (delay_hours: 0) fires for both.
      scan_and_drain()
      assert reload_enrollment(replier_enrollment.id).current_step == 1
      assert reload_enrollment(no_reply_enrollment.id).current_step == 1

      # The replier sends a reply — recorded on the REAL Mailbox seam.
      inbound_reply!(org, replier)

      # Force step 2 due for both (time-travel).
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(replier_enrollment.id), %{next_send_at: past})
      assert {:ok, _} = Sequences.transition(reload_enrollment(no_reply_enrollment.id), %{next_send_at: past})

      scan_and_drain()

      # RED: the replier's step 2 was NEVER queued — only step 1's StepSend exists.
      replier_final = reload_enrollment(replier_enrollment.id)
      assert replier_final.status == :paused
      assert replier_final.paused_reason == :replied
      assert length(step_sends_for(replier_enrollment.id)) == 1

      # ANTI-TAUTOLOGY / positive control: the no-reply enrollment proceeds and
      # completes — proving the pause is caused by the REPLY, not some global
      # freeze.
      no_reply_final = reload_enrollment(no_reply_enrollment.id)
      assert no_reply_final.status == :completed
      assert length(step_sends_for(no_reply_enrollment.id)) == 2
    end

    test "CROSS-ORG: a reply recorded for the SAME person_id under a DIFFERENT org never pauses this org's enrollment" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)

      shared_person_id = Ash.UUID.generate()

      seq = new_sequence(scope_a, org_a, @two_steps)
      enrollment = enroll(scope_a, org_a, seq.id, shared_person_id)

      scan_and_drain()
      assert reload_enrollment(enrollment.id).current_step == 1

      # A reply for the SAME person_id value, but anchored to org_b — must be
      # invisible to org_a's reply check (Samen.Sequences.MailboxReplyCheck is
      # org-pinned).
      inbound_reply!(org_b, shared_person_id)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      final = reload_enrollment(enrollment.id)
      # NOT paused — org_b's reply is invisible across the boundary.
      assert final.status == :completed
      assert length(step_sends_for(enrollment.id)) == 2
    end

    # MED-1 (T75 fix round): the `direction == :inbound` conjunct in
    # Samen.Sequences.MailboxReplyCheck was UNPINNED — dropping it flips zero
    # tests, yet with I1 two-way sync the org's OWN sent mail lands as
    # `:outbound` rows on the SAME `crm.person` anchor. A regression here would
    # make EVERY sequence self-pause after step 1 (the org's own outbound copy
    # of that very step landing on the SAME anchor), silently, suite green.
    test "an OUTBOUND MailMessage on the SAME anchor does NOT pause the sequence (direction conjunct pinned)" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)

      person = Ash.UUID.generate()
      enrollment = enroll(scope, org, seq.id, person)

      scan_and_drain()
      assert reload_enrollment(enrollment.id).current_step == 1

      # The org's OWN sent mail (e.g. the I1 Mailbox sync recording a copy of
      # step 1 from the connected mailbox's Sent folder) — direction :outbound,
      # SAME "crm.person" anchor, SAME person_id.
      mail_message!(org, person, direction: :outbound)

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      final = reload_enrollment(enrollment.id)
      # NOT paused — only an INBOUND message is a reply.
      assert final.status == :completed
      assert length(step_sends_for(enrollment.id)) == 2
    end

    # MED-1 (T75 fix round): the `subject_key == "crm.person"` conjunct was
    # ALSO unpinned. A message anchored to a DIFFERENT object (e.g. the
    # company, not this specific contact) must not pause a contact's sequence
    # just because it happens to carry the same `subject_id` value.
    test "an INBOUND message under a DIFFERENT subject_key does NOT pause the sequence (subject_key conjunct pinned)" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)

      person = Ash.UUID.generate()
      enrollment = enroll(scope, org, seq.id, person)

      scan_and_drain()
      assert reload_enrollment(enrollment.id).current_step == 1

      # Inbound, but anchored to "crm.company" (subject_id coincidentally ==
      # this person's id) — not a reply from THIS contact.
      mail_message!(org, person, direction: :inbound, subject_key: "crm.company")

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      final = reload_enrollment(enrollment.id)
      assert final.status == :completed
      assert length(step_sends_for(enrollment.id)) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # MED-3 (T75 fix round): a bounce/complaint webhook on a sequence step's
  # provider_message_id writes the SAME production `dlv_suppression` row every
  # other send family gets (Samen.Sequences.ReceiptLookup, the SAME
  # Samen.Delivery.Deliverability registration seam
  # Samen.Delivery.MarketingReceiptLookup uses) — closing the gap where only a
  # MANUALLY-suppressed person_id was ever protected.

  defp bounce_event(provider_message_id) do
    %ProviderEvent{
      provider: :postmark,
      event_id: "evt-bounce-#{System.unique_integer([:positive])}",
      kind: :bounce,
      provider_message_id: provider_message_id,
      occurred_at: DateTime.utc_now(),
      payload: %{"MessageID" => provider_message_id, "Type" => "HardBounce"}
    }
  end

  describe "a bounce on a sequence step's provider_message_id suppresses the recipient" do
    test "bounce -> dlv_suppression row -> the recipient's NEXT step is refused as :suppressed" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)

      person = Ash.UUID.generate()
      enrollment = enroll(scope, org, seq.id, person)

      # Step 1 genuinely delivers (FakeProvider), minting a real provider_message_id.
      scan_and_drain()
      [send_1] = step_sends_for(enrollment.id)
      assert send_1.status == :delivered
      assert is_binary(send_1.provider_message_id)

      Application.put_env(:samen_core, Chokepoint, suppression_module: SuppressionCheck)
      Application.put_env(:samen_core, SuppressionCheck, repo: TestRepo)

      # The bounce webhook arrives — matched via Samen.Sequences.ReceiptLookup,
      # the SAME Samen.Delivery.Deliverability domain handler every other send
      # family's bounces flow through.
      assert :ok =
               Deliverability.handle_event(bounce_event(send_1.provider_message_id),
                 repo: TestRepo,
                 receipt_lookup: ReceiptLookup.build(StepSend, Enrollment)
               )

      assert Suppression.suppressed?(TestRepo, org, person)

      # RED: step 2 is now refused at the C2 chokepoint — the SAME net every
      # other send family's suppression flows through.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      [_send_1, send_2] = step_sends_for(enrollment.id)
      assert send_2.status == :suppressed

      stopped = reload_enrollment(enrollment.id)
      assert stopped.status == :stopped
      assert stopped.paused_reason == :suppressed
    end

    test "CROSS-ORG: a bounce-derived suppression row for org A never suppresses org B's enrollment of the SAME person_id" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      shared_person = Ash.UUID.generate()

      seq_a = new_sequence(scope_a, org_a, @two_steps)
      enrollment_a = enroll(scope_a, org_a, seq_a.id, shared_person)

      scan_and_drain()
      [send_a1] = step_sends_for(enrollment_a.id)
      assert send_a1.status == :delivered

      Application.put_env(:samen_core, Chokepoint, suppression_module: SuppressionCheck)
      Application.put_env(:samen_core, SuppressionCheck, repo: TestRepo)

      assert :ok =
               Deliverability.handle_event(bounce_event(send_a1.provider_message_id),
                 repo: TestRepo,
                 receipt_lookup: ReceiptLookup.build(StepSend, Enrollment)
               )

      assert Suppression.suppressed?(TestRepo, org_a, shared_person)
      # ANTI-TAUTOLOGY / positive control: org_b, same person_id value, is
      # UNTOUCHED — dlv_suppression's own compound key (org_id, subscriber_id)
      # scopes the bounce to the org whose step actually bounced.
      refute Suppression.suppressed?(TestRepo, org_b, shared_person)

      seq_b = new_sequence(scope_b, org_b, @two_steps)
      enrollment_b = enroll(scope_b, org_b, seq_b.id, shared_person)
      scan_and_drain()

      [send_b1] = step_sends_for(enrollment_b.id)
      assert send_b1.status == :delivered
      assert reload_enrollment(enrollment_b.id).status == :active
    end
  end

  # ---------------------------------------------------------------------------
  # MED-4 (T75 fix round): :resume bumps reply_cutoff_at, so a resumed
  # enrollment is not immediately re-paused by the SAME stale reply that
  # (correctly) paused it — but a NEW reply after resume DOES pause again.

  @three_steps [
    %{"delay_hours" => 0, "subject" => "Step 1", "body" => "First touch"},
    %{"delay_hours" => 0, "subject" => "Step 2", "body" => "Follow-up"},
    %{"delay_hours" => 0, "subject" => "Step 3", "body" => "Final touch"}
  ]

  describe ":resume bumps the reply-detection cutoff" do
    test "resume does NOT re-pause on the OLD reply, but a NEW reply after resume DOES pause" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @three_steps)

      person = Ash.UUID.generate()
      enrollment = enroll(scope, org, seq.id, person)

      # Step 1 fires.
      scan_and_drain()
      assert reload_enrollment(enrollment.id).current_step == 1

      # A reply pauses it (the SAME mechanism the reply-detection describe
      # block above already proves).
      inbound_reply!(org, person)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      paused = reload_enrollment(enrollment.id)
      assert paused.status == :paused
      assert paused.paused_reason == :replied
      assert paused.current_step == 1

      # Tenant explicitly resumes. Sleep past the second boundary first — both
      # `reply_cutoff_at` values are `utc_datetime` (second precision), so a
      # same-second pause->resume in a fast test would otherwise compare :eq
      # even though the fix genuinely re-wrote the column.
      Process.sleep(1100)

      resumed =
        paused
        |> Ash.Changeset.for_update(:resume, %{}, scope: scope)
        |> Ash.update!()

      assert resumed.status == :active
      assert resumed.paused_reason == nil
      # MED-4: reply_cutoff_at is now STRICTLY AFTER the reply that paused it.
      assert DateTime.compare(resumed.reply_cutoff_at, paused.reply_cutoff_at) == :gt

      # RED (the bug this fix closes): scanning right after resume must NOT
      # re-pause on the SAME OLD reply — step 2 fires normally.
      scan_and_drain()

      after_resume = reload_enrollment(enrollment.id)
      assert after_resume.status == :active
      assert after_resume.current_step == 2
      assert length(step_sends_for(enrollment.id)) == 2

      # ANTI-TAUTOLOGY / positive control: a NEW reply, sent AFTER the resume,
      # DOES pause — proving reply detection is genuinely still live, not
      # disabled by the fix.
      inbound_reply!(org, person)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      final = reload_enrollment(enrollment.id)
      assert final.status == :paused
      assert final.paused_reason == :replied
      assert final.current_step == 2
      # Step 3 was never queued.
      assert length(step_sends_for(enrollment.id)) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # DELTA-2 (T75 closing round): reply_cutoff_at is a nullable column with no
  # default — a hand-nulled (or pre-MED-4-vintage) row must not crash the
  # due-scan. Fall back to enrolled_at, the cutoff's own original value.

  describe "a nil reply_cutoff_at does not crash the due-scan" do
    test "the due-scan completes normally (fallback to enrolled_at), no reply present" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)
      enrollment = enroll(scope, org, seq.id)

      scan_and_drain()
      assert reload_enrollment(enrollment.id).current_step == 1

      # Hand-null reply_cutoff_at (bypasses :system_advance's accept list via
      # force_change_attribute — the same mechanism the internal transitions
      # already use).
      reload_enrollment(enrollment.id)
      |> Ash.Changeset.for_update(:system_advance, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:reply_cutoff_at, nil)
      |> Ash.update!()

      assert reload_enrollment(enrollment.id).reply_cutoff_at == nil

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})

      # DID NOT RAISE (a FunctionClauseError here would fail this test as a
      # crash, not an assertion failure) — and, with no reply on record,
      # proceeds normally to completion.
      scan_and_drain()

      final = reload_enrollment(enrollment.id)
      assert final.status == :completed
      assert final.current_step == 2
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Fail-honest keyless send (ADR-014 §3) — never fakes :delivered

  describe "keyless/fail-honest: no ESP configured => the honest blocked outcome" do
    test "an unconfigured adapter in a non-:test delivery env yields StepSend.status == :blocked, never :delivered" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)
      enrollment = enroll(scope, org, seq.id)

      Application.put_env(:samen_core, Samen.Sequences.SendWorker,
        sequence_resource: Sequence,
        enrollment_resource: Enrollment,
        step_send_resource: StepSend,
        adapter: nil,
        adapter_config: %{}
      )

      Application.put_env(:samen_core, :delivery_env, :prod)

      scan_and_drain()

      [send_1] = step_sends_for(enrollment.id)
      assert send_1.status == :blocked
      refute send_1.status == :delivered

      # MED-5 (T75 fix round): the enrollment surfaces this HONESTLY as
      # `:blocked` — no longer indistinguishable from a healthy `:active`
      # enrollment (paused_reason stays nil; :blocked is its own visible fact).
      blocked = reload_enrollment(enrollment.id)
      assert blocked.status == :blocked
      refute blocked.status == :active
      # current_step NEVER advances past a blocked step (Invariant D1, carried).
      assert blocked.current_step == 0
      # Retried later, not abandoned.
      assert DateTime.compare(blocked.next_send_at, DateTime.utc_now()) == :gt

      # The FakeProvider was never even reachable (adapter nil => Chokepoint
      # blocks before resolving any adapter).
      assert FakeProvider.calls() == []

      # MED-5 (no unbounded row flood): simulate THREE more retry cycles while
      # still unconfigured (backdating next_send_at each time, mirroring the
      # real watchdog/backoff cadence) — the SAME StepSend row is reused
      # (status/queued_at updated in place), never duplicated.
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Enum.each(1..3, fn _ ->
        assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
        scan_and_drain()
      end)

      assert length(step_sends_for(enrollment.id)) == 1
      still_blocked = reload_enrollment(enrollment.id)
      assert still_blocked.status == :blocked
      assert still_blocked.current_step == 0

      # MED-5 (self-recovery, "resume-on-configure"): once an operator wires a
      # real adapter, the VERY NEXT successful send flips the enrollment back
      # to :active with ZERO manual "unblock" action — resolve_outcome/3's
      # success clause sets status unconditionally.
      Application.put_env(:samen_core, Samen.Sequences.SendWorker,
        sequence_resource: Sequence,
        enrollment_resource: Enrollment,
        step_send_resource: StepSend,
        adapter: FakeProvider,
        adapter_config: %{configured: true}
      )

      Application.delete_env(:samen_core, :delivery_env)

      assert {:ok, _} = Sequences.transition(reload_enrollment(enrollment.id), %{next_send_at: past})
      scan_and_drain()

      recovered = reload_enrollment(enrollment.id)
      assert recovered.status == :active
      assert recovered.current_step == 1
      # STILL the SAME single row for step 0 — resolved in place, not a fresh one.
      [resolved_send] = step_sends_for(recovered.id) |> Enum.filter(&(&1.step_index == 0))
      assert resolved_send.status == :delivered
      assert resolved_send.id == send_1.id
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Org-scope pins — every new read is invisible across a two-org boundary

  describe "org-scope pins on the new Outreach reads" do
    test "CROSS-ORG: Sequence/Enrollment/StepSend rows are invisible to a different org's tenant read" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      seq = new_sequence(scope_a, org_a, @two_steps)
      enrollment = enroll(scope_a, org_a, seq.id)
      scan_and_drain()
      [send_row] = step_sends_for(enrollment.id)

      # RED: org_b's own tenant-scoped read sees NONE of org_a's rows.
      assert Sequence |> Ash.Query.filter(id == ^seq.id) |> Ash.read!(scope: scope_b) == []
      assert Enrollment |> Ash.Query.filter(id == ^enrollment.id) |> Ash.read!(scope: scope_b) == []
      assert StepSend |> Ash.Query.filter(id == ^send_row.id) |> Ash.read!(scope: scope_b) == []

      # ANTI-TAUTOLOGY / positive control: org_a's OWN read finds them.
      assert [%{id: found_id}] = Sequence |> Ash.Query.filter(id == ^seq.id) |> Ash.read!(scope: scope_a)
      assert found_id == seq.id
      assert [_] = Enrollment |> Ash.Query.filter(id == ^enrollment.id) |> Ash.read!(scope: scope_a)
      assert [_] = StepSend |> Ash.Query.filter(id == ^send_row.id) |> Ash.read!(scope: scope_a)
    end

    # LOW-6b (T75 fix round): Samen.Sequences.fetch/3's org_id conjunct, pinned
    # with a real assertion (previously only exercised incidentally).
    test "CROSS-ORG: enrolling into ANOTHER org's sequence is refused" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      seq_a = new_sequence(scope_a, org_a, @two_steps)

      # RED: org_b cannot enroll a contact into org_a's sequence.
      assert {:error, _} =
               Enrollment
               |> Ash.Changeset.for_create(
                 :enroll,
                 %{org_id: org_b, sequence_id: seq_a.id, person_id: Ash.UUID.generate()},
                 scope: scope_b
               )
               |> Ash.create()

      # ANTI-TAUTOLOGY / positive control: org_a enrolling into its OWN
      # sequence succeeds.
      assert {:ok, _} =
               Enrollment
               |> Ash.Changeset.for_create(
                 :enroll,
                 %{org_id: org_a, sequence_id: seq_a.id, person_id: Ash.UUID.generate()},
                 scope: scope_a
               )
               |> Ash.create()
    end
  end

  # ---------------------------------------------------------------------------
  # LOW-6c (T75 fix round): the SendWorker's `status in [:active, :blocked]`
  # guard, pinned live — the verifier's ATK9 proved this race reachable (a
  # manual pause landing between "queued" and "the worker actually runs").

  describe "a manual pause landing between queue and delivery is honored" do
    test "SendWorker's status guard skips delivery — the chokepoint is NEVER called" do
      org = Ash.UUID.generate()
      scope = tenant_scope(org)
      seq = new_sequence(scope, org, @two_steps)
      enrollment = enroll(scope, org, seq.id)

      # The due-scan queues the StepSend + enqueues SendWorker, WITHOUT
      # draining yet — the exact window ATK9 raced.
      AshOban.Test.schedule_and_run_triggers(Enrollment)

      [queued_send] = step_sends_for(enrollment.id)
      assert queued_send.status == :queued

      # The race: a human pauses the enrollment before the worker runs.
      reload_enrollment(enrollment.id)
      |> Ash.Changeset.for_update(:pause, %{}, scope: scope)
      |> Ash.update!()

      Oban.drain_queue(queue: :automation_timers, with_recursion: true)

      raced_send = step_sends_for(enrollment.id) |> List.first()
      assert raced_send.status == :skipped
      # The chokepoint (and therefore the adapter) was NEVER reached.
      assert FakeProvider.calls() == []
      # ANTI-TAUTOLOGY: the enrollment stays exactly as the human left it —
      # the race didn't silently flip it back to :active.
      assert reload_enrollment(enrollment.id).status == :paused
    end
  end
end
