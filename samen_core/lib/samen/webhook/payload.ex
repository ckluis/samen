defmodule Samen.Webhook.Payload do
  @moduledoc """
  Webhook payload serialization under the T3.11 opt-in allowlist (doc
  §external-surface, F3.6; plan T3.13).

  ## Opt-IN allowlist (F3.6)

  The doc (§external-surface, `:711`) is explicit that a resource's columns are
  **not auto-published** to the API OR webhook surface. Each field is an explicit
  opt-in into the public allowlist — "a field absent from that allowlist is absent
  from the payload by omission; the default is not-exposed."

  This serializer honors that mandate by reusing the **same `show_fields` allowlist
  the public API surface uses** (AshJsonApi's `json_api do show_fields([…]) end`
  block). A field is included ONLY IF its catalog name appears in the resource's
  `show_fields`. This is the identical opt-in control `AshJsonApi` filters the API
  payload through (`show_field?`), so the webhook surface mirrors the API surface
  field-for-field.

  Consequences of the opt-in design (verified by the F3.6 red-path tests):

    * A `public?: true` attribute NOT named in `show_fields` (e.g. `org_id`,
      `inserted_at`, `updated_at`, a plaintext `notes` column) is **ABSENT** by
      omission — no pattern-matching required, no storage-name heuristic.
    * The Tier-1 `:custom` jsonb bag is **ABSENT** unless explicitly allowlisted —
      the bag is never auto-published, even when populated with data.
    * A resource with NO `show_fields` (no AshJsonApi `json_api` block, or an empty
      allowlist) produces an **empty `data` map** — fail-closed, nothing exposed.

  ### Why `show_fields` (not a separate webhook-payload declaration)

  Reusing `show_fields` composes best with the T3.11 code: (a) it is the SAME
  allowlist the API serializer already enforces, so the webhook surface cannot
  drift from the API surface; (b) `Samen.ApiContract` already resolves it
  defensively (AshJsonApi is an *optional* dep of `samen_core` — only host apps like
  `demo` carry it), so there is one canonical resolution path; (c) it keeps the
  doc's "the json_api / webhook payload declaration names it" a SINGLE declaration
  rather than two allowlists a host must keep in sync. A dedicated webhook-payload
  field declaration would let the two surfaces diverge silently — the exact drift
  Gate-3 F3.6 flagged.

  ## Additional PII/storage constraints (defense in depth)

  On top of the opt-in allowlist, allowlisted fields still obey:

    * **Catalog names only** — the `show_fields` names are catalog names; a storage
      name (`cnt_*`, `pii_*`, `vt_*`) is never allowlisted. A belt-and-suspenders
      storage-name guard drops any such name that somehow reaches the serializer.
      The guard keys on the resource's **declared abbrev** (`Samen.Info.abbrev/1`):
      a name is stripped only if it starts with THIS resource's `<abbrev>_` /
      `pii_<abbrev>_` prefix (or the generic `pii_` storage-artifact prefix) — NOT a
      blanket 3-letter regex, which false-positived on legitimate catalog names like
      `cdl_number` (A6 fix).
    * **Masked / absent PII** — `%Masked{}` values serialize as `"••••"` (via the
      `Masked` encoder); a vault-routed field absent without a reveal grant is
      ABSENT. Plaintext in a PII-declared field is OMITTED (fail-closed).

  ## Build

  `build/3` takes an event type string, a resource (Ash resource module), and a
  record (a loaded Ash struct), and returns a map ready for JSON serialization.

  The payload shape:

      %{
        "event" => "invoice.created",          # bounded event type
        "id"    => "rndrec-uuid...",            # opaque resource record ID
        "type"  => "contact",                  # catalog resource type name
        "data"  => %{                           # allowlisted public attributes
          "display_name" => "Acme Corp",        # on show_fields; non-PII catalog name
          "full_name"    => "••••"              # on show_fields; masked PII (Masked → "••••")
          # (a public field NOT on show_fields is ABSENT by omission)
          # (PII absent if operator-plane with no grant)
        }
      }

  ## PII safety

  The `data` map NEVER contains:
    * Storage column names (`cnt_display_name`, `pii_cnt_full_name`)
    * Raw vault tokens (`vt_abcdef…`)
    * Decoded plaintext PII (unless a reveal grant is active AND the caller
      explicitly passes `reveal: true` — which the delivery worker does NOT do)

  The default (no `reveal: true`) leaves `%Masked{}` values as-is, which Jason
  encodes as `"••••"`. This is the safe path: the receiver gets `"••••"` and must
  use the API reveal flow for the actual plaintext.
  """

  alias Samen.Masked
  alias Samen.Pii.Info, as: PiiInfo

  @doc """
  Build the webhook payload map for `event_type`, `resource`, and `record`.

  Options:
    * `:include_masked` — (default `true`) if false, PII-bearing fields with a
      `%Masked{}` value are OMITTED rather than serialized as `"••••"`. The
      delivery worker uses `true` (the receiver sees `"••••"`, not nothing).

  Returns a map (not yet JSON-encoded — the delivery worker encodes it).
  """
  @spec build(String.t(), module(), struct(), keyword()) :: map()
  def build(event_type, resource, record, opts \\ []) do
    include_masked = Keyword.get(opts, :include_masked, true)

    %{
      "event" => event_type,
      "id" => record_id(record),
      "type" => resource_type(resource),
      "data" => build_data(resource, record, include_masked)
    }
  end

  @doc """
  Encode the payload map to JSON (via Jason).

  Returns `{:ok, json_string}` or `{:error, reason}`.
  """
  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(payload) when is_map(payload) do
    Jason.encode(payload)
  end

  # ---------------------------------------------------------------------------
  # Private

  # F3.6 — opt-IN allowlist. A field is serialized ONLY IF its catalog name is on
  # the resource's `show_fields` allowlist (the same allowlist the public API surface
  # uses). A field absent from `show_fields` — INCLUDING the Tier-1 `:custom` bag,
  # `org_id`, `inserted_at`, `updated_at`, and any plaintext-at-rest column — is
  # ABSENT from the payload by omission. No allowlist → empty `data` (fail-closed).
  defp build_data(resource, record, include_masked) do
    allowlist = allowlisted_fields(resource)
    pii_attrs = pii_attr_names(resource)
    abbrev = declared_abbrev(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr -> attr.public? and MapSet.member?(allowlist, attr.name) end)
    |> Enum.reduce(%{}, fn attr, acc ->
      name = to_string(attr.name)
      value = Map.get(record, attr.name)

      cond do
        # Defense in depth: a storage-named field is never on a well-formed
        # allowlist, but if one slips through we still drop it (catalog names only).
        storage_name?(name, abbrev) ->
          acc

        # PII attribute: Masked → "••••" or omit.
        attr.name in pii_attrs ->
          case value do
            %Masked{} ->
              if include_masked, do: Map.put(acc, name, "••••"), else: acc

            nil ->
              acc

            _other ->
              # Plaintext PII leaked to the payload serializer — omit safely.
              # This should not happen if the resource is correctly wired, but we
              # fail closed: a non-masked PII value is NOT put into the payload.
              acc
          end

        # Normal non-PII public attribute that IS on the allowlist.
        true ->
          Map.put(acc, name, serialize_value(value))
      end
    end)
  end

  # The opt-in allowlist: the resource's AshJsonApi `show_fields` set (catalog
  # names). Resolved defensively via `apply/3` because AshJsonApi is an OPTIONAL dep
  # of samen_core (only host apps carry it) — mirrors `Samen.ApiContract.build_fields/1`.
  # A resource with no AshJsonApi block, no `show_fields`, or an unresolvable
  # allowlist yields an EMPTY set → the payload `data` is empty (fail-closed:
  # nothing is auto-published).
  defp allowlisted_fields(resource) do
    info_mod = Module.concat(["AshJsonApi", "Resource", "Info"])

    show_fields =
      if Code.ensure_loaded?(info_mod) and function_exported?(info_mod, :show_fields, 1) do
        try do
          apply(info_mod, :show_fields, [resource]) || []
        rescue
          _ -> []
        end
      else
        []
      end

    MapSet.new(show_fields)
  end

  defp pii_attr_names(resource) do
    resource
    |> PiiInfo.pii_attributes()
    |> Enum.map(fn attr -> attr.name end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  # The resource's DECLARED abbrev (the source of truth for its storage prefix),
  # read back through the normal `samen` DSL surface. `nil` when the resource does
  # not `use Samen.Resource` (e.g. a plain test struct or a foreign resource) — in
  # which case only the generic `pii_` storage-artifact guard applies.
  defp declared_abbrev(resource) do
    Samen.Info.abbrev(resource)
  rescue
    _ -> nil
  end

  # A6 fix (Gate-6 / extraction-retro A6): a "storage name" is a bare storage
  # column that leaked through `public?` — the `<abbrev>_<rest>` naming convention.
  #
  # The OLD guard used a blanket `~r/^[a-z]{3}_/` regex, which FALSE-POSITIVED on
  # legitimate CATALOG names that merely START with a 3-letter token + underscore
  # (`cdl_number`, `cdl_state`, `cdl_expiry`, `eld_provider`) and SILENTLY DROPPED
  # them — over-strict (absent by omission, never a leak) but wrong: those catalog
  # fields belong in the payload.
  #
  # A name is now treated as a storage name ONLY IF it starts with THIS resource's
  # own registered abbrev prefix (`<abbrev>_`), its vault prefix (`pii_<abbrev>_`),
  # or the generic `pii_` prefix (a genuine storage artifact regardless of abbrev).
  # A catalog name is NEVER prefixed with its own resource's abbrev — the storage
  # transformer prefixes PHYSICAL columns with `<abbrev>_`; the catalog name it maps
  # from is the un-prefixed one. So `cdl_number` on the `drv` Driver survives, while
  # a genuinely-leaked `drv_something` is still stripped.
  #
  # This is DEFENSE IN DEPTH only: the `show_fields` opt-in allowlist remains the
  # primary gate — a field must be explicitly allowlisted (catalog name) to reach
  # this check at all. When the abbrev is unknown (`nil`), only the `pii_` guard
  # applies (fail-safe: we never invent a prefix that would over-drop a catalog name).
  defp storage_name?(name, abbrev) do
    abbrev_prefixed? =
      is_binary(abbrev) and
        (String.starts_with?(name, abbrev <> "_") or
           String.starts_with?(name, "pii_" <> abbrev <> "_"))

    abbrev_prefixed? or String.starts_with?(name, "pii_")
  end

  defp resource_type(resource) do
    # Use the AshJsonApi type if available, else the resource's module basename.
    if Code.ensure_loaded?(AshJsonApi.Resource.Info) and
         function_exported?(AshJsonApi.Resource.Info, :type, 1) do
      try do
        apply(AshJsonApi.Resource.Info, :type, [resource]) || default_type(resource)
      rescue
        _ -> default_type(resource)
      end
    else
      default_type(resource)
    end
  end

  defp default_type(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp record_id(record) do
    case Map.get(record, :id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp serialize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_value(%Masked{}), do: "••••"
  defp serialize_value(v) when is_atom(v) and not is_boolean(v) and v != nil, do: to_string(v)
  defp serialize_value(v), do: v
end
