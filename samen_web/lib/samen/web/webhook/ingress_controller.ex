defmodule Samen.Web.Webhook.IngressController do
  @moduledoc """
  The `POST /webhooks/:provider` route entry (ADR-038 §5.1; T19/B9). A thin Phoenix
  controller that delegates to `Samen.Web.Webhook.Ingress.ingest/2` — the
  `BytesController` seam pattern (route wiring here, enforcement in the logic module).

  Mounted by `Samen.Web.Router.samen_webhook_routes/1`. The host's pipeline for this
  route MUST run `Plug.Parsers` with the `Samen.Web.Webhook.RawBodyReader` body reader
  so the exact signed bytes survive for signature verification.
  """
  use Phoenix.Controller, formats: [:json, :html]

  @doc "Ingest a webhook delivery (verify → persist → enqueue; ADR-038 §5.2)."
  def create(conn, _params), do: Samen.Web.Webhook.Ingress.ingest(conn, [])
end
