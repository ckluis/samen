defmodule Samen.Delivery.PiiRenderingTest do
  @moduledoc """
  WS-C C3 (T29) — THE per-plane masking gate for PII-safe email RENDERING, the
  INV-1 load-bearing task of WS-C. The SAME token-only `Samen.Delivery.Message` +
  the SAME recipient record renders two ways through `Samen.Delivery.Rendering`
  (composing the T28 `Samen.Delivery.Chokepoint` send path):

    * **SEND / recipient plane** (`Chokepoint.render_for_send/4`): the recipient
      legitimately receives their OWN email, so the vault-routed address + the body
      that interpolates it resolve to PLAINTEXT (green).
    * **OPERATOR-preview plane** (`Rendering.preview_for_operator/4`): the SAME
      message masks — `••••`, NEVER the plaintext, NEVER a `vt_` vault token (red).
    * **SABOTAGE twin** (anti-tautology): the operator mask is REFUTABLE — a
      clear (send-plane) render of the same record LEAKS the sentinel and is caught
      by the same scan, and the plane flip is the only difference.

  Plus the two payload/at-rest guarantees C3 exists to prove:
    * the provider payload carries ONLY the ADR-whitelisted fields and NEVER a
      `vt_` token (a vault token reaching the ESP is a real breach);
    * a delivery record at rest (a real `oban_jobs` DB dump) holds provider id +
      template ref + opaque refs — NO plaintext rendered body.

  All resolution runs through `Samen.Api.PiiResolution` (the governed read path) on
  the actor's plane — never bypassed, never hand-masked — via `Samen.MaskingCase`.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  alias Samen.Delivery.{Chokepoint, Message, RenderedEmail, Rendering}
  alias Samen.Masked
  alias SamenCore.Support.RevealDomain.RevealPerson

  @repo SamenCore.TestRepo
  @resource RevealPerson

  # The sentinel PII: the recipient's OWN email address. Legitimately plaintext on
  # the send path (the mail is addressed to them); it must never survive at rest,
  # never appear on an operator preview, and never leak as a vt_ token to the ESP.
  @recipient_email "ada.recipient-SENTINEL@customer.test"
  @vault_token "vt_recip_ada_sentinel_token"

  # A vault stub — the grant/plane gate is what we prove, not the vault decrypt
  # (mirrors impersonation_masking_test.exs). On the send plane the tenant owns its
  # PII, so this returns the recipient's plaintext address.
  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "ada.recipient-SENTINEL@customer.test"}
  end

  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp recipient(id) do
    struct(@resource, %{
      id: id,
      display_name: "Ada",
      emails: Masked.new(@vault_token, :emails)
    })
  end

  defp message(subscriber_id) do
    %Message{
      send_id: Ecto.UUID.generate(),
      org_id: Ecto.UUID.generate(),
      to_subscriber_id: subscriber_id,
      template_id: "welcome"
    }
  end

  defp send_render(id),
    do: Chokepoint.render_for_send(message(id), recipient(id), @resource, repo: :unused, vault: OkVault)

  defp operator_preview(id),
    do:
      Rendering.preview_for_operator(message(id), recipient(id), @resource,
        repo: :unused,
        vault: OkVault,
        grant: DenyAll
      )

  # ==========================================================================
  # The MaskingCase 3-proof (send clear · operator masked · refutable)
  # ==========================================================================

  test "GREEN — the recipient-facing render on the SEND path resolves PLAINTEXT (their own email)" do
    id = Ecto.UUID.generate()
    rendered = send_render(id)

    # The resolved address is CLEAR (not a %Masked{}) — the recipient owns the mail.
    assert_plane_clear!(rendered.to, @recipient_email)
    # …and the body that interpolates it is plaintext too, with no vault token.
    assert rendered.text_body =~ @recipient_email
    assert rendered.html_body =~ @recipient_email
    refute rendered.text_body =~ "vt_"
    refute rendered.html_body =~ "vt_"
  end

  test "RED — an operator-plane PREVIEW of the SAME message MASKS (••••, never plaintext, never vt_)" do
    id = Ecto.UUID.generate()
    preview = operator_preview(id)

    # The address masks to %Masked{} → •••• (present-but-masked; the impersonation posture).
    assert_plane_masked!(preview.to, @recipient_email)
    # The body shows the mask and NOT the plaintext, with no vt_ token anywhere.
    assert preview.text_body =~ Masked.mask()
    refute preview.text_body =~ @recipient_email
    refute preview.text_body =~ "vt_"
    # DOM (html) form: mask present, plaintext absent by omission, no vt_.
    assert_masked_dom!(preview.html_body, @recipient_email)
  end

  test "BOTH directions on the SAME message — send plaintext ∧ operator masked (anti-tautology)" do
    id = Ecto.UUID.generate()
    rendered = send_render(id)
    preview = operator_preview(id)

    # The ONLY difference between the two renders is the plane.
    assert_two_plane!(rendered.to, preview.to, @recipient_email)
    assert rendered.text_body =~ @recipient_email
    refute preview.text_body =~ @recipient_email
    assert preview.text_body =~ Masked.mask()
  end

  test "SABOTAGE TWIN — the operator mask is REFUTABLE (a clear render leaks and is caught)" do
    id = Ecto.UUID.generate()

    # AS-DESIGNED: the operator preview masks — the sentinel is ABSENT.
    preview = operator_preview(id)
    refute preview.text_body =~ @recipient_email
    refute preview.html_body =~ @recipient_email

    # SABOTAGE MODEL: a resolver that failed to mask would render the SAME record's
    # body in the CLEAR — which is precisely the send-plane render. The leak scan
    # FLIPS on it, proving the operator `refute`s above are refutable, not vacuous.
    leaked = send_render(id)
    assert_leak_detected!(leaked.text_body, @recipient_email)
    assert_leak_detected!(leaked.html_body, @recipient_email)
  end

  # ==========================================================================
  # Provider payload minimality (ADR-whitelisted fields only; NEVER a vt_ token)
  # ==========================================================================

  test "PAYLOAD — the provider payload carries ONLY the ADR-whitelisted fields, never a vt_ token" do
    id = Ecto.UUID.generate()
    rendered = send_render(id)

    payload = RenderedEmail.provider_payload(rendered)

    # EXACTLY the whitelist — no extra field rides along (the sabotage flips this).
    assert Enum.sort(Map.keys(payload)) == [:html_body, :subject, :text_body, :to]
    assert Enum.sort(Map.keys(payload)) == Enum.sort(RenderedEmail.provider_payload_fields())

    # The resolved recipient address is present (non-vacuous — this is a real send payload).
    assert payload.to == @recipient_email

    # NO vault token anywhere in the payload — a vt_ reaching the ESP is a breach.
    refute inspect(payload) =~ "vt_"
    refute Enum.any?(Map.values(payload), &match?(%Masked{}, &1))

    # The recipient's own vault token IS known to the render (internal correlation)
    # but is deliberately NOT in the payload — the exact field the sabotage leaks.
    assert rendered.vault_token_ref == @vault_token
    refute Map.has_key?(payload, :vault_token_ref)
  end

  test "PAYLOAD GUARD — a masked (operator) render REFUSES to become a provider payload (fail-closed)" do
    id = Ecto.UUID.generate()
    preview = operator_preview(id)

    # An operator preview holds a %Masked{} address; turning it into an ESP payload
    # would transmit a masked/unresolved value — refused (INV-1 fail-closed).
    assert_raise ArgumentError, fn -> RenderedEmail.provider_payload(preview) end
  end

  # ==========================================================================
  # At-rest: a real oban_jobs DB dump — provider id + template ref + refs, NO body
  # ==========================================================================

  test "AT-REST — the persisted delivery record holds refs + provider id + template ref, NO rendered body (DB dump grep)" do
    id = Ecto.UUID.generate()
    rendered = %{send_render(id) | provider_message_id: "esp-msg-12345"}

    # Positive control: the render DID contain the sentinel — the body was real,
    # so a body persisted at rest WOULD be caught by the grep below (non-vacuous).
    assert rendered.text_body =~ @recipient_email

    at_rest = RenderedEmail.at_rest_record(rendered)

    # Structurally: the at-rest projection has NO body/subject/address key.
    refute Map.has_key?(at_rest, :text_body)
    refute Map.has_key?(at_rest, :html_body)
    refute Map.has_key?(at_rest, :subject)
    refute Map.has_key?(at_rest, :to)
    assert Enum.sort(Map.keys(at_rest)) == Enum.sort(RenderedEmail.at_rest_fields())

    # Persist it as a REAL delivery record (an oban_jobs row — the durable delivery
    # artifact) and dump the row back out of Postgres.
    string_args =
      at_rest
      |> Map.new(fn {k, v} -> {to_string(k), v && to_string(v)} end)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %{rows: [[job_id]]} =
      @repo.query!(
        "INSERT INTO oban_jobs (queue, args, worker, state, inserted_at, scheduled_at, priority, max_attempts, attempt) " <>
          "VALUES ('webhooks_out', $1, 'Samen.Delivery.Lifecycle.EmailWorker', 'available', now(), now(), 0, 20, 0) RETURNING id",
        [string_args]
      )

    %{rows: [[dumped_args]]} =
      @repo.query!("SELECT args FROM oban_jobs WHERE id = $1", [job_id])

    dump = Jason.encode!(dumped_args)

    # THE at-rest assertion: no plaintext rendered body / sentinel PII at rest…
    refute dump =~ @recipient_email
    refute dump =~ "SENTINEL"
    # …and no vault token at rest either.
    refute dump =~ "vt_"

    # Non-vacuous: the row genuinely holds the refs + provider id + template ref.
    assert dump =~ rendered.send_id
    assert dump =~ "esp-msg-12345"
    assert dump =~ "welcome"
  end
end
