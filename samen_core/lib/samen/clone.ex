defmodule Samen.Clone do
  @moduledoc """
  Generic, framework-level **duplicate/clone** for any Samen resource (spec G9,
  semantics c14). One reusable function copies a record to a NEW, genuinely
  INDEPENDENT record — adoptable by any resource at ~0 authored LOC.

  ## The vault guarantee — re-tokenization, never token-sharing (the crux)

  For every VAULT-ROUTED (🔒) field, the clone gets its OWN FRESH vault entry /
  `vt_*` token holding the SAME logical value as the source. It is NEVER a copy of
  the source's token or ciphertext. A naive clone that copied the encrypted column
  or the `vt_*` token would ALIAS both records to the same `pii_vault` subject — a
  P0 hazard (crypto-shredding one would destroy the other's PII; the two records
  would be secretly linked).

  **Why independence is structural.** `Samen.Vault.Change` keys the vault on
  `subject_id = the record's own primary key`. A clone is a NEW record with a NEW
  primary key, so the governed create mints a FRESH per-subject DEK and FRESH
  `pii_vault` rows (new tokens, new ciphertext) under the clone's OWN key. Crypto-
  shred destroys a subject's DEK; because clone and source have DISTINCT
  `subject_id`s, shredding/erasing one leaves the other fully resolvable — in BOTH
  directions. The only requirement is that the clone be fed PLAINTEXT (so the
  governed write re-tokenizes) and NEVER the source token.

  ## Governed write path only

  The clone writes through the resource's REAL `:create` action — the same governed
  path a normal create uses (`Samen.Pii.WriteGuard` → `Samen.Vault.Change` →
  `Samen.Type.VaultField`). There is NO raw Ecto/Ash copy of the encrypted column,
  NO direct insert, and NO call to `Samen.Vault.store_fields/4` that would bypass
  the chokepoint. The `VaultField` last-line guard still refuses raw plaintext at
  rest.

  To re-tokenize it needs the source plaintext; it resolves that through the SINGLE
  governed reveal chokepoint `Samen.Api.PiiResolution.resolve/4` on the ACTOR'S
  plane — never a second decrypt path. Consequences (fail-closed):

    * **tenant plane** — owns its org's PII, resolves CLEAR with no grant → clone
      works. The plaintext is used ONLY server-side to feed the create; the clone's
      returned record is fully `%Masked{}` (no plaintext, no `vt_*` in the response).
    * **operator WITHOUT a grant** — the resolve returns `%Masked{}` /
      `%Ash.ForbiddenField{}`; the clone REFUSES with `{:error, {:pii_unresolved,
      field}}`. An actor who cannot READ the PII cannot clone it into plaintext.
    * **operator WITH a grant** — the resolve succeeds, but the re-tokenizing WRITE
      runs on the operator plane and `Samen.Pii.WriteGuard` refuses an operator-plane
      plaintext write; the clone is refused at the write (the transaction rolls back).
      Operators never mint independent PII copies.

  ## Org-scope

  The source is re-read filtered to `org_id == actor.org_id`, and the clone is
  created with the actor's `org_id`. A cross-org clone attempt is refused
  (`{:error, :cross_org}` / `{:error, :source_not_found}`) — org A's record is never
  cloned into org B.

  ## Unique / identity fields + `_copy` suffix

  The display field (auto-detected `:name` / `:display_name` / `:title` / `:label`,
  or `:display_field`) receives the `_copy` suffix (c14). Any OTHER unique-identity
  string attribute is also suffixed so the clone cannot trip a unique constraint;
  non-string unique attributes are dropped for the caller to set. `:overrides` win
  over everything.

  ## Relationships / file attachments (shallow)

  `belongs_to` foreign-key attributes and a `storage_key` reference are ordinary
  attributes copied verbatim: the referenced record / file is RE-LINKED, never
  deep-cloned or re-uploaded. The clone never touches `Samen.Files.upload/3`, so no
  new `storage_key` is minted (the files chokepoint is untouched).

  ## Audit

  The clone rides the resource's real `:create` action, so it is audited exactly
  like any governed create (value-free / token-only for vault fields). It does not
  escape audit.

  ## Usage

      {:ok, copy} = Samen.Clone.clone(person, tenant_scope, repo: MyApp.Repo)
      # copy.display_name == person.display_name <> "_copy"
      # copy's vault tokens DIFFER from person's; both resolve independently.
  """

  require Ash.Query

  alias Samen.Api.PiiResolution
  alias Samen.Masked
  alias Samen.Pii

  @display_candidates [:name, :display_name, :title, :label]
  @never_copy [:inserted_at, :updated_at, :archived_at]
  @default_suffix "_copy"

  @doc """
  Clone `source` (a loaded record) to a new independent record in the actor's org.

  `actor_or_scope` is a `%Samen.Scope{}` or a bare actor map — it MUST carry
  `:org_id` (org-scope) and, for a vault-bearing resource, a `:plane`
  (`:tenant` to resolve + re-tokenize; `:operator` is refused for PII).

  Options:
    * `:repo`          — the Ecto repo backing the vault (defaults to the resource's
      AshPostgres repo, else the configured `:vault_repo`). Required to re-tokenize.
    * `:action`        — the create action to write through (default `:create`).
    * `:grant`         — grant checker module for the reveal (default
      `Samen.Reveal.grant_checker()`).
    * `:display_field` — the field to suffix (default: first present of
      `#{inspect(@display_candidates)}`).
    * `:suffix`        — the display/unique suffix (default `#{inspect(@default_suffix)}`).
    * `:overrides`     — a map of `field => value` to force on the clone (wins over
      copied/suffixed values; use to set unique fields explicitly).

  Returns `{:ok, clone}` or `{:error, reason}`. Reasons include `:cross_org`,
  `:source_not_found`, and `{:pii_unresolved, field}` (actor lacks the plane/grant
  to read a vault field — refused, never aliased).
  """
  @spec clone(Ash.Resource.record(), Samen.Scope.t() | map(), keyword()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def clone(%resource{} = source, actor_or_scope, opts \\ []) do
    actor = actor_of(actor_or_scope)
    repo = repo_for(resource, opts)
    action = Keyword.get(opts, :action, :create)

    with {:ok, loaded} <- reload_org_scoped(resource, source, actor),
         {:ok, vault_inputs} <- resolve_vault_inputs(resource, loaded, actor, repo, opts) do
      attrs =
        loaded
        |> copyable_attrs(resource, action, actor)
        |> apply_suffix(resource, loaded, opts)
        |> Map.merge(vault_inputs)
        |> Map.merge(overrides(opts))

      create(resource, action, attrs, actor_or_scope)
    end
  end

  # ---------------------------------------------------------------------------
  # Source re-read: org-scoped, all attributes selected (vault fields => %Masked{}).
  # ---------------------------------------------------------------------------
  defp reload_org_scoped(resource, %{id: id} = source, actor) do
    selectable = selectable_names(resource)

    query =
      resource
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.ensure_selected(selectable)
      |> scope_to_org(resource, actor)

    case Ash.read(query, authorize?: false) do
      {:ok, [record]} -> {:ok, record}
      {:ok, []} -> {:error, :source_not_found}
      {:ok, [record | _]} -> {:ok, record}
      # A resource with no id (should not happen for a Samen resource) — clone the
      # struct as-is (org guard below still applies).
      {:error, _} -> guard_org(resource, source, actor)
    end
  end

  # Belt over the org-scoped read: even a policy-less resource cannot cross orgs.
  defp scope_to_org(query, resource, actor) do
    if has_attr?(resource, :org_id) do
      org = actor[:org_id]
      Ash.Query.filter(query, org_id == ^org)
    else
      query
    end
  end

  defp guard_org(resource, source, actor) do
    if has_attr?(resource, :org_id) and Map.get(source, :org_id) != actor[:org_id] do
      {:error, :cross_org}
    else
      {:ok, source}
    end
  end

  # ---------------------------------------------------------------------------
  # Re-tokenization inputs: resolve each vault field to plaintext on the actor's
  # plane through the SINGLE governed chokepoint. Refuse (never alias) if unresolved.
  # ---------------------------------------------------------------------------
  defp resolve_vault_inputs(resource, record, actor, repo, opts) do
    case Pii.Info.fields(resource) do
      [] ->
        {:ok, %{}}

      fields ->
        resolve_opts = [repo: repo] |> maybe_put_grant(opts)
        [resolved] = PiiResolution.resolve([record], resource, actor, resolve_opts)
        collect_vault_inputs(fields, resolved)
    end
  end

  defp collect_vault_inputs(fields, resolved) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.get(resolved, field.name) do
        nil ->
          {:cont, {:ok, acc}}

        %Masked{} ->
          {:halt, {:error, {:pii_unresolved, field.name}}}

        %Ash.ForbiddenField{} ->
          {:halt, {:error, {:pii_unresolved, field.name}}}

        plaintext when is_binary(plaintext) ->
          {:cont, {:ok, Map.put(acc, field.name, decode_vault_value(field, plaintext))}}

        # A non-binary/non-masked value (already-typed) — pass through.
        other ->
          {:cont, {:ok, Map.put(acc, field.name, other)}}
      end
    end)
  end

  # A revealed composite value is the stored JSON bytes; decode it back to the
  # structured shape the composite type's `cast_input` accepts (string keys OK).
  # A scalar reveals as its string; the create action's declared-type cast re-parses
  # it (e.g. an ISO date), producing a byte-identical re-vaulted value.
  defp decode_vault_value(%{composite?: true}, plaintext), do: Jason.decode!(plaintext)
  defp decode_vault_value(_field, plaintext), do: plaintext

  # ---------------------------------------------------------------------------
  # Non-vault attribute copy — only what the create action accepts, minus PK,
  # timestamps, archived_at, and the vault fields (re-tokenized separately). org_id
  # is forced to the actor's org.
  # ---------------------------------------------------------------------------
  defp copyable_attrs(record, resource, action, actor) do
    accepted = accepted_inputs(resource, action)
    pks = MapSet.new(Ash.Resource.Info.primary_key(resource))
    vault_names = MapSet.new(Pii.Info.fields(resource), & &1.name)
    excluded = pks |> MapSet.union(MapSet.new(@never_copy)) |> MapSet.union(vault_names)

    base =
      accepted
      |> Enum.reject(&MapSet.member?(excluded, &1))
      |> Enum.reduce(%{}, fn name, acc ->
        case Map.get(record, name) do
          %Ash.NotLoaded{} -> acc
          nil -> acc
          value -> Map.put(acc, name, value)
        end
      end)

    if has_attr?(resource, :org_id) and MapSet.member?(accepted, :org_id) do
      Map.put(base, :org_id, actor[:org_id])
    else
      base
    end
  end

  # ---------------------------------------------------------------------------
  # Display `_copy` suffix + unique-field handling (avoid unique-constraint hits).
  # ---------------------------------------------------------------------------
  defp apply_suffix(attrs, resource, record, opts) do
    suffix = Keyword.get(opts, :suffix, @default_suffix)
    display = display_field(resource, opts)
    unique = unique_attr_names(resource)

    attrs
    |> suffix_display(display, record, suffix)
    |> handle_unique(unique, display, record, suffix)
  end

  defp suffix_display(attrs, nil, _record, _suffix), do: attrs

  defp suffix_display(attrs, display, record, suffix) do
    case Map.get(record, display) do
      value when is_binary(value) -> Map.put(attrs, display, value <> suffix)
      _ -> attrs
    end
  end

  # For every unique-identity attribute OTHER than the display field: suffix a string
  # (so a unique index is not violated), drop a non-string (leave to the caller).
  defp handle_unique(attrs, unique, display, record, suffix) do
    unique
    |> Enum.reject(&(&1 == display))
    |> Enum.reduce(attrs, fn name, acc ->
      case Map.get(record, name) do
        value when is_binary(value) -> Map.put(acc, name, value <> suffix)
        _ -> Map.delete(acc, name)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Governed create.
  # ---------------------------------------------------------------------------
  defp create(resource, action, attrs, %Samen.Scope{} = scope) do
    resource
    |> Ash.Changeset.for_create(action, attrs, scope: scope)
    |> Ash.create()
  end

  defp create(resource, action, attrs, actor) when is_map(actor) do
    resource
    |> Ash.Changeset.for_create(action, attrs, actor: actor)
    |> Ash.create()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  defp actor_of(%Samen.Scope{actor: actor}), do: actor || %{}
  defp actor_of(actor) when is_map(actor), do: actor

  defp repo_for(resource, opts) do
    Keyword.get(opts, :repo) ||
      ash_repo(resource) ||
      Application.get_env(:samen_core, :vault_repo)
  end

  defp ash_repo(resource) do
    AshPostgres.DataLayer.Info.repo(resource, :mutate)
  rescue
    _ -> nil
  end

  defp maybe_put_grant(resolve_opts, opts) do
    case Keyword.get(opts, :grant) do
      nil -> resolve_opts
      grant -> Keyword.put(resolve_opts, :grant, grant)
    end
  end

  defp overrides(opts), do: Keyword.get(opts, :overrides, %{}) |> Map.new()

  defp display_field(resource, opts) do
    case Keyword.get(opts, :display_field) do
      nil -> Enum.find(@display_candidates, &has_attr?(resource, &1))
      field -> field
    end
  end

  defp unique_attr_names(resource) do
    resource
    |> Ash.Resource.Info.identities()
    |> Enum.flat_map(& &1.keys)
    |> Enum.uniq()
  end

  # The create action's accepted input names (`create: :*` expands to the public
  # writable attributes). Copying only accepted names avoids `NoSuchInput`.
  defp accepted_inputs(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{accept: accept} when is_list(accept) -> MapSet.new(accept)
      _ -> MapSet.new()
    end
  end

  # Every attribute name that can be read back — used to ensure_selected on reload so
  # vault fields materialize as %Masked{} for the resolver.
  defp selectable_names(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
  end

  defp has_attr?(resource, name), do: Ash.Resource.Info.attribute(resource, name) != nil
end
