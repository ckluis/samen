defmodule Samen.Webhook.Payload do
  @moduledoc """
  Webhook payload serialization under the T3.11 allowlist (doc §external-surface;
  plan T3.13).

  Webhook payloads obey the SAME constraints as the public API (T3.11):

    * **Catalog names only** — never storage names (`cnt_*`, `pii_*`, `vt_*`) nor
      vault routing internals.
    * **Masked / absent PII** — `%Masked{}` values serialize as `"••••"` by the
      existing `Masked` encoder; vault-routed fields absent without a reveal grant
      serialize as ABSENT (omitted from the map entirely).
    * **No plaintext PII** — the payload NEVER carries a raw decrypted PII value
      unless the allowlist permits it AND a reveal grant is active.
    * **Allowlist** — only fields in the resource's `public?: true` set that are
      NOT vault-routed (or which are masked) are included. This is the same opt-in
      allowlist the API serializer uses.

  ## Build

  `build/3` takes an event type string, a resource (Ash resource module), and a
  record (a loaded Ash struct), and returns a map ready for JSON serialization.

  The payload shape:

      %{
        "event" => "invoice.created",          # bounded event type
        "id"    => "rndrec-uuid...",            # opaque resource record ID
        "type"  => "contact",                  # catalog resource type name
        "data"  => %{                           # filtered public attributes
          "display_name" => "Acme Corp",        # non-PII catalog name
          "full_name"    => "••••"              # masked PII (Masked → "••••")
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

  defp build_data(resource, record, include_masked) do
    pii_attrs = pii_attr_names(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr -> attr.public? end)
    |> Enum.reduce(%{}, fn attr, acc ->
      name = to_string(attr.name)
      value = Map.get(record, attr.name)

      cond do
        # Skip storage columns that are not catalog-name safe (abbrev_* or pii_*).
        storage_name?(name) ->
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

        # Normal non-PII public attribute.
        true ->
          Map.put(acc, name, serialize_value(value))
      end
    end)
  end

  defp pii_attr_names(resource) do
    resource
    |> PiiInfo.pii_attributes()
    |> Enum.map(fn attr -> attr.name end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  # A "storage name" is a bare storage column that leaked through public? — the
  # abbrev_* naming convention. Non-PII attributes have catalog names (`:name`,
  # `:status`, etc.), not storage names. We guard against a resource that
  # mistakenly exposes a storage column by checking for 3-letter-prefix pattern.
  defp storage_name?(name) do
    # Storage columns follow the pattern "<abbrev>_<rest>" where abbrev is 3
    # lower-case letters. Catalog names never start with a 3-letter abbrev prefix.
    # We also block pii_ prefix explicitly.
    Regex.match?(~r/^[a-z]{3}_/, name) or String.starts_with?(name, "pii_")
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
