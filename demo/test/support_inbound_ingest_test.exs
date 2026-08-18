defmodule Demo.SupportInboundIngestTest do
  @moduledoc """
  DB-backed gate for the C5 inbound-email → ticket capability (T59), against the DEMO
  host's REAL mounted Support + CRM resources (the first-client wiring: the framework
  `Samen.Support.Inbound.Ingest` lives in samen_core; demo adopts it by handing a
  `Config` its own resource modules — ≈0 authored LOC). Proves the security-critical
  properties on real Postgres:

    * new-ticket + thread-onto-existing (same org)
    * CROSS-ORG threading REFUSED (2-org, sabotage-refutable positive control)
    * loop-prevention: each signal → no ticket + no auto-reply; a mail-loop is bounded
    * stored-XSS: script/onerror in subject/body/display-name inert at rest (T111)
    * sender PII + body vaulted and masked-per-plane (MaskingCase 3-proof)
    * malformed/oversized inbound handled (no crash)
    * attachment lands via the Files chokepoint as :quarantined
  """
  use Demo.DataCase, async: false
  use Samen.MaskingCase

  alias Demo.SupportScope.{Ticket, Conversation, Message}
  alias Demo.CrmScope.Person
  alias Demo.PrimitivesScope.File, as: DemoFile
  alias Demo.Identity.Org
  alias Samen.Delivery.InboundMessage
  alias Samen.Support.Inbound.{Config, Ingest}

  require Ash.Query

  # Operator-without-grant vault stub (mirrors docs_scope_test's DenyAll): the mask is
  # the plane/grant gate, independent of decrypt availability.
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # ---- helpers --------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} = Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)
    org.id
  end

  defp cfg(org_id, opts \\ []) do
    Config.new(
      Keyword.merge(
        [
          org_id: org_id,
          repo: Demo.Repo,
          ticket_resource: Ticket,
          conversation_resource: Conversation,
          message_resource: Message,
          contact_resource: Person,
          our_domains: ["support.demo.test"],
          our_addresses: ["support@demo.test"],
          inbound_localpart: "support"
        ],
        opts
      )
    )
  end

  defp inbound(fields) do
    struct!(%InboundMessage{provider: :fake, message_id: "in-#{System.unique_integer([:positive])}"}, fields)
  end

  defp ticket_count(org_id) do
    {:ok, n} = Ticket |> Ash.Query.filter(org_id == ^org_id) |> Ash.count(authorize?: false)
    n
  end

  defp message_count(org_id) do
    {:ok, n} = Message |> Ash.Query.filter(org_id == ^org_id) |> Ash.count(authorize?: false)
    n
  end

  # ==========================================================================
  # (a) new ticket + thread onto existing (correct org)
  # ==========================================================================

  test "a fresh inbound creates a ticket + conversation + vaulted contact + message" do
    org = mk_org("acme-a")

    {:ok, r} =
      Ingest.ingest(
        inbound(from: "Ada Lovelace <ada@customer.test>", subject: "Cannot log in", text_body: "Help please"),
        cfg(org)
      )

    assert r.disposition == :created
    assert r.ticket_id && r.conversation_id && r.message_id && r.contact_id
    assert ticket_count(org) == 1

    {:ok, ticket} = Ash.get(Ticket, r.ticket_id, authorize?: false)
    assert ticket.subject == "Cannot log in"
  end

  test "a reply carrying the ticket plus-address threads onto the SAME ticket (no new ticket)" do
    org = mk_org("acme-a")
    {:ok, first} = Ingest.ingest(inbound(subject: "Order issue", text_body: "First"), cfg(org))

    {:ok, second} =
      Ingest.ingest(
        inbound(
          to: ["support+ticket-#{first.ticket_id}@demo.test"],
          subject: "Re: Order issue",
          text_body: "Second"
        ),
        cfg(org)
      )

    assert second.disposition == :threaded
    assert second.ticket_id == first.ticket_id
    assert ticket_count(org) == 1
    assert message_count(org) == 2
  end

  # ==========================================================================
  # (b) CROSS-ORG threading REFUSED — the crux security property
  # ==========================================================================

  test "a forged reference at ANOTHER org's ticket does NOT thread — opens a new ticket in the correct org" do
    org_a = mk_org("org-a")
    org_b = mk_org("org-b")

    # org B has a real ticket.
    {:ok, b} = Ingest.ingest(inbound(subject: "B ticket", text_body: "B body"), cfg(org_b))
    b_messages_before = message_count(org_b)

    # An org-A inbound forges EVERY threading vector at org B's ticket id.
    forged = b.ticket_id

    {:ok, a} =
      Ingest.ingest(
        inbound(
          to: ["support+ticket-#{forged}@demo.test"],
          subject: "totally legit [ticket-#{forged}]",
          headers: %{
            "In-Reply-To" => "<ticket-#{forged}.x@demo.test>",
            "References" => "<ticket-#{forged}.x@demo.test>"
          },
          text_body: "cross-org injection attempt"
        ),
        cfg(org_a)
      )

    # It did NOT attach to org B's ticket …
    assert a.ticket_id != forged
    assert a.disposition == :created
    assert message_count(org_b) == b_messages_before
    # … it opened a NEW ticket in org A.
    assert ticket_count(org_a) == 1

    # POSITIVE CONTROL (sabotage-refutable): the SAME token scheme threads WITHIN org A.
    {:ok, a_thread} =
      Ingest.ingest(
        inbound(to: ["support+ticket-#{a.ticket_id}@demo.test"], subject: "Re", text_body: "reply"),
        cfg(org_a)
      )

    assert a_thread.disposition == :threaded
    assert a_thread.ticket_id == a.ticket_id
  end

  # ==========================================================================
  # (c) loop-prevention — each signal → no ticket, no auto-reply; bounded loop
  # ==========================================================================

  test "each loop signal suppresses: no ticket created, no auto-reply sent" do
    org = mk_org("loop-org")
    test_pid = self()
    recorder = fn ctx -> send(test_pid, {:auto_reply, ctx}) end

    loop_cases = [
      inbound(from: "x@customer.test", headers: %{"Auto-Submitted" => "auto-replied"}, text_body: "a"),
      inbound(from: "x@customer.test", headers: %{"Precedence" => "bulk"}, text_body: "b"),
      inbound(from: "x@customer.test", headers: %{"X-Auto-Response-Suppress" => "All"}, text_body: "c"),
      inbound(from: "mailer-daemon@customer.test", text_body: "d"),
      inbound(from: "robot@support.demo.test", text_body: "e")
    ]

    for msg <- loop_cases do
      {:ok, r} = Ingest.ingest(msg, cfg(org, auto_reply: recorder))
      assert r.disposition == :suppressed
    end

    assert ticket_count(org) == 0
    refute_received {:auto_reply, _}

    # CONTROL: genuine human mail DOES create a ticket and DOES auto-reply.
    {:ok, r} = Ingest.ingest(inbound(from: "human@customer.test", text_body: "real"), cfg(org, auto_reply: recorder))
    assert r.disposition == :created
    assert r.auto_reply == :sent
    assert_received {:auto_reply, %{ticket_id: _}}
  end

  test "a mail-loop between two autoresponders is bounded (no infinite tickets)" do
    org = mk_org("mailloop-org")

    for _ <- 1..8 do
      {:ok, r} =
        Ingest.ingest(inbound(from: "auto@other.test", headers: %{"Auto-Submitted" => "auto-generated"}), cfg(org))

      assert r.disposition == :suppressed
    end

    assert ticket_count(org) == 0
  end

  test "runaway bound caps inbound per thread" do
    org = mk_org("cap-org")
    {:ok, t} = Ingest.ingest(inbound(subject: "cap", text_body: "1"), cfg(org, max_inbound_per_thread: 2))

    thread = fn n ->
      Ingest.ingest(
        inbound(to: ["support+ticket-#{t.ticket_id}@demo.test"], text_body: n),
        cfg(org, max_inbound_per_thread: 2)
      )
    end

    {:ok, _} = thread.("2")
    {:ok, capped} = thread.("3")
    assert capped.disposition == :rate_capped
    assert message_count(org) == 2
  end

  # ==========================================================================
  # (d) stored-XSS — script/onerror inert at rest (T111 lineage), refutable
  # ==========================================================================

  test "script/onerror in subject, body, and display-name are inert at rest" do
    org = mk_org("xss-org")
    xss_subject = "<script>alert('subj')</script>Hi"
    xss_body = "<img src=x onerror=\"alert(1)\">click"
    xss_name = "<script>steal()</script>Mallory"

    {:ok, r} =
      Ingest.ingest(
        inbound(from: "mallory@evil.test", from_name: xss_name, subject: xss_subject, text_body: xss_body),
        cfg(org)
      )

    # ticket.subject is stored sanitized (raw SQL — the at-rest column has no live tag).
    %{rows: [[stored_subject]]} =
      Demo.Repo.query!("SELECT stk_subject FROM stk_ticket WHERE stk_id = $1", [Ecto.UUID.dump!(r.ticket_id)])

    refute stored_subject =~ "<script"
    assert stored_subject =~ "Hi"

    # SABOTAGE twin: the raw input DID carry the live tag — the scan is refutable.
    assert xss_subject =~ "<script"

    # contact display_name stored sanitized.
    {:ok, person} = Ash.get(Person, r.contact_id, authorize?: false)
    refute person.display_name =~ "<script"
    assert person.display_name =~ "Mallory"

    # message body, revealed on the tenant plane, carries no live tag/handler.
    body = resolve_on_plane(load_msg(r.message_id), Message, :tenant, repo: Demo.Repo).body
    refute body =~ "<img"
    refute body =~ "onerror"
    assert body =~ "click"
  end

  # ==========================================================================
  # (e) PII vaulted + masked — MaskingCase 3-proof on body AND sender email
  # ==========================================================================

  test "message body: tenant clear ∧ operator masked ∧ vt_ token at rest (3-proof)" do
    org = mk_org("pii-org")
    {:ok, r} = Ingest.ingest(inbound(subject: "s", text_body: "SENTINEL-BODY hello"), cfg(org))
    msg = load_msg(r.message_id)

    # GREEN — tenant resolves clear.
    tenant = resolve_on_plane(msg, Message, :tenant, repo: Demo.Repo).body
    assert_plane_clear!(tenant, "SENTINEL-BODY hello")

    # RED — operator-without-grant masks.
    operator = resolve_on_plane(msg, Message, :operator, repo: Demo.Repo, grant: DenyAll).body
    assert_plane_masked!(operator, "SENTINEL-BODY hello")

    # SABOTAGE twin — the tenant render leaks the sentinel (proving the operator refute is refutable).
    assert_leak_detected!(to_string(tenant), "SENTINEL-BODY")

    # at rest: a vt_ token, never the plaintext.
    %{rows: [[raw]]} =
      Demo.Repo.query!("SELECT pii_smg_body FROM smg_message WHERE smg_id = $1", [Ecto.UUID.dump!(r.message_id)])

    assert String.starts_with?(raw, "vt_")
    refute raw =~ "SENTINEL-BODY"
  end

  test "sender email is vaulted (masked by default) and carries no plaintext at rest" do
    org = mk_org("pii-org2")
    {:ok, r} = Ingest.ingest(inbound(from: "Vault Me <vaultme@customer.test>", text_body: "x"), cfg(org))

    # masked-by-default when the vault composite is loaded (the default posture).
    person = Ash.get!(Person, r.contact_id, load: [:emails], authorize?: false)
    assert match?(%Samen.Masked{}, person.emails)

    # no plaintext address anywhere in the row (vault at rest).
    %{rows: [row]} = Demo.Repo.query!("SELECT * FROM per_person WHERE per_id = $1", [Ecto.UUID.dump!(r.contact_id)])
    refute inspect(row) =~ "vaultme@customer.test"
  end

  # ==========================================================================
  # (f) malformed / oversized inbound handled (no crash)
  # ==========================================================================

  test "a malformed / oversized inbound does not crash and still records honestly" do
    org = mk_org("malformed-org")

    malformed = %InboundMessage{
      provider: :fake,
      message_id: nil,
      from: nil,
      from_name: 999,
      to: :nope,
      subject: nil,
      text_body: nil,
      html_body: %{bad: true},
      headers: "not a map",
      attachments: nil
    }

    assert {:ok, %{disposition: :created}} = Ingest.ingest(malformed, cfg(org))

    oversized = inbound(subject: String.duplicate("Z", 1_000_000), text_body: String.duplicate("Y", 3_000_000))
    assert {:ok, %{disposition: :created}} = Ingest.ingest(oversized, cfg(org, max_body_bytes: 500, max_subject_bytes: 80))
  end

  # ==========================================================================
  # (g/attachments) attachment lands via the chokepoint as :quarantined
  # ==========================================================================

  test "an inbound attachment lands via Files.upload as :quarantined, key on the message" do
    org = mk_org("attach-org")

    {:ok, r} =
      Ingest.ingest(
        inbound(
          subject: "with file",
          text_body: "see attached",
          attachments: [%{"Name" => "report.txt", "ContentType" => "text/plain", "Content" => Base.encode64("hello")}]
        ),
        cfg(org,
          file_module: DemoFile,
          file_upload_opts: [
            scanner: Samen.Files.Scanner.Noop,
            max_bytes: 26_214_400,
            allowed_content_types: ~w(application/pdf image/png image/jpeg text/plain text/csv)
          ]
        )
      )

    msg = load(Message, r.message_id)
    assert [key] = msg.attachments
    assert is_binary(key)

    {:ok, [file]} =
      DemoFile |> Ash.Query.filter(storage_key == ^key) |> Ash.read(authorize?: false)

    assert file.status == :quarantined
  end

  defp load(resource, id), do: Ash.get!(resource, id, authorize?: false)
  defp load_msg(id), do: Ash.get!(Message, id, load: [:body], authorize?: false)
end
