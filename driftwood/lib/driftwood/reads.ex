defmodule Driftwood.Reads do
  @moduledoc """
  The SHARED tenant-plane read layer used by BOTH planes' LiveViews (T5.3).

  This is the load-bearing seam that makes the masked-impersonation guarantee real: the
  broker's own dashboard and the OPERATOR's impersonation view call the EXACT SAME
  functions here — `driver_roster/1`, `load_board/1`, `settlements/1` — differing only
  in the `scope` passed. When the operator passes an impersonation scope (no reveal
  grant), the vault-routed fields (`full_name`, `cdl_number`) come back as `%Masked{}`
  and render `••••` BY CONSTRUCTION. There is no separate "operator read" that could
  accidentally leak plaintext — one code path, one masking behaviour.

  Every function takes an `%Ash.Query`-compatible `scope` (a `%Samen.Scope{}` or an
  actor map) and reads through Ash so OrgScope + the vault masking apply. Vault fields
  are `ensure_selected` explicitly (a real UI asks for them); without a reveal grant
  they load masked.

  ## FMCSA status (the driver roster)

  `fmcsa_status/1` computes, for a driver row, the SAME legality the
  `Driftwood.Policy.FmcsaDispatchGate` enforces — medical/CDL expiry, driver status —
  as a display badge (`:ok` | `{:blocked, reasons}`). It reads ONLY non-PII columns
  (dates + status), never the vaulted CDL number. `dispatchable?/1` is the UI-action
  guard: the roster's "Dispatch" button is disabled for a non-`:ok` driver, matching
  the server-side gate (defence in depth — the gate still refuses if the UI is
  bypassed).
  """

  @doc """
  The DRIVER ROSTER for the given scope: driver rows with name (masked unless granted),
  CDL number (masked), CDL state/expiry (non-PII), medical expiry, status, ELD provider,
  and a computed FMCSA badge. Reads through Ash — OrgScope narrows to the scope's org;
  the vault fields load `%Masked{}` without a reveal grant.
  """
  def driver_roster(scope) do
    Driftwood.Freight.Driver
    |> Ash.Query.ensure_selected([
      :full_name,
      :cdl_number,
      :cdl_state,
      :cdl_expiry,
      :medical_card_expiry,
      :status,
      :eld_provider
    ])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn d ->
      Map.put(d, :__fmcsa__, fmcsa_status(d))
    end)
  rescue
    _ -> []
  end

  @doc """
  The LOAD BOARD for the given scope: Load (Opportunity alias) rows — name, value cents,
  status, close date, lane (from the custom bag). Non-PII throughout; reads through the
  scope's org boundary.
  """
  def load_board(scope) do
    Driftwood.Crm.Opportunity
    |> Ash.Query.ensure_selected([:name, :value_cents, :currency, :status, :close_date, :custom])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn l ->
      lane = get_in(l.custom || %{}, ["lane"]) || "unknown"
      Map.put(l, :__lane__, lane)
    end)
  rescue
    _ -> []
  end

  @doc """
  The SETTLEMENTS for the given scope, WITH the `Driftwood.Context` reshape calcs loaded
  (gross / factoring_fee / net_payable / carryover) — the reshaped two-sided money. The
  derived money is read through `Samen.Context.reshaped_query/2` (the anti-corruption
  layer), so the calcs land in `row.calculations`; this returns a normalized map per
  settlement with the stored inputs + the derived fields flattened. Reads through the
  scope's org boundary; all columns are non-PII cents/enums.
  """
  def settlements(scope) do
    Samen.Context.reshaped_query(Driftwood.Context, Driftwood.Freight.Settlement)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> Enum.map(fn s ->
      calc = s.calculations || %{}

      %{
        id: s.id,
        status: s.status,
        linehaul_cents: s.linehaul_cents,
        advances_cents: s.advances_cents,
        claim_deduction_cents: s.claim_deduction_cents,
        gross_cents: to_int(Map.get(calc, :gross_cents)),
        factoring_fee_cents: to_int(Map.get(calc, :factoring_fee_cents)),
        net_payable_cents: to_int(Map.get(calc, :net_payable_cents)),
        carryover_cents: to_int(Map.get(calc, :carryover_cents))
      }
    end)
  rescue
    _ -> []
  end

  # The reshape returns :integer calcs (sometimes a Decimal from the numeric SQL path).
  defp to_int(nil), do: 0
  defp to_int(i) when is_integer(i), do: i
  defp to_int(f) when is_float(f), do: round(f)
  defp to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()

  @doc """
  Compute the FMCSA display status for a driver row — the SAME rule the
  `FmcsaDispatchGate` enforces (medical/CDL expiry, driver status), as a display badge.
  Reads ONLY non-PII columns. Returns `:ok` or `{:blocked, [reason_atom]}`.
  """
  @spec fmcsa_status(map()) :: :ok | {:blocked, [atom()]}
  def fmcsa_status(driver) do
    today = Date.utc_today()

    reasons =
      []
      |> check_medical(Map.get(driver, :medical_card_expiry), today)
      |> check_cdl(parse_iso(Map.get(driver, :cdl_expiry)), today)
      |> check_status(Map.get(driver, :status))

    case reasons do
      [] -> :ok
      list -> {:blocked, Enum.reverse(list)}
    end
  end

  @doc "Is this driver row currently dispatchable (FMCSA badge is :ok)? UI-action guard."
  @spec dispatchable?(map()) :: boolean()
  def dispatchable?(driver), do: fmcsa_status(driver) == :ok

  @doc "Human-readable reason label for a blocked FMCSA badge."
  def reason_label(:medical_missing), do: "medical card missing"
  def reason_label(:medical_expired), do: "medical card expired"
  def reason_label(:cdl_missing_expiry), do: "CDL expiry missing"
  def reason_label(:cdl_expired), do: "CDL expired"
  def reason_label(:out_of_service), do: "out of service"
  def reason_label(:terminated), do: "terminated"
  def reason_label(other), do: to_string(other)

  # -- gate rule mirrored (non-PII only) ------------------------------------

  defp check_medical(reasons, nil, _today), do: [:medical_missing | reasons]

  defp check_medical(reasons, %Date{} = expiry, today) do
    if Date.compare(expiry, today) == :lt, do: [:medical_expired | reasons], else: reasons
  end

  defp check_cdl(reasons, nil, _today), do: [:cdl_missing_expiry | reasons]

  defp check_cdl(reasons, %Date{} = expiry, today) do
    if Date.compare(expiry, today) == :lt, do: [:cdl_expired | reasons], else: reasons
  end

  defp check_status(reasons, s) when s in [:out_of_service, "out_of_service"],
    do: [:out_of_service | reasons]

  defp check_status(reasons, s) when s in [:terminated, "terminated"],
    do: [:terminated | reasons]

  defp check_status(reasons, _), do: reasons

  defp parse_iso(nil), do: nil
  defp parse_iso(%Date{} = d), do: d

  defp parse_iso(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      {:error, _} -> nil
    end
  end
end
