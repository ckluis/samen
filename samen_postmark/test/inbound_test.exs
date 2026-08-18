defmodule SamenPostmark.InboundTest do
  @moduledoc """
  C5 inbound-parse coverage for the reference (inbound-capable) adapter (T59). The
  ticket/thread/vault/loop consumer lives in `samen_core`
  (`Samen.Support.Inbound.*`, unit-tested there and integration-tested on the demo
  host); THIS suite pins the ADAPTER end of the seam: the fail-honest gate on
  `parse_inbound/3`, and that a valid vendor payload normalizes into a
  `Samen.Delivery.InboundMessage` with the fields the consumer threads on
  (From/FromName/To/Subject/bodies/Headers/Message-ID), without crashing on
  malformed input.
  """
  use ExUnit.Case, async: true

  alias Samen.Delivery.InboundMessage
  alias SamenPostmark.Provider

  @creds %{inbound_username: "u", inbound_password: "p"}
  defp configured, do: Map.merge(%{server_token: "tok", from: "sender@example.test"}, @creds)

  defp auth_headers(user \\ "u", pass \\ "p"),
    do: [{"Authorization", "Basic " <> Base.encode64("#{user}:#{pass}")}]

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "MessageID" => "msg-abc",
        "From" => "ada@customer.test",
        "FromName" => "Ada Lovelace",
        "To" => "support+ticket-1@demo.test, ops@demo.test",
        "Subject" => "Cannot log in",
        "TextBody" => "Please help.",
        "HtmlBody" => "<p>Please help.</p>",
        "Headers" => [%{"Name" => "In-Reply-To", "Value" => "<ticket-1.x@demo.test>"}],
        "Attachments" => []
      },
      overrides
    )
    |> Jason.encode!()
  end

  # ==========================================================================
  # Fail-honest gate (g) — the exact lie the gates sabotage-test for
  # ==========================================================================

  describe "fail-honest parse_inbound/3" do
    test "UNCONFIGURED adapter returns {:error, :not_configured}, never a fake parse" do
      assert Provider.parse_inbound(payload(), auth_headers(), %{}) == {:error, :not_configured}
    end

    test "configured but MISSING inbound creds returns {:error, :not_implemented}" do
      config = %{server_token: "tok", from: "sender@example.test"}
      assert Provider.parse_inbound(payload(), auth_headers(), config) == {:error, :not_implemented}
    end

    test "wrong Basic-Auth credentials return {:error, :invalid_signature} (parses nothing)" do
      assert Provider.parse_inbound(payload(), auth_headers("u", "WRONG"), configured()) ==
               {:error, :invalid_signature}
    end

    test "the capability is honestly declared" do
      assert :inbound in Provider.capabilities()
    end
  end

  # ==========================================================================
  # Valid parse → InboundMessage the T59 consumer threads on
  # ==========================================================================

  describe "parse_inbound/3 normalization" do
    test "a valid, authenticated payload normalizes into an InboundMessage" do
      assert {:ok, %InboundMessage{} = msg} =
               Provider.parse_inbound(payload(), auth_headers(), configured())

      assert msg.provider == :postmark
      assert msg.message_id == "msg-abc"
      assert msg.from == "ada@customer.test"
      assert msg.from_name == "Ada Lovelace"
      assert "support+ticket-1@demo.test" in msg.to
      assert msg.subject == "Cannot log in"
      assert msg.text_body == "Please help."
      assert msg.headers["In-Reply-To"] == "<ticket-1.x@demo.test>"
    end

    test "a missing Message-ID falls back to a content hash (no crash, stable id)" do
      body = payload(%{"MessageID" => nil})
      assert {:ok, %InboundMessage{message_id: id}} = Provider.parse_inbound(body, auth_headers(), configured())
      assert is_binary(id) and id != ""
    end
  end

  # ==========================================================================
  # Malformed input — no crash
  # ==========================================================================

  describe "malformed input" do
    test "non-JSON body returns {:error, :malformed}, never raises" do
      assert Provider.parse_inbound("this is not json", auth_headers(), configured()) ==
               {:error, :malformed}
    end

    test "a non-binary raw body is refused honestly (configured → :malformed)" do
      assert Provider.parse_inbound(%{not: "binary"}, auth_headers(), configured()) ==
               {:error, :malformed}
    end
  end
end
