defmodule Driftwood.Policy.FmcsaDispatchGate do
  @moduledoc """
  The FMCSA dispatch legality gate (design §4, DECISION F) — a reusable
  `Ash.Resource.Change` run in `before_action` on the `DispatchEvent.:dispatch`
  action, exactly the shape of the shipped `Samen.Policy.SameOrgFk`.

  ## The rule (exact, design §4)

  A driver MUST NOT be dispatched to a load if, at the moment of dispatch, ANY of:

    1. `medical_card_expiry` is null OR `< today` (medical card missing/expired), OR
    2. `cdl_expiry` is null OR `< today` (CDL missing/expired), OR
    3. the CDL vault token is absent/`shredded` (no valid CDL on file), OR
    4. `status` is `:out_of_service` OR `:terminated`.

  `today` is `Date.utc_today()` evaluated AT DISPATCH TIME — a point-in-time check,
  so a row lingering past expiry cannot dispatch.

  ## Why it reads DATES, not the vaulted CDL (design OR-7 resolution)

  The gate must never decrypt the CDL number (that would need a reveal grant and
  route PII into a dispatch code path — a `pii_reads` violation). It checks:

    * the expiry DATES (plain, non-PII columns), and
    * the PRESENCE of the CDL vault token: a bounded `SELECT` on the `pii_vault`
      table for `(subject_id = driver_id, vault_name = 'pii_cdl')` asserting a row
      exists with `state = 'active'` (NOT `'shredded'`). This proves a CDL is on
      file WITHOUT decrypting it — the ciphertext is never read.

  This keeps the whole compliance check on non-PII data — the deliberate design
  choice so the gate never touches plaintext PII. It is also why `cdl_expiry` is a
  separate non-PII column: the gate needs CDL VALIDITY without CDL PLAINTEXT.
  """
  use Ash.Resource.Change

  require Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      driver_id = Ash.Changeset.get_attribute(cs, :driver_id)

      case load_driver(cs, driver_id) do
        nil ->
          Ash.Changeset.add_error(cs,
            field: :driver_id,
            message: "dispatch refused: driver not found (#{inspect(driver_id)})"
          )

        driver ->
          evaluate_gate(cs, driver_id, driver)
      end
    end)
  end

  # Load ONLY the non-PII gate inputs directly from the driver table via a bare
  # repo query (never Ash.read — so OrgScope filtering can't make a lingering row
  # vanish and pass the gate vacuously; same reasoning as SameOrgFk).
  defp load_driver(changeset, driver_id) when is_binary(driver_id) or is_struct(driver_id) do
    repo = repo!(changeset)

    query =
      Ecto.Query.from(d in "drv_driver",
        where: d.drv_id == ^Ecto.UUID.dump!(to_string(driver_id)),
        select: %{
          medical_card_expiry: d.drv_medical_card_expiry,
          cdl_expiry: d.drv_cdl_expiry,
          status: d.drv_status
        }
      )

    repo.one(query)
  end

  defp load_driver(_changeset, _driver_id), do: nil

  defp evaluate_gate(changeset, driver_id, driver) do
    today = Date.utc_today()

    errors =
      []
      |> check_medical_card(driver.medical_card_expiry, today)
      |> check_cdl_expiry(parse_iso(driver.cdl_expiry), today)
      |> check_cdl_on_file(changeset, driver_id)
      |> check_status(driver.status)

    Enum.reduce(errors, changeset, fn message, cs ->
      Ash.Changeset.add_error(cs, field: :driver_id, message: message)
    end)
  end

  defp check_medical_card(errors, nil, _today),
    do: ["dispatch refused: {:medical_card_missing}" | errors]

  defp check_medical_card(errors, expiry, today) do
    if Date.compare(expiry, today) == :lt do
      ["dispatch refused: {:medical_card_expired, #{Date.to_iso8601(expiry)}}" | errors]
    else
      errors
    end
  end

  defp check_cdl_expiry(errors, nil, _today),
    do: ["dispatch refused: {:cdl_missing_expiry}" | errors]

  defp check_cdl_expiry(errors, %Date{} = expiry, today) do
    if Date.compare(expiry, today) == :lt do
      ["dispatch refused: {:cdl_expired, #{Date.to_iso8601(expiry)}}" | errors]
    else
      errors
    end
  end

  # cdl_expiry is stored as ISO-8601 TEXT (see the Driver resource note). Parse it to
  # a %Date{}; an unparseable/blank value is treated as a missing expiry (fail closed).
  defp parse_iso(nil), do: nil
  defp parse_iso(%Date{} = d), do: d

  defp parse_iso(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  # Token-PRESENCE check: a bounded SELECT on pii_vault for the driver's CDL vault
  # row. Passes only if a row exists AND its state is 'active' (not 'shredded').
  # Never decrypts — the ciphertext column is not read.
  defp check_cdl_on_file(errors, changeset, driver_id) do
    repo = repo!(changeset)
    subject_id = to_string(driver_id)

    query =
      Ecto.Query.from(v in "pii_vault",
        where: v.subject_id == ^subject_id and v.vault_name == "pii_cdl",
        select: v.state
      )

    case repo.all(query) do
      [] ->
        ["dispatch refused: {:cdl_missing}" | errors]

      states ->
        if Enum.any?(states, &(&1 == "active")) do
          errors
        else
          ["dispatch refused: {:cdl_shredded}" | errors]
        end
    end
  end

  defp check_status(errors, status) when status in ["out_of_service", :out_of_service],
    do: ["dispatch refused: {:driver_out_of_service}" | errors]

  defp check_status(errors, status) when status in ["terminated", :terminated],
    do: ["dispatch refused: {:driver_terminated}" | errors]

  defp check_status(errors, _status), do: errors

  defp repo!(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate) ||
      Application.get_env(:driftwood, :vault_repo) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "FmcsaDispatchGate: could not resolve a repo for #{inspect(changeset.resource)}"
  end
end
