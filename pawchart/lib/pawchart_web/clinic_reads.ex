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
  alias Samen.Web.Reads.Guard

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
  `[]` for ANY failure (legacy shape) — a screen uses `owner_roster_result/1`, which tells a failed
  read from an honestly empty clinic.
  """
  @spec owner_roster(term()) :: [struct()]
  def owner_roster(scope), do: scope |> owner_roster_result() |> Guard.value([])

  @doc """
  The tagged sibling of `owner_roster/1` (WP6 phase 4): `{:ok, owners}` (`{:ok, []}` is an HONEST
  empty clinic), `{:error, :unavailable}` (the read raised: outage, decrypt failure, bug — reported by
  name and exception module) or `{:error, :forbidden}` (a denial).
  """
  @spec owner_roster_result(term()) :: Guard.result([struct()])
  def owner_roster_result(scope) do
    Guard.run(:pawchart_owner_roster, scope, fn ->
      Patient
      |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :marketing_opt_in, :inserted_at])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@limit)
      |> Ash.read!(scope: scope)
      |> resolve_pii(Patient, scope)
    end)
  end

  @doc """
  Fetch ONE patient (owner) by id for `scope`, PII-resolved on the same plane. The fetch
  is ORG-SCOPED, so a cross-org id (including one supplied via a `?patient=` param or a
  crafted `handle_event`) is INVISIBLE under OrgScope and yields `:error` (never a
  cross-org read). `{:ok, owner}` or `:error` (legacy shape: not found AND failure).
  """
  @spec get_owner(term(), binary()) :: {:ok, struct()} | :error
  def get_owner(scope, id) do
    case get_owner_result(scope, id) do
      {:ok, owner} -> {:ok, owner}
      {:error, _kind} -> :error
    end
  end

  @doc """
  The tagged sibling of `get_owner/2`: `{:ok, owner}`, `{:error, :not_found}` (no such patient in this
  clinic, including a cross-org or MALFORMED id — the id is cast before it reaches a query, so a bad id is
  a plain not-found with no error log), `{:error, :unavailable}` (the read failed: an outage is NOT "not
  found") or `{:error, :forbidden}`.
  """
  @spec get_owner_result(term(), term()) :: {:ok, struct()} | {:error, :not_found | :unavailable | :forbidden}
  def get_owner_result(scope, id) do
    with {:ok, id} <- cast_id(id),
         {:ok, rows} <-
           Guard.run(:pawchart_get_owner, scope, fn ->
             Patient
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :marketing_opt_in])
             |> Ash.Query.limit(1)
             |> Ash.read!(scope: scope)
             |> resolve_pii(Patient, scope)
           end) do
      first_or_not_found(rows)
    end
  end

  @doc """
  This clinic's PETS (the clinical records), newest first, org-scoped + bounded. The
  scalar vault field `microchip` resolves on the scope's plane. `[]` for any failure (legacy shape);
  see `pet_roster_result/1`.
  """
  @spec pet_roster(term()) :: [struct()]
  def pet_roster(scope), do: scope |> pet_roster_result() |> Guard.value([])

  @doc "The tagged sibling of `pet_roster/1` — same contract as `owner_roster_result/1`."
  @spec pet_roster_result(term()) :: Guard.result([struct()])
  def pet_roster_result(scope) do
    Guard.run(:pawchart_pet_roster, scope, fn ->
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
    end)
  end

  @doc "The pets belonging to `owner_id` (from this org's already-org-scoped, resolved roster)."
  @spec pets_for_owner(term(), binary()) :: [struct()]
  def pets_for_owner(scope, owner_id), do: scope |> pets_for_owner_result(owner_id) |> Guard.value([])

  @doc "The tagged sibling of `pets_for_owner/2`: `{:ok, pets}` or `{:error, :unavailable | :forbidden}`."
  @spec pets_for_owner_result(term(), term()) :: Guard.result([struct()])
  def pets_for_owner_result(scope, owner_id) when is_binary(owner_id) do
    with {:ok, pets} <- pet_roster_result(scope), do: {:ok, Enum.filter(pets, &(&1.owner_id == owner_id))}
  end

  def pets_for_owner_result(_scope, _owner_id), do: {:ok, []}

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

    # WP6 phase 4: `Guard.write/3` — a raise or a RETURNED `Ash.Error.Unknown` is `{:error, :unavailable}`
    # (reported by name), a real refusal (`Invalid`) passes through untouched, so the screen can tell a
    # missing name from an outage.
    Guard.write(:pawchart_create_owner, scope, fn ->
      Patient
      |> Ash.Changeset.for_create(:create, owner_attrs(params, org_id), scope: scope)
      |> Ash.create(scope: scope)
    end)
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

    # Both reads must SUCCEED before anything is written: the form edits only the FIRST email/phone and
    # merges it into the stored lists (F06), so a failed read of the stored lists must never degrade into
    # "no stored lists" (that would overwrite the owner's other emails/phones with just the one typed).
    with {:ok, id} <- cast_id(id),
         {:ok, owner} <- fetch_result(Patient, scope, id, :pawchart_fetch_owner),
         {:ok, existing} <- get_owner_result(scope, id) do
      Guard.write(:pawchart_update_owner, scope, fn ->
        owner
        |> Ash.Changeset.for_update(:update, owner_attrs(params, org_id, existing), scope: scope)
        |> Ash.update(scope: scope)
      end)
    end
  end

  @doc """
  Create ONE pet for `org_id` via `Pet`'s real `:create` action on the tenant scope. A
  cross-org `owner_id` is REFUSED by `Samen.Policy.SameOrgFk`. `{:ok, pet}` or `{:error, _}`.
  """
  @spec create_pet(binary(), map()) :: {:ok, struct()} | {:error, term()}
  def create_pet(org_id, params) when is_binary(org_id) and is_map(params) do
    scope = tenant_scope(org_id)

    Guard.write(:pawchart_create_pet, scope, fn ->
      Pet
      |> Ash.Changeset.for_create(:create, pet_attrs(params, org_id), scope: scope)
      |> Ash.create(scope: scope)
    end)
  end

  @doc """
  Update ONE pet via `Pet`'s real `:update` action on the tenant scope. Org-scoped fetch
  (a cross-org id is `:not_found`). `{:ok, pet}` or `{:error, :not_found | term}`.
  """
  @spec update_pet(binary(), binary(), map()) :: {:ok, struct()} | {:error, term()}
  def update_pet(org_id, id, params) when is_binary(org_id) and is_binary(id) and is_map(params) do
    scope = tenant_scope(org_id)

    with {:ok, id} <- cast_id(id),
         {:ok, pet} <- fetch_result(Pet, scope, id, :pawchart_fetch_pet) do
      Guard.write(:pawchart_update_pet, scope, fn ->
        pet
        |> Ash.Changeset.for_update(:update, pet_attrs(params, org_id), scope: scope)
        |> Ash.update(scope: scope)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # PII resolution — the two-key-classes seam, keyed on the scope's actor plane.
  # (Mirrors Driftwood.Reads.resolve_pii/2.) A resolver failure MUST NOT downgrade
  # to plaintext: the read already produced %Masked{}, so return records untouched.
  # ---------------------------------------------------------------------------

  defp resolve_pii(records, resource, scope) do
    Samen.Api.PiiResolution.resolve(records, resource, actor_of(scope), repo: PawChart.Repo)
  rescue
    e ->
      # Fail-CLOSED, not silent: the records stay masked, and the failure is reported by name and
      # exception module (Guard.report/3) instead of vanishing.
      Guard.report(:pawchart_resolve_pii, scope, e)
      records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  # ---------------------------------------------------------------------------
  # Attr builders + helpers (org-scoped fetch; blank normalization)
  # ---------------------------------------------------------------------------

  # The raw org-scoped row for a write: `{:ok, row}`, `{:error, :not_found}` (also a cross-org id) or
  # `{:error, :unavailable | :forbidden}` — an outage is never "not found".
  defp fetch_result(resource, scope, id, name) do
    with {:ok, row} <-
           Guard.run(name, scope, fn ->
             resource
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.limit(1)
             |> Ash.read_one!(scope: scope)
           end) do
      first_or_not_found(List.wrap(row))
    end
  end

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_), do: {:error, :not_found}

  defp first_or_not_found([row | _]), do: {:ok, row}
  defp first_or_not_found(_), do: {:error, :not_found}

  # `existing` is nil on create (the form value IS the list) and the plane-resolved patient on
  # update (the form value replaces the first entry, the tail is kept). When the stored list is
  # unreadable (masked / not decodable) the field is left OUT of the changeset, never clobbered.
  defp owner_attrs(params, org_id, existing \\ nil) do
    base = %{
      org_id: org_id,
      full_name: %{first: str(params["first"]), last: str(params["last"])},
      marketing_opt_in: truthy(params["marketing_opt_in"])
    }

    base
    |> put_contact_list(:emails, params["email"], existing)
    |> put_contact_list(:phones, params["phone"], existing)
  end

  defp put_contact_list(attrs, key, value, nil), do: Map.put(attrs, key, list_of(value))

  defp put_contact_list(attrs, key, value, existing) do
    case stored_list(Map.get(existing, key)) do
      {:ok, stored} -> Map.put(attrs, key, replace_first(stored, blank_to_nil(value)))
      :unreadable -> attrs
    end
  end

  defp stored_list(list) when is_list(list), do: {:ok, list}
  defp stored_list(nil), do: {:ok, []}

  defp stored_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :unreadable
    end
  end

  defp stored_list(_), do: :unreadable

  defp replace_first([], nil), do: []
  defp replace_first([], new), do: [new]
  defp replace_first([_ | tail], nil), do: tail
  defp replace_first([%{"address" => _} = h | tail], new), do: [%{h | "address" => new} | tail]
  defp replace_first([%{"number" => _} = h | tail], new), do: [%{h | "number" => new} | tail]
  defp replace_first([_ | tail], new), do: [new | tail]

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
