defmodule Driftwood.Webhooks do
  @moduledoc """
  F1 (Gate-5 carry) — outbound webhook payloads for the freight vertical (doc
  §external-surface: "outbound webhooks emit the SAME masked, catalogued payloads").

  Every payload is built by the SHARED `Samen.Webhook.Payload.build/3`, which honors the
  resource's `show_fields` OPT-IN allowlist (the SAME allowlist the JSON:API surface
  uses, so the two egress surfaces cannot drift). A field absent from the allowlist —
  including a storage column, `org_id`, and the Tier-1 `custom` bag — is ABSENT by
  omission; a `%Masked{}` PII value serializes as `••••` (or is omitted on the operator
  plane without a grant). No storage name (`pii_drv_*`, `drv_*`, `dsp_*`) ever appears.

  Two freight events:

    * `load.status` — a dispatch's status change (dispatched/in_transit/delivered/
      cancelled) over the non-PII `Driftwood.Freight.DispatchEvent`. Proves the opt-in /
      storage-name / custom-bag controls on a load-status event WITHOUT any decrypt.
    * `driver.updated` — a driver record change over the PII-bearing
      `Driftwood.Freight.Driver`. Proves the masked-catalogued-payload guarantee: the
      vaulted CDL renders `••••`, never plaintext, never a `vt_` token.
  """

  alias Samen.Webhook.Payload

  @doc """
  Build the `load.status` webhook payload for a dispatch (load-status) record.

  The record is a `Driftwood.Freight.DispatchEvent` struct (non-PII). The payload carries
  only allowlisted catalog fields (`status`, `dispatched_at`, `driver_id`, `load_id`);
  `org_id` and the `custom` bag are absent by omission.
  """
  @spec load_status(struct()) :: map()
  def load_status(dispatch_event) do
    Payload.build("load.status", Driftwood.Freight.DispatchEvent, dispatch_event)
  end

  @doc """
  Build the `driver.updated` webhook payload for a driver record.

  The driver's vaulted `cdl_number`/`full_name` are `%Masked{}` on a plane-less/masked
  read → they serialize as `••••` (never plaintext, never a `vt_` token). `org_id` and
  the storage columns are absent by omission (opt-in allowlist).
  """
  @spec driver_updated(struct()) :: map()
  def driver_updated(driver) do
    Payload.build("driver.updated", Driftwood.Freight.Driver, driver)
  end
end
