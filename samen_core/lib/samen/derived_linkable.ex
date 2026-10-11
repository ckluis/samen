defmodule Samen.DerivedLinkable do
  @moduledoc """
  The **derived-linkable marker registry** (ADR-046 §6 (a); introduced with the E5
  `email_bidx` arm) — the explicit catalog of columns whose value is a keyed function
  of a subject's PII (a blind index / keyed-HMAC), so they live OUTSIDE the
  per-subject-DEK envelope and crypto-shred cannot reach them.

  ## Why a marker registry (and not just a name heuristic)

  A blind-index column (`email_bidx = Base.encode16(HMAC-SHA256(k_bidx, email))`) is a
  plain `:string` column — nothing STRUCTURAL distinguishes it from any other string.
  Left un-erased it keeps an **equality oracle** over the enumerable input space alive
  for a shredded subject forever (HMAC a candidate value, compare to the stored index).
  The `email_bidx` residue slipped past every existing gate precisely because
  `schema.dict.json` grandfathers pre-existing columns.

  So this module is the authoritative answer to "which columns are derived-linkable?"
  Each entry maps the derived-linkable **logical attribute name** to the **logical subject
  attribute** whose PHYSICAL column owns the index row — the column the blind-index erasure
  arm (`Samen.Auth.BlindIndexErasure`) matches on so it fires ONLY on erasure of the OWNING
  principal (never a per-tenant data-subject shred; ADR-035 §4.1 amendment):

    * `email_bidx`   → `:id`            — Credential/Invitation own their index row
      (the row's own pk IS its vault subject), so the arm matches `<abbrev>_id == subject_id`.
    * `sent_to_bidx` → `:credential_id` — an `AuthToken` is org-less and belongs_to a
      Credential; its owning principal is that credential, so the arm matches
      `<abbrev>_credential_id == subject_id` (a principal-account erasure of the credential).

  `discover/1` resolves each logical subject attribute to its PHYSICAL, abbrev-prefixed
  column (`<abbrev>_id` / `<abbrev>_credential_id`) per-resource, since the arm's SQL
  interpolates a physical identifier.

  A NEW blind index MUST be added here (that is the registration ADR-046 §6 requires),
  or it will be caught anyway by the structural `_bidx` backstop (`structural?/1`) —
  `Samen.Erasure.Completeness` discovers every `_bidx`-suffixed column from the LIVE
  schema and FAILS the gate on any that is not registered here AND covered by a
  `blind_index_erasure_spec`. "Pre-existing" confers no exemption (unlike schema.dict).

  This registry is the framework-first analogue of `Samen.Jobs.default_queue_config/0`:
  a single source of truth the completeness gate reads, and the seam
  `Samen.Erasure.install_default_specs/1` derives the runtime erasure specs from — so a
  fresh `gen.app` is erasure-complete for this class by construction.
  """

  # derived-linkable logical name (string) => the owning-principal's LOGICAL subject attr.
  @registry %{
    "email_bidx" => :id,
    "sent_to_bidx" => :credential_id
  }

  @doc "The canonical derived-linkable registry: `logical_name => logical_subject_attr`."
  @spec registry() :: %{String.t() => atom()}
  def registry, do: @registry

  @doc "The registered derived-linkable logical column names."
  @spec registered_names() :: [String.t()]
  def registered_names, do: Map.keys(@registry)

  @doc "Is `name` an explicitly-registered derived-linkable column?"
  @spec registered?(atom() | String.t()) :: boolean()
  def registered?(name), do: Map.has_key?(@registry, to_string(name))

  @doc "The owning-principal LOGICAL subject attribute for a registered column, or `nil`."
  @spec subject_attr(atom() | String.t()) :: atom() | nil
  def subject_attr(name), do: Map.get(@registry, to_string(name))

  @doc """
  The structural signature of a blind index — the `_bidx` suffix the
  `Samen.Auth.BlindIndex` convention produces. Backstop discovery so a NEW `_bidx`
  column is found even before it is registered (the gate then FAILS it as unregistered
  until it is added to `@registry`, which is the whole point).
  """
  @spec structural?(atom() | String.t()) :: boolean()
  def structural?(name), do: String.ends_with?(to_string(name), "_bidx")

  @doc """
  Discover derived-linkable columns across `resources` from the LIVE Ash schema.

  A column is discovered when it is a `:string` attribute that is either registered
  (`registered?/1`) OR structurally a blind index (`structural?/1`). Returns a list of
  descriptors:

      %{
        resource:       module(),
        table:          String.t(),   # physical (abbrev-prefixed) table
        column:         String.t(),   # physical column (attr.source || attr.name)
        logical:        atom(),        # logical attribute name
        registered?:    boolean(),     # in @registry?
        subject_column: String.t() | nil  # PHYSICAL owning-principal key (nil if unregistered/unresolvable)
      }
  """
  @spec discover([module()]) :: [map()]
  def discover(resources) do
    for resource <- resources,
        attr <- string_attributes(resource),
        registered?(attr.name) or structural?(attr.name) do
      %{
        resource: resource,
        table: table(resource),
        column: to_string(attr.source || attr.name),
        logical: attr.name,
        registered?: registered?(attr.name),
        subject_column: physical_subject_column(resource, attr.name)
      }
    end
  end

  # Resolve the registered LOGICAL subject attribute to its PHYSICAL (abbrev-prefixed)
  # column on this resource — the identifier the arm's SQL interpolates.
  defp physical_subject_column(resource, logical_name) do
    with subject_logical when subject_logical != nil <- subject_attr(logical_name),
         %{} = subject_attr <- Ash.Resource.Info.attribute(resource, subject_logical) do
      to_string(subject_attr.source || subject_attr.name)
    else
      _ -> nil
    end
  end

  defp string_attributes(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr ->
      attr.type in [:string, :ci_string, Ash.Type.String, Ash.Type.CiString]
    end)
  rescue
    _ -> []
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)
end
