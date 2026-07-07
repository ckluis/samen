defmodule Driftwood.OperatorReveal do
  @moduledoc """
  Drive a SECOND-PARTY reveal of ONE driver's CDL number end-to-end (T5.3 clause (b),
  T1.6). This is the SEPARATE unmask path layered on top of masked impersonation — an
  operator, under an ACTIVE, distinct-party-approved `Samen.Reveal.Grant`, unmasks a
  single driver's vaulted CDL number through the single decrypt chokepoint
  (`Samen.Reveal.reveal/5`). Without an approving grant it denies — `••••` stays.

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
end
