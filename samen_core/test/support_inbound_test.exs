defmodule Samen.Support.InboundTest do
  @moduledoc """
  Pure-logic gate for the C5 inbound-email capability (T59) — the parts that need no
  mounted resources: untrusted-input parse hardening, loop-signal classification,
  stored-XSS sanitization, org-scoped threading TOKEN extraction, and the fail-honest
  adapter seam. The DB-backed security properties (cross-org threading refusal, PII
  vault+mask 3-proof, attachment chokepoint) live in the demo host suite
  (`demo/test/support_inbound_ingest_test.exs`) against real mounted resources.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.{FakeProvider, InboundMessage}
  alias Samen.Support.Inbound.{Config, LoopGuard, Parse, Sanitize, Threading}

  @tid "11111111-1111-4111-8111-111111111111"

  defp config(opts \\ []) do
    Config.new(
      Keyword.merge(
        [
          org_id: "org-a",
          repo: :fake_repo,
          ticket_resource: :ticket,
          conversation_resource: :conversation,
          message_resource: :message,
          our_domains: ["support.acme.test"],
          our_addresses: ["support@acme.test"],
          inbound_localpart: "support"
        ],
        opts
      )
    )
  end

  defp inbound(fields) do
    struct!(
      %InboundMessage{provider: :fake, message_id: "m-1"},
      fields
    )
  end

  # ==========================================================================
  # Parse — untrusted input never crashes; fields are bounded
  # ==========================================================================

  describe "Parse.normalize/2 (untrusted-input hardening)" do
    test "malformed / missing / wrong-typed fields do not crash" do
      msg = %InboundMessage{
        provider: :fake,
        message_id: nil,
        from: nil,
        from_name: 12_345,
        to: :not_a_list,
        subject: nil,
        text_body: nil,
        html_body: %{unexpected: true},
        headers: "not a map",
        attachments: nil
      }

      parsed = Parse.normalize(msg, config())
      assert parsed.to == []
      assert parsed.headers == %{}
      assert parsed.references == []
      assert is_nil(parsed.subject)
    end

    test "oversized subject and body are truncated to the caps (no unbounded copy)" do
      huge = String.duplicate("A", 2_000_000)
      msg = inbound(subject: huge, text_body: huge)
      cfg = config(max_subject_bytes: 100, max_body_bytes: 1_000)
      parsed = Parse.normalize(msg, cfg)

      assert byte_size(parsed.subject) <= 100
      assert byte_size(parsed.text_body) <= 1_000
    end

    test "extracts a bare address + display from `Name <addr>` and downcases the addr" do
      msg = inbound(from: "Ada Lovelace <Ada@Example.TEST>", from_name: nil)
      parsed = Parse.normalize(msg, config())
      assert parsed.from_address == "ada@example.test"
      assert parsed.from_display == "Ada Lovelace"
    end

    test "parses In-Reply-To and References into bounded message-id lists" do
      headers = %{
        "In-Reply-To" => "<ticket-#{@tid}.abc@acme.test>",
        "References" => "<x@a> <ticket-#{@tid}.abc@acme.test> <y@b>"
      }

      parsed = Parse.normalize(inbound(headers: headers), config())
      assert parsed.in_reply_to == "ticket-#{@tid}.abc@acme.test"
      assert length(parsed.references) == 3
    end
  end

  # ==========================================================================
  # Sanitize — stored-XSS defense (T111 lineage), sabotage-refutable
  # ==========================================================================

  describe "Sanitize.plain_text/1 (stored-XSS)" do
    test "a <script> payload is inert at rest" do
      out = Sanitize.plain_text("<script>alert('pwn')</script>Hello")
      refute out =~ "<script"
      refute out =~ "</script>"
      assert out =~ "Hello"
    end

    test "an <img onerror=...> payload is inert at rest" do
      out = Sanitize.plain_text("<img src=x onerror=\"alert1\">caption")
      refute out =~ "<img"
      refute out =~ "onerror"
      assert out =~ "caption"
    end

    test "residual angle brackets are entity-escaped (cannot re-open a tag)" do
      out = Sanitize.plain_text("2 < 3 and 4 > 1")
      refute out =~ ~r/<[a-z]/i
      assert out =~ "&lt;"
      assert out =~ "&gt;"
    end

    test "SABOTAGE twin: the raw payload DOES carry the live tag (scan is refutable)" do
      raw = "<script>alert(1)</script>"
      # The refute above would be vacuous if nothing ever contained '<script>'; the raw
      # input proves the scan can fail — the sanitizer is what makes it pass.
      assert raw =~ "<script"
      refute Sanitize.plain_text(raw) =~ "<script"
    end

    test "nil passes through" do
      assert Sanitize.plain_text(nil) == nil
    end
  end

  # ==========================================================================
  # LoopGuard — every loop signal suppresses; genuine mail delivers
  # ==========================================================================

  describe "LoopGuard.classify/2 (each signal + control)" do
    test "genuine human mail delivers" do
      parsed = Parse.normalize(inbound(from: "human@customer.test", headers: %{}), config())
      assert LoopGuard.classify(parsed, config()) == :deliver
    end

    test "Auto-Submitted: auto-replied suppresses" do
      parsed = Parse.normalize(inbound(headers: %{"Auto-Submitted" => "auto-replied"}), config())
      assert {:suppress, :auto_submitted} = LoopGuard.classify(parsed, config())
    end

    test "Auto-Submitted: no still delivers (control)" do
      parsed = Parse.normalize(inbound(from: "human@customer.test", headers: %{"Auto-Submitted" => "no"}), config())
      assert LoopGuard.classify(parsed, config()) == :deliver
    end

    test "Precedence: bulk suppresses" do
      parsed = Parse.normalize(inbound(headers: %{"Precedence" => "bulk"}), config())
      assert {:suppress, :precedence_bulk} = LoopGuard.classify(parsed, config())
    end

    test "X-Auto-Response-Suppress suppresses" do
      parsed = Parse.normalize(inbound(headers: %{"X-Auto-Response-Suppress" => "All"}), config())
      assert {:suppress, :auto_response_suppress} = LoopGuard.classify(parsed, config())
    end

    test "a mailer-daemon / postmaster / noreply sender suppresses" do
      for local <- ["mailer-daemon", "postmaster", "noreply", "no-reply", "bounces"] do
        parsed = Parse.normalize(inbound(from: "#{local}@somewhere.test"), config())
        assert {:suppress, :system_sender} = LoopGuard.classify(parsed, config())
      end
    end

    test "our OWN sending domain/address suppresses (reflexive loop)" do
      by_domain = Parse.normalize(inbound(from: "anything@support.acme.test"), config())
      assert {:suppress, :own_identity} = LoopGuard.classify(by_domain, config())

      by_addr = Parse.normalize(inbound(from: "support@acme.test"), config())
      assert {:suppress, :own_identity} = LoopGuard.classify(by_addr, config())
    end
  end

  # ==========================================================================
  # Threading — token extraction (pure). Org-scoped resolution is DB-tested in demo.
  # ==========================================================================

  describe "Threading.candidate_ticket_ids/2 (token extraction)" do
    test "extracts the id from a plus-address" do
      parsed = Parse.normalize(inbound(to: ["support+ticket-#{@tid}@acme.test"]), config())
      assert @tid in Threading.candidate_ticket_ids(parsed, config())
    end

    test "extracts the id from a subject token" do
      parsed = Parse.normalize(inbound(subject: "Re: order help [ticket-#{@tid}]"), config())
      assert @tid in Threading.candidate_ticket_ids(parsed, config())
    end

    test "extracts the id from an In-Reply-To that carries our outbound pattern" do
      parsed =
        Parse.normalize(inbound(headers: %{"In-Reply-To" => "<ticket-#{@tid}.nonce@acme.test>"}), config())

      assert @tid in Threading.candidate_ticket_ids(parsed, config())
    end

    test "a FOREIGN message-id without our prefix yields NO candidate (not mistaken for a ticket)" do
      other = "22222222-2222-4222-8222-222222222222"
      parsed = Parse.normalize(inbound(headers: %{"In-Reply-To" => "<#{other}@random.test>"}), config())
      assert Threading.candidate_ticket_ids(parsed, config()) == []
    end
  end

  # ==========================================================================
  # Fail-honest adapter seam (g)
  # ==========================================================================

  describe "fail-honest inbound adapter" do
    test "an UNCONFIGURED inbound adapter returns {:error, :not_configured}, never a fake parse" do
      FakeProvider.reset()
      FakeProvider.set_capabilities([:inbound])
      assert FakeProvider.parse_inbound("{}", [], %{}) == {:error, :not_configured}
    end

    test "an adapter WITHOUT the :inbound capability returns {:error, :not_implemented}" do
      FakeProvider.reset()
      assert FakeProvider.parse_inbound("{}", [], %{configured: true}) == {:error, :not_implemented}
    end

    test "ingest_raw surfaces the adapter's :not_configured verbatim (no fabricated ticket)" do
      FakeProvider.reset()
      FakeProvider.set_capabilities([:inbound])

      assert {:error, :not_configured} =
               Samen.Support.Inbound.Ingest.ingest_raw(FakeProvider, "{}", [], %{}, config())
    end
  end
end
