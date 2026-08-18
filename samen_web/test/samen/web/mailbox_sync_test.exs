defmodule Samen.Web.MailboxSyncTest do
  @moduledoc """
  T74 (spec §I1) — THE FULL TWO-WAY LOOP, proved end to end against real Postgres with
  the keyless `Samen.Mailbox.FakeProvider`.

  What is proved here:

    * **Inbound threads onto the RIGHT Person** — matched by the person's VAULTED
      `emails` (there is no plaintext email column to query), asserted via granted
      resolution on both sides: the matcher resolves through
      `Samen.Api.PiiResolution`, and the test independently resolves the matched
      person to show the address it matched really is that person's.
    * **…and onto the right COMPANY** — through the person's `company_id`, so the
      same message shows on both timelines (zero timeline loss).
    * **Outbound is recorded too** (the second leg): a send through the SAME provider
      lands on the SAME person's timeline as `direction: :outbound`.
    * **Matching is REFUTABLE** — a message from an unknown address is recorded but
      anchored to NOTHING. Without this the "it threaded correctly" assertions would
      be vacuous (everything would stick to the first person).
    * **Idempotent** — re-syncing the same page records nothing twice.
    * **Fail-honest** — an unconfigured provider writes NOTHING and returns
      `{:error, :not_configured}`, never an empty success.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Mailbox
  alias Samen.Mailbox.{Config, FakeProvider, Message}
  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount
  alias Samen.WebTest.Mailbox.MailMessage

  @inbound_body "MBX-INBOUND-SENTINEL can you re-quote the Chicago lane?"
  @inbound_subject "MBX-SUBJECT-SENTINEL Re: Chicago lane"
  @outbound_body "MBX-OUTBOUND-SENTINEL sending the revised quote now."
  @stranger "MBX-STRANGER@nowhere.invalid"

  setup do
    FakeProvider.reset()
    FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
    on_exit(fn -> FakeProvider.reset() end)

    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, person: seeded.crm.person, company: seeded.crm.company}
  end

  defp config(org_id, provider_config \\ %{configured: true}) do
    %Config{
      org_id: org_id,
      repo: Samen.WebTest.Repo,
      provider: FakeProvider,
      provider_config: provider_config,
      connection_resource: Samen.WebTest.Mailbox.Connection,
      message_resource: MailMessage,
      person_resource: Samen.WebTest.Crm.Person,
      company_resource: Samen.WebTest.Crm.Company
    }
  end

  defp connect!(_org_id, cfg) do
    {:ok, connection} =
      Mailbox.connect(%{user_id: Ash.UUID.generate(), address: "rep@ourco.test"}, cfg)

    assert connection.status == :connected
    connection
  end

  defp inbound(address, opts \\ []) do
    %Message{
      direction: :inbound,
      external_id: Keyword.get(opts, :external_id, "ext-#{System.unique_integer([:positive])}"),
      thread_id: "thr-1",
      from_address: address,
      to_addresses: ["rep@ourco.test"],
      subject: Keyword.get(opts, :subject, @inbound_subject),
      body: Keyword.get(opts, :body, @inbound_body),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp mail_rows(org_id) do
    MailMessage
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.ensure_selected([:subject, :body, :counterparty_address])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp tenant_scope(org_id) do
    Mount.scope(
      Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant()),
      org_id
    )
  end

  defp crm_mount, do: Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo, plane: Samen.Web.Plane.tenant())

  # --- cross-org fixtures (MED-1) --------------------------------------------

  defp seed_company!(org_id, name, domain) do
    Samen.WebTest.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, domain: domain},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_person!(org_id, address, company) do
    Samen.WebTest.Crm.Person
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        company_id: company && company.id,
        display_name: "Foreign Contact",
        full_name: %Samen.Type.FullName{first: "Foreign", last: "Contact"},
        emails: [%{label: "work", address: address}]
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # ==========================================================================
  # 1 — inbound threads onto the correct Person AND Company (matched by vaulted address)
  # ==========================================================================

  test "INBOUND: a synced message threads onto the person whose VAULTED email matches, and onto that person's company",
       %{org_id: org_id, person: person, company: company} do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email())])

    assert {:ok, %{synced: 1, skipped: 0}} = Mailbox.sync(connection, cfg)

    [row] = mail_rows(org_id)
    assert row.direction == :inbound
    # THE anchor assertion: this message is on THIS person's timeline, not any other.
    assert row.subject_key == "crm.person"
    assert row.subject_id == person.id
    # …and on that person's company timeline too (secondary anchor).
    assert row.company_id == company.id
    assert row.connection_id == connection.id

    # Assert the MATCH via granted resolution: the person we threaded onto really is
    # the one holding that (vaulted) address — resolved through PiiResolution, never
    # by reading the vault or a plaintext column (there is none).
    matched =
      Samen.WebTest.Crm.Person
      |> Ash.Query.filter(id == ^person.id)
      |> Ash.Query.ensure_selected([:emails])
      |> Ash.read_one!(authorize?: false)
      |> resolve_on_plane(Samen.WebTest.Crm.Person, :tenant, repo: Samen.WebTest.Repo)

    refute match?(%Samen.Masked{}, matched.emails)
    assert to_string(matched.emails) =~ Seeds.contact_email()

    # The same message reaches BOTH framework timeline reads.
    assert [read_person] = Reads.mail_for_person(crm_mount(), tenant_scope(org_id), person.id)
    assert read_person.id == row.id
    assert [read_company] = Reads.mail_for_company(crm_mount(), tenant_scope(org_id), company.id)
    assert read_company.id == row.id
  end

  test "REFUTABLE: a message from an UNKNOWN address is recorded but anchored to NOTHING",
       %{org_id: org_id, person: person, company: company} do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    FakeProvider.deliver_to_inbox([inbound(@stranger)])
    assert {:ok, %{synced: 1}} = Mailbox.sync(connection, cfg)

    [row] = mail_rows(org_id)
    assert row.subject_key == nil
    assert row.subject_id == nil
    assert row.company_id == nil

    # …and it does NOT appear on the seeded person's / company's timeline.
    assert Reads.mail_for_person(crm_mount(), tenant_scope(org_id), person.id) == []
    assert Reads.mail_for_company(crm_mount(), tenant_scope(org_id), company.id) == []
  end

  test "CROSS-ORG: the match is ORG-PINNED — a foreign org's person/company with the SAME vaulted address never anchors",
       %{org_id: org_a, person: person_a, company: company_a} do
    # Org B holds a person with the EXACT SAME vaulted address as org A's contact, at a
    # company with a distinctive domain. Nothing about org B may ever reach org A's sync,
    # and — the load-bearing half — nothing about org A or B may reach a THIRD, bare org.
    org_b = Ash.UUID.generate()
    company_b = seed_company!(org_b, "Foreign Freight GmbH", "foreign-b.invalid")
    person_b = seed_person!(org_b, Seeds.contact_email(), company_b)

    org_c = Ash.UUID.generate()

    # --- org A syncs: anchors to ITS OWN person/company, never org B's ---
    cfg_a = config(org_a)
    connection_a = connect!(org_a, cfg_a)
    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email(), external_id: "ext-org-a")])
    assert {:ok, %{synced: 1}} = Mailbox.sync(connection_a, cfg_a)

    [row_a] = mail_rows(org_a)
    assert row_a.subject_id == person_a.id
    refute row_a.subject_id == person_b.id
    assert row_a.company_id == company_a.id
    refute row_a.company_id == company_b.id

    # Org B's own timeline stays empty — org A's mail is not on it.
    assert Reads.mail_for_person(crm_mount(), tenant_scope(org_b), person_b.id) == []
    assert Reads.mail_for_company(crm_mount(), tenant_scope(org_b), company_b.id) == []
    # …and org B's scope cannot read org A's message even by naming A's person id
    # (the read is org-scoped by policy, not merely by the anchor id).
    assert Reads.mail_for_person(crm_mount(), tenant_scope(org_b), person_a.id) == []

    # --- THE PIN: a BARE org syncing the SAME address anchors to NOTHING ---
    # Without the org filter in Match.candidate_people/1 this would silently anchor to
    # org A's or org B's person — a cross-tenant leak that ships green.
    FakeProvider.reset()
    FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
    cfg_c = config(org_c)
    connection_c = connect!(org_c, cfg_c)
    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email(), external_id: "ext-org-c")])
    assert {:ok, %{synced: 1}} = Mailbox.sync(connection_c, cfg_c)

    [row_c] = mail_rows(org_c)
    assert row_c.subject_key == nil
    assert row_c.subject_id == nil
    assert row_c.company_id == nil

    # --- THE PIN, company-domain half: a foreign org's DOMAIN must not anchor either ---
    FakeProvider.deliver_to_inbox([
      inbound("someone@foreign-b.invalid", external_id: "ext-org-c-domain")
    ])

    assert {:ok, %{synced: 1}} = Mailbox.sync(connection_c, cfg_c)
    domain_row = mail_rows(org_c) |> Enum.find(&(&1.external_id == "ext-org-c-domain"))
    assert domain_row.company_id == nil
    assert domain_row.subject_key == nil
  end

  # P1 (phase6-punchlist) — `Samen.Mailbox.Match.company_for/3` is PUBLIC. The Sync
  # path only ever hands it an already-org-filtered person, so the org conjunct in
  # `company_by_id/2` is an equivalent-on-Sync-path mutant there. A HOST calling the
  # public entry directly with a raw, foreign-org `%{company_id: ...}` struct is the
  # unguarded path — pin it directly, with a positive control so the nil is the org
  # pin (not a broken function that never resolves any company_id).
  test "P1 PUBLIC company_for/3 is ORG-PINNED on the raw-struct path: a foreign-org company_id NEVER resolves cross-org",
       %{org_id: org_a, company: company_a} do
    org_b = Ash.UUID.generate()
    company_b = seed_company!(org_b, "Foreign Freight GmbH", "p1-foreign-b.invalid")

    cfg_a = config(org_a)
    # An address that domain-matches NEITHER company, so the result is decided purely
    # by the by-id path (company_by_domain/2 would otherwise mask the org pin).
    address = "p1-stranger@p1-nowhere.invalid"

    # THE PIN: a raw foreign-org person struct's company_id must not cross into org A.
    assert Samen.Mailbox.Match.company_for(%{company_id: company_b.id}, address, cfg_a) == nil

    # POSITIVE CONTROL (anti-tautology): org A's OWN company_id DOES resolve by-id,
    # proving the nil above is the org boundary, not a dead code path.
    resolved = Samen.Mailbox.Match.company_for(%{company_id: company_a.id}, address, cfg_a)
    assert resolved != nil
    assert resolved.id == company_a.id
  end

  # M2 (phase6-edges F2) — `Samen.Mailbox.Match` must FAIL-CLOSED on ambiguity, mirroring
  # the T160 `Samen.CRM.AccountLink` discipline: exactly ONE candidate matches; zero OR
  # two-or-more resolve to honest absence (nil), never an arbitrary-first guess. A vaulted
  # mail body must never be threaded onto a plausibly-wrong contact/company.
  test "M2 PERSON ambiguity: TWO org people sharing a counterparty address ⇒ no-match (never arbitrary first)",
       %{org_id: org_id} do
    shared = "m2-shared-addr@dup-contact.invalid"
    _p1 = seed_person!(org_id, shared, nil)
    _p2 = seed_person!(org_id, shared, nil)

    cfg = config(org_id)

    # THE PIN: 2+ candidates on the SAME address ⇒ honest absence, not the first person.
    assert Samen.Mailbox.Match.person_for_address(shared, cfg) == nil
  end

  test "M2 PERSON positive control: EXACTLY ONE person on an address ⇒ that person matches (anti-tautology)",
       %{org_id: org_id} do
    unique = "m2-unique-addr@one-contact.invalid"
    person = seed_person!(org_id, unique, nil)

    cfg = config(org_id)

    matched = Samen.Mailbox.Match.person_for_address(unique, cfg)
    assert matched != nil
    assert matched.id == person.id
  end

  test "M2 COMPANY-DOMAIN ambiguity: TWO org companies sharing a domain ⇒ no-match (never arbitrary first)",
       %{org_id: org_id} do
    _c1 = seed_company!(org_id, "Dup Freight One", "m2-dup-domain.invalid")
    _c2 = seed_company!(org_id, "Dup Freight Two", "m2-dup-domain.invalid")

    cfg = config(org_id)
    # `company_id: nil` ⇒ the by-id leg is skipped and resolution goes to the DOMAIN
    # fallback, where the 2+ ambiguity lives.
    address = "someone@m2-dup-domain.invalid"

    # THE PIN: 2+ companies on the same domain ⇒ honest absence, not the first company.
    assert Samen.Mailbox.Match.company_for(%{company_id: nil}, address, cfg) == nil
  end

  test "M2 COMPANY-DOMAIN positive control: EXACTLY ONE company on a domain ⇒ that company matches",
       %{org_id: org_id} do
    company = seed_company!(org_id, "Solo Freight", "m2-solo-domain.invalid")

    cfg = config(org_id)
    address = "someone@m2-solo-domain.invalid"

    matched = Samen.Mailbox.Match.company_for(%{company_id: nil}, address, cfg)
    assert matched != nil
    assert matched.id == company.id
  end

  test "matching is address-NORMALIZED (case/whitespace), not string-identical", %{
    org_id: org_id,
    person: person
  } do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    shouty = "  " <> String.upcase(Seeds.contact_email()) <> " "
    FakeProvider.deliver_to_inbox([inbound(shouty)])
    assert {:ok, %{synced: 1}} = Mailbox.sync(connection, cfg)

    [row] = mail_rows(org_id)
    assert row.subject_id == person.id
  end

  # ==========================================================================
  # 2 — the OUTBOUND leg (two-way)
  # ==========================================================================

  test "OUTBOUND: a send is recorded on the SAME person timeline as direction :outbound", %{
    org_id: org_id,
    person: person,
    company: company
  } do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    assert {:ok, sent} =
             Mailbox.send(
               %{to: Seeds.contact_email(), subject: "Revised quote", body: @outbound_body},
               connection,
               cfg
             )

    assert sent.direction == :outbound
    assert sent.subject_key == "crm.person"
    assert sent.subject_id == person.id
    assert sent.company_id == company.id
    # The provider really dispatched it (the fake's outbox is the receipt log).
    assert [%Message{direction: :outbound}] = FakeProvider.sent()

    # Both legs land on ONE timeline — that is what "two-way" means for the CRM.
    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email())])
    assert {:ok, %{synced: _}} = Mailbox.sync(connection, cfg)

    directions =
      crm_mount()
      |> Reads.mail_for_person(tenant_scope(org_id), person.id)
      |> Enum.map(& &1.direction)
      |> Enum.sort()

    assert directions == [:inbound, :outbound]
  end

  test "a send that the provider ALSO returns from its Sent folder is not double-recorded", %{
    org_id: org_id,
    person: person
  } do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    {:ok, _} = Mailbox.send(%{to: Seeds.contact_email(), body: @outbound_body}, connection, cfg)
    # The fake mirrors a real Sent folder: the next fetch returns the same message.
    assert {:ok, %{synced: 0, skipped: 1}} = Mailbox.sync(connection, cfg)

    assert length(Reads.mail_for_person(crm_mount(), tenant_scope(org_id), person.id)) == 1
  end

  # ==========================================================================
  # 3 — vaulting + idempotency + fail-honest
  # ==========================================================================

  test "bodies/subjects/addresses are VAULTED at rest (pii_body / pii_email), never plaintext", %{
    org_id: org_id
  } do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email())])
    {:ok, _} = Mailbox.sync(connection, cfg)

    %{rows: [[subject_col, body_col, addr_col]]} =
      Ecto.Adapters.SQL.query!(
        Samen.WebTest.Repo,
        "select pii_wmm_subject, pii_wmm_body, pii_wmm_counterparty_address from wmm_mail_message",
        []
      )

    for col <- [subject_col, body_col, addr_col] do
      assert is_binary(col)
      assert String.starts_with?(col, "vt_")
    end

    refute body_col =~ "MBX-INBOUND-SENTINEL"
    refute subject_col =~ "MBX-SUBJECT-SENTINEL"
    refute addr_col =~ Seeds.contact_email()

    # …and the connection's own mailbox address is vaulted the same way.
    %{rows: [[connection_addr]]} =
      Ecto.Adapters.SQL.query!(Samen.WebTest.Repo, "select pii_mwc_address from mwc_connection", [])

    assert String.starts_with?(connection_addr, "vt_")
    refute connection_addr =~ "rep@ourco.test"

    # POSITIVE CONTROL: the tenant plane resolves the SAME row back to plaintext, so
    # the "no plaintext at rest" assertion is not passing because nothing was stored.
    [row] = mail_rows(org_id)
    resolved = resolve_on_plane(row, MailMessage, :tenant, repo: Samen.WebTest.Repo)
    assert_plane_clear!(resolved.body, @inbound_body)
    assert_plane_clear!(resolved.counterparty_address, Seeds.contact_email())
  end

  test "re-syncing the same page is IDEMPOTENT (deduped on the provider's external id)", %{
    org_id: org_id
  } do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email(), external_id: "ext-fixed")])
    assert {:ok, %{synced: 1, skipped: 0}} = Mailbox.sync(connection, cfg)

    # A provider that replays the page (cursor reset / at-least-once push) must not
    # double-post a conversation onto a customer's timeline.
    reset = %{connection | cursor: nil}
    assert {:ok, %{synced: 0, skipped: 1}} = Mailbox.sync(reset, cfg)
    assert length(mail_rows(org_id)) == 1
  end

  test "FAIL-CLOSED: an unavailable dedupe LOOKUP aborts the batch instead of re-posting", %{
    org_id: org_id
  } do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)
    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email(), external_id: "ext-dedupe")])

    # A message_resource the dedupe query cannot read models the transient DB failure.
    # "I could not check" must NEVER be treated as "not a duplicate" — that would
    # re-post a customer-visible conversation onto a CRM timeline on every blip.
    broken = %{cfg | message_resource: NoSuchMailMessageResource}
    result = Mailbox.sync(connection, broken)

    assert {:error, {:dedupe_unavailable, _}} = result
    refute match?({:ok, _}, result)
    assert mail_rows(org_id) == []

    # …and the cursor was NOT advanced, so the SAME page still syncs once it recovers
    # (POSITIVE CONTROL: the abort loses nothing but the round).
    assert {:ok, %{synced: 1, skipped: 0, failed: 0}} = Mailbox.sync(connection, cfg)
    assert length(mail_rows(org_id)) == 1
  end

  test "FAIL-HONEST: an unconfigured provider writes NOTHING and never reports an empty success",
       %{org_id: org_id} do
    unconfigured = config(org_id, %{})

    assert {:error, :not_configured} =
             Mailbox.connect(%{user_id: Ash.UUID.generate(), address: "rep@ourco.test"}, unconfigured)

    # Use a genuinely-connected row so the refusal cannot be blamed on a missing one.
    connection = connect!(org_id, config(org_id))
    FakeProvider.deliver_to_inbox([inbound(Seeds.contact_email())])

    assert {:error, :not_configured} = Mailbox.sync(connection, unconfigured)
    assert {:error, :not_configured} = Mailbox.send(%{to: "x@y.test"}, connection, unconfigured)
    assert mail_rows(org_id) == []

    # POSITIVE CONTROL: the SAME call with a configured provider does the work.
    assert {:ok, %{synced: 1}} = Mailbox.sync(connection, config(org_id))
    assert length(mail_rows(org_id)) == 1
  end

  test "the sync is BOUNDED: a page larger than max_messages_per_sync is capped, not swallowed",
       %{org_id: org_id} do
    cfg = %{config(org_id) | max_messages_per_sync: 2}
    connection = connect!(org_id, cfg)

    FakeProvider.deliver_to_inbox(Enum.map(1..5, fn i -> inbound(Seeds.contact_email(), external_id: "ext-#{i}") end))

    assert {:ok, %{synced: 2}} = Mailbox.sync(connection, cfg)
    assert length(mail_rows(org_id)) == 2
  end

  # ==========================================================================
  # L9 (Phase-6 EDGE-LOW, documented) — a halt+retry re-dups ONLY the
  # external_id:nil subset; a REAL message (provider-carried id) never dups.
  # ==========================================================================

  test "L9: across a dedupe-halt retry, a REAL (id-bearing) message never duplicates -- only the external_id:nil subset re-posts (documented, not a lie)",
       %{org_id: org_id} do
    cfg = config(org_id)
    connection = connect!(org_id, cfg)

    FakeProvider.deliver_to_inbox([
      inbound(Seeds.contact_email(), external_id: "ext-l9-real"),
      inbound(Seeds.contact_email(), external_id: nil)
    ])

    # The SAME fail-closed halt mechanism as the "FAIL-CLOSED" test above: the
    # dedupe LOOKUP itself cannot run (models a transient DB blip), so the
    # batch aborts before writing anything and the cursor is NOT advanced.
    broken = %{cfg | message_resource: NoSuchMailMessageResource}
    assert {:error, {:dedupe_unavailable, _}} = Mailbox.sync(connection, broken)
    assert mail_rows(org_id) == []

    # Recovery: the exact same page re-fetches (per sync.ex's own moduledoc,
    # "the next sync re-reads the same page") and this time the lookup works
    # -- the FIRST genuine write for both messages.
    assert {:ok, %{synced: 2, skipped: 0}} = Mailbox.sync(connection, cfg)
    assert length(mail_rows(org_id)) == 2

    # Now model the SAME recovery path firing a SECOND time over a page that
    # was ALREADY (successfully) processed once -- a provider re-delivering,
    # or a cursor write that itself failed to persist forward, lands the
    # caller back at "re-read the same page" exactly as the halt above does.
    replayed = %{connection | cursor: nil}
    assert {:ok, %{synced: 1, skipped: 1}} = Mailbox.sync(replayed, cfg)

    rows = mail_rows(org_id)
    assert length(rows) == 3
    by_ext_id = Enum.group_by(rows, & &1.external_id)

    # THE GUARANTEE THAT MATTERS: a message carrying the provider's own
    # immutable external_id NEVER duplicates on a customer-visible timeline,
    # across ANY halt+retry cycle.
    assert length(Map.fetch!(by_ext_id, "ext-l9-real")) == 1

    # THE DOCUMENTED, ACCEPTED GAP: `duplicate?/2` (sync.ex) cannot dedupe an
    # external_id:nil message -- "a message with no external id cannot be
    # deduped — it is recorded (never silently dropped)". This is a
    # fake/degenerate-provider case only; every real IMAP/Gmail/Graph message
    # carries a stable id, so a REAL sync never hits this subset. It fails
    # toward a harmless duplicate row, never a lie (never a fabricated
    # success, never a silently dropped message) -- the fail-closed
    # dedupe-unavailable halt itself (proved above and by the FAIL-CLOSED
    # test) is unaffected: it still aborts on a genuine lookup failure
    # regardless of whether this page's messages carry ids.
    assert length(Map.fetch!(by_ext_id, nil)) == 2
  end
end
