defmodule Samen.Vault.Change do
  @moduledoc """
  The resource ↔ vault integration (Gate-0 vault-stack fix, mandatory P0).

  A global `Ash.Resource.Change` (`Samen.Resource` injects it into every resource
  that has a `pii do` block) that makes vault routing **transparent** on the real
  Ash `:create` / `:update` actions:

    * **On write** — for each vault-routed `pii_attribute` the changeset sets, it
      1. resolves the row's **subject_id** (the crypto-shred unit — the resource's
         primary key), forcing/generating it on create if absent;
      2. **re-runs a SCALAR field's DECLARED logical type `cast_input`** (ADR-036 D3
         conformance, T99): `Samen.Transformers.MaterializePii` materialized the
         column as `Samen.Type.VaultField` (identity cast), so this is the single
         point on the vaulted write path where a scalar declared type
         (`EmailAddress`/`PhoneNumber`/`URL`/…) validates the plaintext — a value the
         type rejects is refused as a normal changeset error (DB unchanged), and the
         cast-normalized value is vaulted (a phone reveals E.164-normalized, identical
         to the org-plaintext path). Composite fields are left as-is EXCEPT
         `Samen.Type.Address` (ADR-036 H4/T14, the §10 addendum's own-boundary
         validation) — see `cast_declared_types/1` for why;
      3. calls `Samen.Vault.store_fields/4`, which encrypts each plaintext value
         under the subject DEK into a `pii_vault` row (ciphertext + token);
      4. **replaces the domain column value with the opaque `vt_*` token**
         (`force_change_attribute`), so the domain table only ever receives a
         token — never plaintext. `Samen.Type.VaultField.dump_to_native/2` is the
         last-line guard: it refuses to write a non-token, so even a bug that
         skipped this change fails closed rather than leaking plaintext.

    * **On read** — no per-resource hook is needed: the vault column's type
      (`Samen.Type.VaultField`) presents `%Samen.Masked{}` from the stored token
      via `cast_stored`, so `Ash.read` returns `%Masked{}` as the field's normal
      value. `Samen.Vault.materialize/2` remains available for callers holding a
      raw struct (e.g. from a non-Ash query), but the type covers the Ash path.

  The subject key + ciphertext write happen in `before_action`, inside the same
  Ecto transaction Ash opens for the action, so a failed insert rolls back the
  vault rows too (via the repo's transaction) — no orphan ciphertext, no
  half-tokenized domain row.
  """
  use Ash.Resource.Change

  alias Samen.Pii.Info
  alias Samen.Masked

  @impl true
  def change(changeset, _opts, _context) do
    fields = Info.fields(changeset.resource)

    if fields == [] do
      changeset
    else
      Ash.Changeset.before_action(changeset, fn cs -> route_fields(cs, fields) end)
    end
  end

  # Route every set PII field's plaintext into the vault, replacing the column
  # value with the token. Fields the changeset did not touch are left alone (their
  # existing token stays); an explicit `nil` clears the field (no vault row).
  defp route_fields(changeset, fields) do
    repo = repo!(changeset)
    subject_id = resolve_subject_id(changeset)

    # Collect the (field, plaintext) pairs the caller actually set to a non-token
    # plaintext value. A %Masked{} or a raw token means "already vaulted, leave it".
    to_vault =
      fields
      |> Enum.flat_map(fn field ->
        case fetch_plaintext(changeset, field.name) do
          {:set, %Masked{}} -> []
          {:set, "vt_" <> _} -> []
          {:set, nil} -> []
          {:set, plaintext} -> [{field, plaintext}]
          :unset -> []
        end
      end)

    if to_vault == [] do
      changeset
    else
      changeset = ensure_subject_attr(changeset, subject_id)
      do_vault(changeset, subject_id, to_vault, repo)
    end
  end

  defp do_vault(changeset, subject_id, to_vault, repo) do
    # ADR-036 D3 conformance (T99): re-run each field's DECLARED logical type
    # `cast_input` (validation AND normalization) BEFORE the plaintext reaches the
    # vault. `Samen.Transformers.MaterializePii` swaps every pii_attribute's declared
    # type for `Samen.Type.VaultField` (identity cast), so this is the single point on
    # the vaulted write path where the declared type's validation runs — a garbage
    # email / out-of-allowlist URL is refused, a scalar phone number is normalized
    # (reveal returns the normalized value, byte-identical to the org-plaintext path).
    # FullName/Emails/Phones keep their existing at-rest byte shape unvalidated;
    # `Samen.Type.Address` (ADR-036 H4/T14) is cast-and-refused the same as a scalar —
    # see `cast_declared_types/1` and the §10 addendum in docs/adr/ADR-036-rich-types.md.
    case cast_declared_types(to_vault) do
      {:error, field} ->
        reject_cast(changeset, field)

      {:ok, {casted, clears}} ->
        changeset
        |> apply_clears(clears)
        |> store_casted(subject_id, casted, repo)
    end
  end

  defp store_casted(changeset, _subject_id, [], _repo), do: changeset

  defp store_casted(changeset, subject_id, casted, repo) do
    # Group by vault so store_fields batches per subject/vault under one DEK unwrap.
    casted
    |> Enum.group_by(fn {field, _value} -> field.vault end)
    |> Enum.reduce_while(changeset, fn {vault_name, entries}, cs ->
      pairs = Enum.map(entries, fn {field, value} -> {field.name, dump_plaintext(value)} end)

      case Samen.Vault.store_fields(subject_id, vault_name, pairs, repo) do
        {:ok, tokens} ->
          updated =
            Enum.reduce(entries, cs, fn {field, _value}, acc ->
              token = Map.fetch!(tokens, field.name)
              Ash.Changeset.force_change_attribute(acc, field.name, Masked.new(token, field.name))
            end)

          {:cont, updated}

        {:error, reason} ->
          {:halt, Ash.Changeset.add_error(cs, field: :vault, message: "vault store failed: #{inspect(reason)}")}
      end
    end)
  end

  # Re-run the DECLARED logical type's `cast_input` on each SCALAR plaintext to vault.
  # Uses `Ash.Type.cast_input/2` — the SAME entry point Ash uses to cast an ordinary
  # (org-plaintext) attribute of that type, so it inits the type's constraints and
  # validates/normalizes identically: a vaulted `EmailAddress`/`PhoneNumber`/`URL`/…
  # value is REFUSED if the type rejects it, and STORED normalized (a phone reveals
  # `"+15550100100"`, byte-identical to the org-plaintext path — D3 parity).
  #
  # COMPOSITE fields (`FullName`/`Emails`/`Phones`) are deliberately left EXACTLY as
  # before — no cast gate, store the original value (`dump_plaintext` of what the caller
  # set). This D3 conformance fix is scoped to the confirmed gap (the H3 *scalar*
  # validating types; the T13 probe). Gating composites here is NOT safe within this
  # task's surface: shipped resources write composites in loose shapes their OWN
  # `cast_input` rejects (e.g. `Invitation.email` as a bare-string list
  # `["x@y.test"]`, which `Samen.Type.Emails` refuses) and reshaping the cast struct
  # (`[…]` → `{"entries":[…]}`) breaks every masking/reveal/render/CDC/blind-index
  # consumer that parses the stored composite. Composite validation-on-write for those
  # three types needs those loose writers cleaned up first — a cross-cutting change
  # beyond the two kernel files, tracked as a follow-up, not done silently here.
  #
  # `Samen.Type.Address` (ADR-036 H4/T14) is the ONE exception, and it is narrow and
  # explicit rather than a blanket flip of `field.composite?`: T14's binding directive
  # (the ADR-036 §10 addendum, post-T99) is to validate Address AT ITS OWN INPUT
  # BOUNDARY rather than land the writer-cleanup task T05 is concurrently working
  # against the Invitation/Emails surface. Address is BRAND NEW — no resource ships a
  # loose-shape Address writer to break — so it is safe to opt this ONE composite type
  # into the same cast-and-refuse treatment as the scalars, by module identity (not by
  # `composite?`), leaving FullName/Emails/Phones completely untouched.
  #
  # Returns `{:ok, {casted, clears}}` where `casted` is `[{field, value_to_store}]` and
  # `clears` is `[field]` for a value the type normalized to `nil` (e.g. an empty string)
  # — those clear the column rather than vaulting an empty row. Returns `{:error, field}`
  # on the FIRST value the declared type REJECTS so the write is refused.
  defp cast_declared_types(to_vault) do
    Enum.reduce_while(to_vault, {:ok, {[], []}}, fn {field, plaintext}, {:ok, {casted, clears}} ->
      cond do
        field.composite? and field.type != Samen.Type.Address ->
          # Preserve today's behavior byte-for-byte: no cast, store the original value.
          {:cont, {:ok, {[{field, plaintext} | casted], clears}}}

        true ->
          case Ash.Type.cast_input(field.type, plaintext) do
            {:ok, nil} -> {:cont, {:ok, {casted, [field | clears]}}}
            {:ok, normalized} -> {:cont, {:ok, {[{field, normalized} | casted], clears}}}
            _error -> {:halt, {:error, field}}
          end
      end
    end)
    |> case do
      {:ok, {casted, clears}} -> {:ok, {Enum.reverse(casted), Enum.reverse(clears)}}
      other -> other
    end
  end

  # A value the declared type normalized to nil clears the column (matches the
  # explicit-nil "clear the field" semantics; a leftover raw value here would trip
  # VaultField.dump_to_native's fail-closed refusal).
  defp apply_clears(changeset, clears) do
    Enum.reduce(clears, changeset, fn field, cs ->
      Ash.Changeset.force_change_attribute(cs, field.name, nil)
    end)
  end

  # A value the declared type REFUSES is rejected as a normal Ash changeset error on
  # the offending attribute. The rejected value is NEVER echoed — it is (or may be)
  # PII; the error names only the field and its declared type.
  defp reject_cast(changeset, field) do
    Ash.Changeset.add_error(changeset,
      field: field.name,
      message:
        "is invalid: failed #{inspect(field.type)} validation before vaulting " <>
          "(ADR-036 D3: a vaulted PII value is validated on input)"
    )
  end

  # The plaintext value the caller set for a field, if any. We read the CASTED
  # attribute value on the changeset (VaultField.cast_input passes plaintext
  # through unchanged), distinguishing "set to nil" from "not set at all".
  defp fetch_plaintext(changeset, name) do
    case Ash.Changeset.fetch_change(changeset, name) do
      {:ok, value} -> {:set, value}
      :error -> :unset
    end
  end

  # Convert a plaintext value into the binary the vault encrypts. Composite PII
  # structs / maps are JSON-encoded so reveal can round-trip them; scalars are
  # stringified. (reveal returns the same binary; a host that needs the typed
  # value decodes it — the vault stores opaque bytes.)
  defp dump_plaintext(value) when is_binary(value), do: value

  defp dump_plaintext(%Date{} = d), do: Date.to_iso8601(d)
  defp dump_plaintext(%DateTime{} = d), do: DateTime.to_iso8601(d)

  defp dump_plaintext(value) when is_struct(value) do
    value |> Map.from_struct() |> Jason.encode!()
  end

  defp dump_plaintext(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp dump_plaintext(value), do: to_string(value)

  # subject_id = the resource's primary key value (the crypto-shred unit). On
  # create it may be unset (DB default gen_random_uuid()); we generate + force it
  # so the ciphertext and the domain row share the same subject.
  defp resolve_subject_id(changeset) do
    pk = pk_attr(changeset.resource)

    case Ash.Changeset.fetch_change(changeset, pk) do
      {:ok, value} when not is_nil(value) ->
        to_string(value)

      _ ->
        case Map.get(changeset.data || %{}, pk) do
          nil -> Ash.UUID.generate()
          existing -> to_string(existing)
        end
    end
  end

  # On create, force the generated pk so the row and its ciphertext share the
  # subject. On update the pk is already the data's pk (unchanged).
  defp ensure_subject_attr(changeset, subject_id) do
    pk = pk_attr(changeset.resource)

    cond do
      not is_nil(Map.get(changeset.data || %{}, pk)) ->
        changeset

      match?({:ok, v} when not is_nil(v), Ash.Changeset.fetch_change(changeset, pk)) ->
        changeset

      true ->
        Ash.Changeset.force_change_attribute(changeset, pk, subject_id)
    end
  end

  defp pk_attr(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pk] -> pk
      [pk | _] -> pk
      [] -> :id
    end
  end

  defp repo!(changeset) do
    AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.Vault.Change: could not resolve a repo for #{inspect(changeset.resource)}"
  end
end
