defmodule Samen.Scopes.SalesOps.ConvertLead do
  @moduledoc """
  The F7 lead → contact/opportunity conversion (`Lead.convert`). An
  `Ash.Resource.Change` scheduled via `Ash.Changeset.after_action` — the SAME
  cross-row-cascade discipline `Samen.Scopes.Work.CascadeRestore` uses, which runs
  INSIDE the same database transaction Ash opens for the `:convert` action (per
  `Samen.Vault.Change`'s own doc: `before_action`/`after_action` hooks share the
  action's transaction, so a failure anywhere in this hook rolls back EVERYTHING —
  the Lead's own `status`/`converted_at` change included; the Lead never ends up
  half-converted).

  ## The steps

  1. Reveal the Lead's vaulted `full_name`/`emails`/`phones` through the SINGLE
     `Samen.Vault.reveal/3` chokepoint (INV-1 — never a second decrypt path),
     JSON-decode, and re-cast each through its OWN type's `cast_input/2` (the same
     round-trip `Samen.Vault.Change` documents: composites are JSON-encoded to
     ciphertext, `reveal` returns the same binary back).
  2. Create the host CRM Person (the "Contact") from that PLAINTEXT via a normal
     governed `Ash.create` — `Samen.Vault.Change` mints a **fresh** `vt_*` token on
     the Person's OWN vault columns. The Lead's token is never copied, never
     reused: no PII crosses the conversion as shared ciphertext OR a shared token
     (the same "re-tokenize, never share" duplicate-safety rule G9 clone will use).
  3. Create the host CRM Opportunity, carrying the Lead's `value` — a
     `Samen.Type.Money` value, NON-PII, passed through completely UNCHANGED
     (Decimal arithmetic under the hood, never a float — INV-2 exactness. No
     reveal needed: Money was never vaulted).
  4. Link the Lead back to both new rows (`converted_person_id`,
     `converted_opportunity_id`) via a second governed update on the SAME Lead
     row, in the SAME transaction.

  Every cross-resource write runs `authorize?: false` — a system cascade
  following an already-authorized parent `:convert` action, mirroring
  `Samen.Scopes.Work.CascadeRestore`'s own posture (a trusted-kernel internal
  write, not a second policy-gated entry point).

  An optional `company_id` argument (asserted same-org by each created
  resource's own `Samen.Policy.SameOrgFk` change) links both the new Person and
  Opportunity to an existing CRM Company, when the caller has one.
  """
  use Ash.Resource.Change

  alias Samen.Masked
  alias Samen.Vault

  @impl true
  def change(changeset, opts, _context) do
    person_mod = Keyword.fetch!(opts, :person_mod)
    opportunity_mod = Keyword.fetch!(opts, :opportunity_mod)

    Ash.Changeset.after_action(changeset, fn changeset, lead ->
      convert(changeset, lead, person_mod, opportunity_mod)
    end)
  end

  defp convert(changeset, lead, person_mod, opportunity_mod) do
    repo = AshPostgres.DataLayer.Info.repo(lead.__struct__, :mutate)
    company_id = Ash.Changeset.get_argument(changeset, :company_id)
    # Neither the non-PII fields NOR the vault-routed PII fields (PII columns are
    # NOT select-by-default, mirroring every other 🔒 field — e.g.
    # `Samen.LocationsScopeTest.with_address_loaded/2`) are guaranteed loaded on
    # the after_action struct for an `accept([])` update. `Ash.load!` force-fetches
    # them generically (works regardless of the host's storage column names).
    lead =
      Ash.load!(lead, [:org_id, :value, :company_name, :full_name, :emails, :phones],
        authorize?: false
      )

    org_id = lead.org_id

    with {:ok, full_name} <- reveal_composite(lead.full_name, Samen.Type.FullName, repo, lead.id),
         {:ok, emails} <- reveal_composite(lead.emails, Samen.Type.Emails, repo, lead.id),
         {:ok, phones} <- reveal_composite(lead.phones, Samen.Type.Phones, repo, lead.id),
         {:ok, person} <-
           create_person(person_mod, lead, org_id, full_name, emails, phones, company_id),
         {:ok, opportunity} <- create_opportunity(opportunity_mod, lead, org_id, company_id),
         {:ok, converted} <- link(lead, person, opportunity) do
      {:ok, converted}
    end
  end

  # ── PII reveal (the single chokepoint, INV-1) ──────────────────────────────

  defp reveal_composite(nil, _type, _repo, _subject_id), do: {:ok, nil}

  defp reveal_composite(%Masked{} = masked, type, repo, subject_id) do
    case Vault.reveal(masked, repo, subject_id: subject_id) do
      {:ok, plaintext} ->
        with {:ok, decoded} <- Jason.decode(plaintext),
             {:ok, value} <- cast(type, decoded) do
          {:ok, value}
        else
          {:error, %Jason.DecodeError{}} -> {:error, :decode_failed}
          other -> other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fail-honest (never silently drop PII): the ONLY legal shapes at this point
  # are `nil` (never set) or `%Masked{}` (loaded and vault-routed). Anything
  # else — most likely an `%Ash.NotLoaded{}` a caller forgot to `Ash.load!` — is
  # a bug that must be surfaced loudly, never treated as "no value to reveal".
  defp reveal_composite(other, _type, _repo, _subject_id), do: {:error, {:unexpected_pii_shape, other}}

  defp cast(type, decoded) do
    case type.cast_input(decoded, []) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :cast_failed}
    end
  end

  # ── cross-resource creates (fresh vault tokens minted on THEIR OWN write) ──

  defp create_person(person_mod, lead, org_id, full_name, emails, phones, company_id) do
    attrs =
      %{
        full_name: full_name,
        emails: emails,
        phones: phones,
        display_name: display_name(full_name, lead),
        org_id: org_id
      }
      |> maybe_put(:company_id, company_id)

    person_mod
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp create_opportunity(opportunity_mod, lead, org_id, company_id) do
    attrs =
      %{
        name: opportunity_name(lead),
        value: lead.value,
        org_id: org_id
      }
      |> maybe_put(:company_id, company_id)

    opportunity_mod
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp link(lead, person, opportunity) do
    lead
    |> Ash.Changeset.for_update(
      :update,
      %{converted_person_id: person.id, converted_opportunity_id: opportunity.id},
      authorize?: false
    )
    |> Ash.update(authorize?: false)
  end

  defp display_name(%Samen.Type.FullName{first: first, last: last}, _lead) do
    case [first, last] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ") do
      "" -> "Converted lead"
      name -> name
    end
  end

  defp display_name(_full_name, lead), do: lead.company_name || "Converted lead"

  defp opportunity_name(lead), do: "#{lead.company_name || "Lead"} opportunity"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
