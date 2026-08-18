defmodule PawChartWeb.ClinicReads do
  @moduledoc """
  The read/write layer for the PawChart **Clinic** tenant surface (`/clinic`) — the
  vertical 20% (PP-4). It SURFACES the EXISTING vertical-authored resources
  `PawChart.Clinic.Patient` (the human OWNER) and `PawChart.Clinic.Pet` (the animal /
  clinical record) in the clinic's OWN tenant UI; it re-defines no domain model and
  re-implements no substrate. Sibling of `Driftwood.Reads` (the freight vertical's
  read layer) — the SAME "read through Ash with a scope, then resolve PII on the actor's
  plane" seam, on the vet vertical.

  ## Org-scope (every read narrows to the actor's org — the isolation boundary)

  Every read runs through Ash with `scope: scope`, so `Samen.Policy.OrgScope` (the
  resources' own read policy, inherited unchanged) narrows to the actor's org BY
  CONSTRUCTION — a clinic sees ONLY its own patients/pets. Proven refutably by the
  cross-org red-path in `clinic_surface_test.exs` (clinic B's owner/pet is NEVER visible
  to clinic A; the same org IS — the positive control) + sabotage patch 181 (dropping
  `scope:` for `authorize?: false` flips it). Writes ride the same org-scoped actor: a
  cross-org owner→pet FK is refused by `Samen.Policy.SameOrgFk`, and a create always uses
  the socket's own `org_id`.

  ## Per-plane masking (this surface RENDERS vault-routed 🔒 fields)

  `Patient` composes `Samen.Fragments.CorePerson` — its `full_name` / `emails` / `phones`
  are vault-routed (🔒), and `Pet` carries the scalar vault field `pii_pet_microchip`
  (🔒). Every read therefore resolves through `Samen.Api.PiiResolution.resolve/4` on the
  actor's plane — the SAME chokepoint the operator impersonation console and every
  framework read surface use. On the `:tenant` plane (clinic staff over their OWN org)
  the fields resolve CLEAR (the clinic owns its patients' PII, no reveal grant needed);
  on the `:operator`-without-grant plane the SAME read keeps them `%Samen.Masked{}` (••••),
  never plaintext, never a `vt_*` token. There is ONE read path, so there is no separate
  "operator read" that could leak. Proven by the three `Samen.MaskingCase` proofs in
  `clinic_masking_test.exs` + sabotage patch 182 (forcing the resolver to the tenant plane
  regardless of actor → the operator plane leaks → flips).
  """

  require Ash.Query

  alias PawChart.Clinic.{Patient, Pet}

  # A3 read-bounding: every read on this surface carries an explicit hard cap.
  @limit 200

  @doc """
  The tenant-plane read/write scope for a clinic `org_id` — `plane: :tenant`, so the
  clinic resolves its OWN patients'/pets' vault fields CLEAR (no reveal grant needed).
  Mirrors `Driftwood.Reads`' `broker_scope/1`. `OrgScope` keys only on `org_id`, so the
  plane never affects isolation.
  """
  @spec tenant_scope(binary()) :: Samen.Scope.t()
  def tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "clinic:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  # ---------------------------------------------------------------------------
  # Reads — org-scoped by construction (Ash `scope: scope` ⇒ OrgScope narrows),
  # PII-resolved on the actor's plane (`Samen.Api.PiiResolution`).
  # ---------------------------------------------------------------------------

  @doc """
  This clinic's PATIENTS (the pet OWNERS), newest first, org-scoped + bounded. Vault
  fields resolve on the scope's plane (tenant CLEAR, operator-without-grant `%Masked{}`).
  `[]` on any failure — an honest absence, never a fabricated row.
  """
  @spec owner_roster(term()) :: [struct()]
  def owner_roster(scope) do
    Patient
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :marketing_opt_in, :inserted_at])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(Patient, scope)
  rescue
    _ -> []
  end

  @doc """
  Fetch ONE patient (owner) by id for `scope`, PII-resolved on the same plane. The fetch
  is ORG-SCOPED, so a cross-org id (including one supplied via a `?patient=` param or a
  crafted `handle_event`) is INVISIBLE under OrgScope and yields `:error` (never a
  cross-org read). `{:ok, owner}` or `:error`.
  """
  @spec get_owner(term(), binary()) :: {:ok, struct()} | :error
  def get_owner(scope, id) when is_binary(id) do
    Patient
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :marketing_opt_in])
    |> Ash.Query.limit(1)
    |> Ash.read!(scope: scope)
    |> resolve_pii(Patient, scope)
    |> case do
      [owner | _] -> {:ok, owner}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def get_owner(_scope, _id), do: :error

  @doc """
  This clinic's PETS (the clinical records), newest first, org-scoped + bounded. The
  scalar vault field `microchip` resolves on the scope's plane. `[]` on any failure.
  """
  @spec pet_roster(term()) :: [struct()]
  def pet_roster(scope) do
    Pet
    |> Ash.Query.ensure_selected([
      :name,
      :species,
      :breed,
      :weight_kg,
      :temperament,
      :microchip,
      :owner_id,
      :inserted_at
    ])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(Pet, scope)
  rescue
    _ -> []
  end

  @doc "The pets belonging to `owner_id` (from this org's already-org-scoped, resolved roster)."
  @spec pets_for_owner(term(), binary()) :: [struct()]
  def pets_for_owner(scope, owner_id) when is_binary(owner_id) do
    scope |> pet_roster() |> Enum.filter(&(&1.owner_id == owner_id))
  end

  def pets_for_owner(_scope, _owner_id), do: []

  # ---------------------------------------------------------------------------
  # Writes — the resources' REAL :create/:update actions on the tenant scope
  # (OrgScope-confined; a cross-org owner→pet FK is refused by SameOrgFk).
  # ---------------------------------------------------------------------------

  @doc """
  Create ONE patient (owner) for `org_id` from the raw form params via `Patient`'s real
  `:create` action on the tenant scope. `{:ok, patient}` or `{:error, changeset | term}`.
  """
  @spec create_owner(binary(), map()) :: {:ok, struct()} | {:error, term()}
  def create_owner(org_id, params) when is_binary(org_id) and is_map(params) do
    scope = tenant_scope(org_id)

    Patient
    |> Ash.Changeset.for_create(:create, owner_attrs(params, org_id), scope: scope)
    |> Ash.create(scope: scope)
  rescue
    e -> {:error, e}
  end

  @doc """
  Update ONE patient's editable fields via `Patient`'s real `:update` action on the
  tenant scope. The fetch is ORG-SCOPED, so a cross-org id is genuinely `:not_found`
  (OrgScope makes it not-exist for this actor) — never a cross-org update. `{:ok, patient}`
  or `{:error, :not_found | changeset | term}`.
  """
  @spec update_owner(binary(), binary(), map()) :: {:ok, struct()} | {:error, term()}
  def update_owner(org_id, id, params) when is_binary(org_id) and is_binary(id) and is_map(params) do
    scope = tenant_scope(org_id)

    case fetch(Patient, scope, id) do
      nil ->
        {:error, :not_found}

      owner ->
        owner
        |> Ash.Changeset.for_update(:update, owner_attrs(params, org_id), scope: scope)
        |> Ash.update(scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Create ONE pet for `org_id` via `Pet`'s real `:create` action on the tenant scope. A
  cross-org `owner_id` is REFUSED by `Samen.Policy.SameOrgFk`. `{:ok, pet}` or `{:error, _}`.
  """
  @spec create_pet(binary(), map()) :: {:ok, struct()} | {:error, term()}
  def create_pet(org_id, params) when is_binary(org_id) and is_map(params) do
    scope = tenant_scope(org_id)

    Pet
    |> Ash.Changeset.for_create(:create, pet_attrs(params, org_id), scope: scope)
    |> Ash.create(scope: scope)
  rescue
    e -> {:error, e}
  end

  @doc """
  Update ONE pet via `Pet`'s real `:update` action on the tenant scope. Org-scoped fetch
  (a cross-org id is `:not_found`). `{:ok, pet}` or `{:error, :not_found | term}`.
  """
  @spec update_pet(binary(), binary(), map()) :: {:ok, struct()} | {:error, term()}
  def update_pet(org_id, id, params) when is_binary(org_id) and is_binary(id) and is_map(params) do
    scope = tenant_scope(org_id)

    case fetch(Pet, scope, id) do
      nil ->
        {:error, :not_found}

      pet ->
        pet
        |> Ash.Changeset.for_update(:update, pet_attrs(params, org_id), scope: scope)
        |> Ash.update(scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # PII resolution — the two-key-classes seam, keyed on the scope's actor plane.
  # (Mirrors Driftwood.Reads.resolve_pii/2.) A resolver failure MUST NOT downgrade
  # to plaintext: the read already produced %Masked{}, so return records untouched.
  # ---------------------------------------------------------------------------

  defp resolve_pii(records, resource, scope) do
    Samen.Api.PiiResolution.resolve(records, resource, actor_of(scope), repo: PawChart.Repo)
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  # ---------------------------------------------------------------------------
  # Attr builders + helpers (org-scoped fetch; blank normalization)
  # ---------------------------------------------------------------------------

  defp fetch(resource, scope, id) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(scope: scope)
  rescue
    _ -> nil
  end

  defp owner_attrs(params, org_id) do
    %{
      org_id: org_id,
      full_name: %{first: str(params["first"]), last: str(params["last"])},
      emails: list_of(params["email"]),
      phones: list_of(params["phone"]),
      marketing_opt_in: truthy(params["marketing_opt_in"])
    }
  end

  @temperaments ~w(docile anxious aggressive unknown)

  defp pet_attrs(params, org_id) do
    %{
      org_id: org_id,
      name: str(params["name"]),
      species: str(params["species"]),
      breed: blank_to_nil(params["breed"]),
      weight_kg: blank_to_nil(params["weight_kg"]),
      temperament: temperament(params["temperament"]),
      microchip: blank_to_nil(params["microchip"]),
      owner_id: blank_to_nil(params["owner_id"])
    }
  end

  defp temperament(v) when is_binary(v) do
    if v in @temperaments, do: String.to_existing_atom(v), else: :unknown
  end

  defp temperament(_), do: :unknown

  defp str(v) when is_binary(v), do: String.trim(v)
  defp str(_), do: ""

  defp blank_to_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp list_of(v) do
    case blank_to_nil(v) do
      nil -> []
      trimmed -> [trimmed]
    end
  end

  defp truthy(v), do: v in [true, "true", "on", "1"]
end
