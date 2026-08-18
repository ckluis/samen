defmodule Driftwood.OperatorReveal do
  @moduledoc """
  Drive a SECOND-PARTY reveal of a driver's vaulted CDL number end-to-end (T5.3 clause (b),
  T1.6). This is the SEPARATE unmask path layered on top of masked impersonation — an
  operator, under an ACTIVE, distinct-party-approved `Samen.Reveal.Grant`, decrypts a
  driver's vaulted CDL number through the single decrypt chokepoint
  (`Samen.Reveal.reveal/5`). Without an approving grant it denies — `••••` stays.

  ## Honest scope: the grant is SUBJECT-WIDE (R-P6 / persona-6 P6-F1)

  This function targets the CDL field, but the underlying grant it consults is
  **subject-wide, not field-narrow**: `Samen.Reveal.Grants.active?/3` keys only on
  `(subject_id, requestor_id)`. So while a grant is live, the SAME subject's OTHER vaulted
  fields (notably the driver's full name) also resolve to plaintext on the tenant-plane
  resolver — including passively, on a plain roster load, with no reveal click. That is
  lawful (a valid distinct-party grant authorizes operator-plane resolution of that
  subject), but the scope is the whole record. The UI states this truthfully ("Reveal
  driver record", plus an open-window banner) rather than implying a field-narrow "CDL
  only" reveal. If field-level scoping is ever required, it must be added to `active?/3`
  (grant enforcement becomes field-aware) with its own red + positive-control test.

  The reveal actor is the OPERATOR ID (a plain string): it is NOT the token-blind
  aggregate actor, so the mutual-exclusion gate does not fire here; the grant gate does.
  `granted?/1` (the wired `Samen.Reveal.Grants`) checks for an active, unexpired,
  distinct-party grant for `(operator_id, driver_id)` and denies otherwise.
  """

  require Ash.Query

  @doc """
  Attempt to reveal the CDL plaintext for `driver_id` on behalf of `operator_id`.
  Returns `{:ok, plaintext}` only under an active second-party grant; otherwise
  `{:error, reason}` (`:denied`, `:not_found`, `:shredded`, …). `••••` never becomes
  plaintext without an approving grant.
  """
  @spec reveal_cdl(binary(), binary()) :: {:ok, String.t()} | {:error, term()}
  def reveal_cdl(operator_id, driver_id) do
    case masked_cdl(driver_id) do
      {:ok, masked} ->
        Samen.Reveal.reveal(
          operator_id,
          masked,
          :reveal_driver,
          Driftwood.Freight.Driver,
          subject_id: to_string(driver_id),
          repo: Driftwood.Repo
        )

      {:error, _} = err ->
        err
    end
  end

  # Load the driver's masked CDL value (a %Samen.Masked{}) — the token to decrypt.
  defp masked_cdl(driver_id) do
    driver =
      Driftwood.Freight.Driver
      |> Ash.Query.filter(id == ^driver_id)
      |> Ash.Query.ensure_selected([:cdl_number])
      |> Ash.read_one!(authorize?: false)

    case driver do
      nil -> {:error, :not_found}
      %{cdl_number: %Samen.Masked{} = masked} -> {:ok, masked}
      _ -> {:error, :no_masked_value}
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  REQUEST a second-party reveal grant for a driver (T149 B5 — the missing entry point). This
  is the REQUEST side of the EXISTING reveal-grant lifecycle (`Samen.Reveal.Grants.request/1`):
  it files a `RevealRequest` (subject = the driver, requestor = the operator, a bounded reason)
  and opens a PENDING `pii_reveal` approval — it GRANTS NOTHING on its own. A DISTINCT second
  party must then `approve/2` (distinct-party enforced at the policy layer AND the
  `rvg_distinct_party` DB CHECK), which mints a TIME-BOXED grant (default
  `Samen.Reveal.Grants.default_window_minutes/0` minutes). Only THEN does `reveal_cdl/2` unmask.

  The reveal machinery is NOT rebuilt here — this wires the request entry point the operator
  console lacked. Returns `{:ok, %RevealRequest{}}` or `{:error, reason}` (incl.
  `{:error, {:pii_shaped_reason, _}}` when the reason is itself a PII value shape — the reason
  must name the ticket, not the person).
  """
  # PP-11 (T150): `org_id` is the TENANT org the impersonation session is opened over —
  # the driver's own org. Threading it makes the reveal-request lifecycle event land on
  # THAT tenant's audit chain (visible on its `Settings.SecurityLive` ledger), instead of
  # the org-less `__global__` operator chain. Optional (defaults `nil`) so the pre-PP-11
  # 3-arity call sites keep compiling with the pre-PP-11 (global-chain) behavior.
  @spec request_reveal(binary(), binary(), String.t(), String.t() | nil) ::
          {:ok, Samen.Reveal.RevealRequest.t()} | {:error, term()}
  def request_reveal(operator_id, driver_id, reason, org_id \\ nil)

  def request_reveal(operator_id, driver_id, reason, org_id)
      when is_binary(operator_id) and is_binary(driver_id) and is_binary(reason) do
    Samen.Reveal.Grants.request(%{
      subject_id: to_string(driver_id),
      requestor_id: to_string(operator_id),
      reason: reason,
      resource: Driftwood.Freight.Driver,
      action: :reveal_driver,
      org_id: org_id,
      repo: Driftwood.Repo
    })
  end

  def request_reveal(_operator_id, _driver_id, _reason, _org_id), do: {:error, :invalid_request}
end
