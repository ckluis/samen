defmodule Demo.MarketingConsentLedgerTest do
  @moduledoc """
  F3 Unit 1: the append-only marketing-consent ledger (`Demo.MarketingScope.ConsentEvent`),
  modeled line-for-line on the `mov` subscription-movement ledger.

  Trio:
    * GREEN — a consent transition on Subscriber appends ONE bounded `ConsentEvent` row
      (granted/withdrawn + source + purpose + subject_hash); `Samen.Marketing.Consent.state/3`
      derives the current state latest-event-wins (the SOURCE OF TRUTH, not the mutable
      `consent_at` cache).
    * RED (immutability) — the ledger exposes NO update/destroy action; a consent event is
      an immutable fact. (Sabotage 21 adds a mutable update action → this flips.)
    * ERASURE-SURVIVAL — a `:withdrawn` verdict + its `subject_hash` outlive a subject
      crypto-shred, so "do-not-contact" is honored after the PII is unrecoverable.

  No PII by construction (bounded ids/enums/strings/keyed-hash/timestamps only).
  """
  use Demo.DataCase, async: false

  alias Demo.MarketingScope.{ConsentEvent, Subscriber}
  alias Demo.Identity.Org
  alias Samen.Marketing.Consent
  alias Samen.Erasure

  require Ash.Query
  import Ecto.Query

  @event_resource ConsentEvent

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp events_for(subscriber_id) do
    ConsentEvent
    |> Ash.Query.filter(subscriber_id == ^subscriber_id)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  # =========================================================================
  # GREEN — append + derivation
  # =========================================================================

  test "creating a consented subscriber appends a :granted event; state derives :granted" do
    org = mk_org("consent-grant")

    {:ok, sub} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "grant@marketing.example",
        status: :active,
        source: "signup",
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    [event] = events_for(sub.id)
    assert event.event == :granted
    assert event.source == "signup"
    assert event.purpose == :marketing
    assert is_binary(event.subject_hash) and event.subject_hash != ""

    assert {:ok, :granted} = Consent.state_result(@event_resource, org.id, sub.id)
  end

  test "unsubscribing appends a :withdrawn event; state derives :withdrawn (latest-wins)" do
    org = mk_org("consent-withdraw")

    {:ok, sub} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "wd@marketing.example",
        status: :active,
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    assert {:ok, :granted} = Consent.state_result(@event_resource, org.id, sub.id)

    {:ok, _sub} =
      sub
      |> Ash.Changeset.for_update(:update, %{status: :unsubscribed})
      |> Ash.update(authorize?: false)

    kinds = events_for(sub.id) |> Enum.map(& &1.event)
    assert kinds == [:granted, :withdrawn]

    # Latest-event-wins: the ledger is the source of truth over the mutable cache.
    assert {:ok, :withdrawn} = Consent.state_result(@event_resource, org.id, sub.id)
  end

  test "state_result/3 tells an UNREADABLE ledger from 'no consent on file' (a gate must not treat it as :none)" do
    org = mk_org("consent-state-result")

    {:ok, sub} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "sr@marketing.example",
        status: :active,
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    {:ok, _} =
      sub |> Ash.Changeset.for_update(:update, %{status: :unsubscribed}) |> Ash.update(authorize?: false)

    # POSITIVE CONTROL: a readable ledger answers, tagged
    assert {:ok, :withdrawn} = Consent.state_result(@event_resource, org.id, sub.id)
    assert {:ok, :none} = Consent.state_result(@event_resource, org.id, Ecto.UUID.generate())

    # RED: an unreadable ledger — the ledger table is really gone for a moment (renamed inside the sandbox transaction) — is an outage, not :none
    table = AshPostgres.DataLayer.Info.table(ConsentEvent)
    Demo.Repo.query!(~s(ALTER TABLE "#{table}" RENAME TO "#{table}_outage"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :unavailable} = Consent.state_result(@event_resource, org.id, sub.id)
        # the legacy shape keeps its documented fallback (and reports it)
        # (apply/3: the deprecated call is the thing under test)
        assert apply(Consent, :state, [@event_resource, org.id, sub.id]) == :none
      end)

    Demo.Repo.query!(~s(ALTER TABLE "#{table}_outage" RENAME TO "#{table}"))

    # the same call is a real answer again once the ledger is back
    assert {:ok, :withdrawn} = Consent.state_result(@event_resource, org.id, sub.id)

    assert log =~ "read=marketing_consent_state"
  end

  describe "a ledger that cannot be written" do
    # The ledger table is really gone (renamed inside the sandbox transaction).
    defp ledger_down! do
      table = AshPostgres.DataLayer.Info.table(ConsentEvent)
      Demo.Repo.query!(~s(ALTER TABLE "#{table}" RENAME TO "#{table}_outage"))
      fn -> Demo.Repo.query!(~s(ALTER TABLE "#{table}_outage" RENAME TO "#{table}")) end
    end

    defp active_subscriber!(org, email) do
      {:ok, sub} =
        Subscriber
        |> Ash.Changeset.for_create(:create, %{org_id: org.id, email: email, status: :active, consent_at: DateTime.utc_now()})
        |> Ash.create(authorize?: false)

      sub
    end

    test "RED: an unsubscribe is REFUSED (and rolled back) when its :withdrawn row cannot be written; healed, it lands" do
      org = mk_org("consent-withdraw-down")
      sub = active_subscriber!(org, "wd-down@marketing.example")
      heal = ledger_down!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} =
                   sub |> Ash.Changeset.for_update(:update, %{status: :unsubscribed}) |> Ash.update(authorize?: false)
        end)

      assert log =~ "read=consent_change_"
      heal.()

      # the opt-out did not commit without its ledger entry
      assert %{status: :active} = Ash.get!(Subscriber, sub.id, authorize?: false)
      assert {:ok, :granted} = Consent.state_result(@event_resource, org.id, sub.id)

      # POSITIVE CONTROL: the same update with the ledger readable lands, and is on the ledger
      assert {:ok, _} = sub |> Ash.Changeset.for_update(:update, %{status: :unsubscribed}) |> Ash.update(authorize?: false)
      assert {:ok, :withdrawn} = Consent.state_result(@event_resource, org.id, sub.id)
    end
  end

  describe "a withdrawal that the ledger layer rejects before the database (an unusable event resource)" do
    # Postgres already aborts a transaction whose ledger INSERT failed, so that case fails regardless of what
    # `ConsentChange` returns. This is the case it alone decides: the append raises before reaching the database.
    defp unsubscribe_with(sub, event_resource) do
      cs = Ash.Changeset.for_update(sub, :update, %{status: :unsubscribed})
      cs = Samen.Marketing.ConsentChange.change(cs, [event_resource: event_resource], %{})
      Ash.update(cs, authorize?: false)
    end

    test "RED: a :withdrawn append that cannot be built refuses the unsubscribe (nothing commits)" do
      org = mk_org("consent-withdraw-unusable")

      {:ok, sub} =
        Subscriber
        |> Ash.Changeset.for_create(:create, %{org_id: org.id, email: "wd-unusable@marketing.example", status: :active, consent_at: DateTime.utc_now()})
        |> Ash.create(authorize?: false)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = unsubscribe_with(sub, String) end)
      assert log =~ "read=consent_change_"
      assert %{status: :active} = Ash.get!(Subscriber, sub.id, authorize?: false)

      # POSITIVE CONTROL: with a usable event resource the same update lands
      assert {:ok, %{status: :unsubscribed}} = unsubscribe_with(sub, @event_resource)
    end
  end

  test "the ledger row carries NO plaintext PII (subject_hash is a one-way handle)" do
    org = mk_org("consent-nopii")
    email = "nopii@marketing.example"

    {:ok, sub} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: email,
        status: :active,
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    [event] = events_for(sub.id)
    refute event.subject_hash =~ email
    refute inspect(event) =~ email

    {:ok, %{columns: cols}} = Repo.query("SELECT * FROM mce_consent_event LIMIT 0")
    refute Enum.any?(cols, fn c -> c =~ "email" end)
  end

  # =========================================================================
  # RED — append-only immutability (sabotage 21 target)
  # =========================================================================

  test "the consent ledger exposes no update or destroy action (append-only immutability)" do
    action_types =
      ConsentEvent
      |> Ash.Resource.Info.actions()
      |> Enum.map(& &1.type)
      |> Enum.uniq()

    refute :update in action_types,
           "ConsentEvent must be append-only — a mutable update action breaks the ledger"

    refute :destroy in action_types,
           "ConsentEvent must be append-only — a destroy action breaks the ledger"

    # Only :read + the :append create are permitted.
    assert Enum.sort(action_types) == [:create, :read]
  end

  # =========================================================================
  # ERASURE-SURVIVAL — do-not-contact outlives the crypto-shred
  # =========================================================================

  test "a withdrawn verdict + subject_hash survive a subject crypto-shred" do
    org = mk_org("consent-erasure")

    {:ok, sub} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "erase@marketing.example",
        status: :active,
        consent_at: DateTime.utc_now()
      })
      |> Ash.create(authorize?: false)

    {:ok, _} =
      sub
      |> Ash.Changeset.for_update(:update, %{status: :unsubscribed})
      |> Ash.update(authorize?: false)

    before_hashes = events_for(sub.id) |> Enum.map(& &1.subject_hash)
    assert Enum.any?(before_hashes, &is_binary/1)

    # Crypto-shred the subscriber's PII.
    assert {:ok, _report} = Erasure.shred(sub.id, repo: Repo, actor_id: "test_consent_erasure")

    # The vaulted email is now unrecoverable...
    %{rows: vault_states} =
      Repo.query!("SELECT state FROM pii_vault WHERE subject_id = $1", [sub.id])

    assert Enum.any?(vault_states, fn [s] -> s == "shredded" end)

    # ...but the append-only ledger is untouched: rows persist byte-identical.
    after_rows =
      Repo.all(
        from(e in "mce_consent_event",
          where: e.mce_subscriber_id == type(^sub.id, :binary_id),
          select: e.mce_subject_hash
        )
      )
    assert after_rows != []
    assert Enum.sort(after_rows) == Enum.sort(before_hashes)

    # Do-not-contact is STILL honored after the PII is gone.
    assert {:ok, :withdrawn} = Consent.state_result(@event_resource, org.id, sub.id)
  end
end
