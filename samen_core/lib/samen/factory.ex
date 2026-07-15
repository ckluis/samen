defmodule Samen.Factory do
  @moduledoc """
  Vault-aware fixture/factory create helpers (WS-D D1.2; ADR-022; AC-G4-5) — the
  builder-facing module seeds and test fixtures write through, so seeded PII takes
  the SAME vault path as a real tenant write.

  ## The idiom this extracts (and must match EXACTLY)

  The shipped seed idiom is `Samen.Web.SampleData` (WS-A A5,
  `samen_web/lib/samen/web/sample_data.ex`): synthetic PII is passed as ordinary
  attrs (`full_name: %Samen.Type.FullName{…}`, `emails: [%{label:, address:}]`)
  to `Ash.Changeset.for_create/4` on the REAL create action, which routes every
  declared `pii_attribute` through the `Samen.Vault.Change` chokepoint — the
  domain column holds a `vt_*` token, `pii_vault` holds the ciphertext, and a
  raw-SQL scan of the row finds NO plaintext. No subject-key or reveal
  boilerplate. `Samen.Factory.create!/3` is that idiom as a function:

      Samen.Factory.create!(
        MyApp.Crm.Person,
        Map.merge(
          %{org_id: org_id, display_name: "Aster Vale", job_title: "Ops"},
          Samen.Factory.person("Aster", "Vale",
            email: "aster.vale@sample.invalid",
            phone: "+1 555 0101"
          )
        ),
        authorize?: false
      )

  The third argument is either a `%Samen.Scope{}` (threaded as `scope:`, exactly
  as `SampleData` passes `Mount.scope/2`) or a keyword list passed through to
  `Ash.Changeset.for_create/4` (`authorize?: false` / `actor:` — the reference
  verticals' `Seeds` idiom; a nil-plane internal write is NOT an operator, see
  `Samen.Pii.WriteGuard`). `action:` selects a non-default create action.

  ## Red paths (a factory write can NEVER land plaintext PII in a physical column)

    * **Physical vault column refused, by name** — attrs keyed by a vault-routed
      field's *storage* column (`pii_pat_mrn`, `pat_full_name`, …) raise
      `ArgumentError` naming the logical field to use instead, BEFORE any
      changeset is built (DB untouched). Bypassing the vault by writing the
      token column directly is impossible through the factory. (Belt — the
      braces: Ash itself rejects a storage-name key as `NoSuchInput`, since
      only logical attribute names are accepted inputs.)
    * **Operator-plane plaintext refused** — the factory adds NO privilege: a
      `%Samen.Scope{}` whose actor is `plane: :operator` writing plaintext PII
      is refused by `Samen.Pii.WriteGuard` at the Ash write path (MC-1 /
      Invariant L1), DB unchanged. The factory goes through the guarded create
      action, so every write-path invariant holds for seeded data too.

  ## `person/3` — the composite-PII attrs builder

  Builds exactly the `SampleData`/`Seeds` person-PII attrs shape (only the keys
  you ask for — an absent email/phone stays absent, it is never written as an
  empty composite):

      Samen.Factory.person("Aster", "Vale")
      #=> %{full_name: %Samen.Type.FullName{first: "Aster", last: "Vale"}}

      Samen.Factory.person("Aster", "Vale", email: "a@x.invalid", phone: "+1 555", phone_label: "direct")
      #=> %{full_name: …,
      #     emails: [%{label: "work", address: "a@x.invalid"}],
      #     phones: [%{label: "direct", number: "+1 555"}]}

  Options: `:email`/`:email_label` (default `"work"`), `:phone`/`:phone_label`
  (default `"mobile"`), or full `:emails`/`:phones` entry lists verbatim.
  """

  alias Samen.Pii

  @doc """
  Create a record through the resource's REAL Ash create action — the vault-aware
  seed write (AC-G4-5: byte-identical vault path to `Samen.Web.SampleData`).

  `scope_or_opts` is a `%Samen.Scope{}` (threaded as `scope:`) or a keyword list
  forwarded to `Ash.Changeset.for_create/4` (plus `:action`, default `:create`).

  Raises `ArgumentError` if any attrs key names a vault-routed field's PHYSICAL
  storage column instead of its logical field (fail loud, DB untouched).
  """
  @spec create!(module(), map(), Samen.Scope.t() | keyword()) :: Ash.Resource.record()
  def create!(resource, attrs, scope_or_opts \\ [])

  def create!(resource, attrs, %Samen.Scope{} = scope) when is_map(attrs),
    do: do_create!(resource, attrs, scope: scope)

  def create!(resource, attrs, opts) when is_map(attrs) and is_list(opts),
    do: do_create!(resource, attrs, opts)

  defp do_create!(resource, attrs, opts) do
    refuse_physical_vault_columns!(resource, attrs)
    {action, opts} = Keyword.pop(opts, :action, :create)

    resource
    |> Ash.Changeset.for_create(action, attrs, opts)
    |> Ash.create!()
  end

  @doc """
  The person-PII attrs (`full_name` + optional `emails`/`phones`) in the shipped
  composite shape — merge into the resource-specific attrs map. See moduledoc.
  """
  @spec person(String.t(), String.t(), keyword()) :: map()
  def person(first, last, opts \\ [])
      when is_binary(first) and is_binary(last) and is_list(opts) do
    %{full_name: %Samen.Type.FullName{first: first, last: last}}
    |> put_composite(:emails, email_entries(opts))
    |> put_composite(:phones, phone_entries(opts))
  end

  defp email_entries(opts) do
    cond do
      entries = Keyword.get(opts, :emails) ->
        entries

      address = Keyword.get(opts, :email) ->
        [%{label: Keyword.get(opts, :email_label, "work"), address: address}]

      true ->
        nil
    end
  end

  defp phone_entries(opts) do
    cond do
      entries = Keyword.get(opts, :phones) ->
        entries

      number = Keyword.get(opts, :phone) ->
        [%{label: Keyword.get(opts, :phone_label, "mobile"), number: number}]

      true ->
        nil
    end
  end

  defp put_composite(attrs, _key, nil), do: attrs
  defp put_composite(attrs, key, entries), do: Map.put(attrs, key, entries)

  # ---------------------------------------------------------------------------
  # Red path: a physical vault column as an attrs key is refused BY NAME.
  # ---------------------------------------------------------------------------

  defp refuse_physical_vault_columns!(resource, attrs) do
    case Pii.Info.fields(resource) do
      [] ->
        :ok

      fields ->
        by_storage =
          Map.new(fields, fn field -> {to_string(field.storage_name), field.name} end)

        Enum.each(attrs, fn {key, _value} ->
          key_string = to_string(key)

          case Map.fetch(by_storage, key_string) do
            # Storage names are always abbrev-/pii_-prefixed, so a hit on a key that
            # is NOT the logical name itself is a physical-column write attempt.
            {:ok, logical} ->
              if key_string != Atom.to_string(logical) do
                raise ArgumentError,
                      "Samen.Factory.create!/3: #{inspect(key)} is the PHYSICAL storage " <>
                        "column of the vault-routed field #{inspect(logical)} on " <>
                        "#{inspect(resource)}. Writing a physical vault column directly " <>
                        "would bypass the Samen.Vault.Change chokepoint (plaintext or a " <>
                        "forged token at rest) — refused before any write. Pass the " <>
                        "logical field #{inspect(logical)} instead; the create action " <>
                        "vault-routes it."
              end

            :error ->
              :ok
          end
        end)
    end
  end
end
