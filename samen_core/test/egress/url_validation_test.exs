defmodule Samen.Egress.UrlValidationTest do
  @moduledoc """
  Issue #25 step 3 — registration-time refusal on the `webhook🔒` Tier-0 config row.

  A URL that fails `Samen.Egress.Guard.check_literal/2` must not be SAVEABLE. The
  assertions are FIELD-SCOPED (an error on `:url`, or the absence of one) rather than on
  `changeset.valid?` alone, so an unrelated required-attribute error can neither
  manufacture a pass on the red nor break the positive control.

  The resource under test is `SamenCore.Support.NotificationFixture.Webhook` — the
  Primitives scope mounted inside `samen_core`'s own test tree (abbrev `nwh`), which is
  the SAME `define_webhook/5` blueprint every host (demo, driftwood, pawchart) mounts. No
  DB round-trip: `Ash.Changeset.for_create/3` runs the validation in memory.
  """
  use ExUnit.Case, async: true

  alias SamenCore.Support.NotificationFixture.Webhook, as: WebhookEndpoint

  defp url_errors(changeset) do
    Enum.filter(changeset.errors, fn error ->
      field = Map.get(error, :field)
      fields = Map.get(error, :fields) || []
      field == :url or :url in fields
    end)
  end

  defp changeset_for(url) do
    Ash.Changeset.for_create(WebhookEndpoint, :create, %{
      url: url,
      label: "test endpoint",
      event_types: ["invoice.created"]
    })
  end

  test "#25 RED: a cloud-metadata URL cannot be registered" do
    changeset = changeset_for("http://169.254.169.254/latest/meta-data/")

    refute changeset.valid?
    assert [_ | _] = errors = url_errors(changeset)
    assert Enum.any?(errors, fn e -> to_string(Map.get(e, :message) || "") =~ "egress guard" end)
  end

  test "#25 RED: a loopback URL cannot be registered" do
    changeset = changeset_for("https://127.0.0.1/hook")
    assert [_ | _] = url_errors(changeset)
  end

  test "#25 RED: an RFC1918 URL cannot be registered" do
    changeset = changeset_for("https://10.0.0.1/hook")
    assert [_ | _] = url_errors(changeset)
  end

  test "#25 RED: an IPv6-loopback URL cannot be registered" do
    changeset = changeset_for("http://[::1]/hook")
    assert [_ | _] = url_errors(changeset)
  end

  test "#25 RED: an IPv4-mapped IPv6 private URL cannot be registered" do
    changeset = changeset_for("http://[::ffff:10.0.0.1]/hook")
    assert [_ | _] = url_errors(changeset)
  end

  test "#25 RED: a non-http(s) scheme cannot be registered" do
    changeset = changeset_for("file:///etc/passwd")
    assert [_ | _] = url_errors(changeset)
  end

  test "#25 POSITIVE CONTROL: a public https URL registers with no error on :url" do
    changeset = changeset_for("https://hooks.example.com/samen")
    assert url_errors(changeset) == []
  end

  test "#25 RED: an UPDATE to a private URL is refused too (and a public one is not)" do
    existing = %WebhookEndpoint{id: Ash.UUID.generate(), url: "https://old.example.com/hook"}

    private = Ash.Changeset.for_update(existing, :update, %{url: "http://169.254.169.254/x"})
    assert [_ | _] = url_errors(private)

    public = Ash.Changeset.for_update(existing, :update, %{url: "https://hooks.example.com/samen"})
    assert url_errors(public) == []
  end
end
