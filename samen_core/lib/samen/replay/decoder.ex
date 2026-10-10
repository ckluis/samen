defmodule Samen.Replay.Decoder do
  @moduledoc """
  Decode stored replay frames back into the capture vocabulary (ADR-052 §2.3) — the inverse of
  `Samen.Replay.FrameSchema.encode/1`, written for STORED, therefore untrusted, data.

  ## Decode safety

    * A frame is decoded only if it passes `Samen.Replay.FrameSchema.validate/1` again — the
      same declaration the store checked at persist time. A row that fails it (written by a
      future or past schema, or tampered with) becomes ONE `:invalid` frame; nothing in it is
      decoded.
    * No stored string ever becomes a NEW atom. Module names, attribute names, map keys and
      `$atom` values go through `existing_atom/1` (`String.to_existing_atom/1` under a rescue);
      an unknown one becomes `Samen.Replay.Placeholder` `:code_changed` (a value) or is dropped
      (a key) — never a crash.
    * A bare string inside a tree (the validator refuses one, so this is defence in depth)
      decodes to a `:redacted` placeholder: no stored free string reaches a template.
    * Closed-set fields (`$redacted.kind`, `$dropped.kind`, `$count.kind`, `$dt.type`) are
      matched against their declared sets as STRINGS.

  The output is the capture vocabulary (`Ref`, `Record`, `Redacted`, `Dropped`, `Kept`, `Id`,
  `Count`, `Shape`) plus plain terms; `Samen.Replay.Resolver` turns it into render terms on
  the viewer's plane.
  """

  alias Samen.Replay.{Count, Dropped, FrameSchema, Id, Kept, Placeholder, Record, Redacted, Ref}
  alias Samen.Replay.Shape

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @typedoc "A decoded frame."
  @type frame :: %{
          seq: non_neg_integer(),
          at_ms: non_neg_integer(),
          kind: atom(),
          payload: map()
        }

  @doc """
  Decode one stored frame (`%{seq, at_ms, kind, payload}` — a `Samen.Replay.Frame` row or a
  map of the same shape). A frame that fails the schema decodes as `kind: :invalid` with an
  empty payload.
  """
  @spec frame(map()) :: frame()
  def frame(%{seq: seq, at_ms: at_ms, kind: kind, payload: payload}) do
    encoded = %{seq: seq, at_ms: at_ms, kind: kind, payload: payload}

    case FrameSchema.validate(encoded) do
      :ok -> %{seq: seq, at_ms: at_ms, kind: kind_atom(kind), payload: payload(payload)}
      {:error, _path} -> invalid(seq, at_ms)
    end
  rescue
    _ -> invalid(0, 0)
  end

  def frame(_), do: invalid(0, 0)

  defp invalid(seq, at_ms),
    do: %{seq: num(seq), at_ms: num(at_ms), kind: :invalid, payload: %{}}

  defp num(n) when is_integer(n) and n >= 0, do: n
  defp num(_), do: 0

  defp kind_atom(kind) when is_atom(kind), do: kind

  defp kind_atom(kind) when is_binary(kind),
    do: Enum.find(FrameSchema.kinds(), :invalid, &(Atom.to_string(&1) == kind))

  # A payload's top level: declared field names (atoms from the schema, never from the row).
  defp payload(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {payload_key(k), payload_value(payload_key(k), v)} end)
    |> Map.delete(nil)
  end

  @payload_keys FrameSchema.payloads()
                |> Map.values()
                |> List.flatten()
                |> Enum.map(fn {name, _type, _opts} -> name end)
                |> Enum.uniq()

  defp payload_key(k) when is_atom(k), do: if(k in @payload_keys, do: k)
  defp payload_key(k) when is_binary(k), do: Enum.find(@payload_keys, &(Atom.to_string(&1) == k))
  defp payload_key(_), do: nil

  defp payload_value(:assigns, v), do: tree(v)
  defp payload_value(:params, v), do: tree(v)
  defp payload_value(_key, v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp payload_value(_key, v) when is_atom(v), do: Atom.to_string(v)
  defp payload_value(_key, _v), do: nil

  @doc """
  Decode one stored tree (the JSON form of a sanitized term) into the capture vocabulary.
  """
  @spec tree(term()) :: term()
  def tree(v) when is_nil(v) or is_boolean(v) or is_number(v), do: v
  # Never a stored free string into a render (the validator already refuses one).
  def tree(v) when is_binary(v), do: Placeholder.new(:redacted, nil)
  def tree(v) when is_atom(v), do: v
  def tree(v) when is_list(v), do: Enum.map(v, &tree/1)

  def tree(v) when is_map(v) and map_size(v) == 1 do
    case Map.to_list(v) do
      [{"$" <> _ = marker, body}] when is_map(body) -> marker(marker, body)
      _ -> plain_map(v)
    end
  end

  def tree(v) when is_map(v), do: plain_map(v)
  def tree(_v), do: Placeholder.new(:code_changed)

  defp plain_map(v) do
    Enum.reduce(v, %{}, fn {k, val}, acc ->
      case map_key(k) do
        nil -> acc
        key -> Map.put(acc, key, tree(val))
      end
    end)
  end

  # A map key: an existing atom when it names one; a positional `$kN`, a UUID or a short list
  # index stays a string (the sanitizer only ever wrote server-known keys); anything else is
  # dropped.
  defp map_key(k) when is_atom(k), do: k

  defp map_key(k) when is_binary(k) do
    cond do
      uuid?(k) -> String.downcase(k)
      Regex.match?(~r/\A\$k\d{1,6}\z/, k) -> k
      Regex.match?(~r/\A\d{1,3}\z/, k) -> k
      true -> existing_atom(k)
    end
  end

  defp map_key(_), do: nil

  # ---------------------------------------------------------------------------
  # Markers

  defp marker("$ref", b) do
    with resource when is_binary(resource) <- b["resource"],
         attribute when is_binary(attribute) <- b["attribute"] do
      %Ref{resource: resource, pk: pk(b["pk"]), attribute: attribute, label: str(b["label"])}
    else
      _ -> Placeholder.new(:code_changed)
    end
  end

  defp marker("$redacted", b) do
    %Redacted{
      kind: closed(b["kind"], Redacted.kinds(), :string),
      length: len(b["length"]),
      label: str(b["label"])
    }
  end

  defp marker("$dropped", b),
    do: %Dropped{kind: closed(b["kind"], Dropped.kinds(), :struct), struct: str(b["struct"])}

  defp marker("$kept", %{"value" => v}) when is_binary(v), do: %Kept{value: v}

  defp marker("$id", %{"value" => v}) when is_binary(v) do
    if uuid?(v), do: %Id{value: String.downcase(v)}, else: Placeholder.new(:redacted)
  end

  defp marker("$atom", %{"value" => v}) when is_binary(v) do
    case existing_atom(v) do
      nil -> Placeholder.new(:code_changed)
      atom -> atom
    end
  end

  defp marker("$dt", %{"type" => type, "value" => v}) when is_binary(v), do: datetime(type, v)

  defp marker("$dec", %{"value" => v}) when is_binary(v) or is_number(v) do
    case Decimal.cast(v) do
      {:ok, d} -> d
      :error -> Placeholder.new(:code_changed)
    end
  end

  defp marker("$record", b) do
    case b["resource"] do
      resource when is_binary(resource) ->
        fields = if is_map(b["fields"]), do: plain_map(b["fields"]), else: %{}
        %Record{resource: resource, pk: pk(b["pk"]), fields: fields}

      _ ->
        Placeholder.new(:code_changed)
    end
  end

  defp marker("$count", b) do
    %Count{kind: closed(b["kind"], [:stream, :upload, :streams, :uploads], :stream), n: len(b["n"]) || 0}
  end

  defp marker("$more", b), do: %Samen.Replay.More{n: len(b["n"]) || 0}

  defp marker("$tuple", %{"items" => items}) when is_list(items),
    do: items |> Enum.map(&tree/1) |> List.to_tuple()

  defp marker("$shape", b) do
    fields = if is_list(b["fields"]), do: Enum.flat_map(b["fields"], &shape_field/1), else: []
    %Shape{fields: fields, more: len(b["more"]) || 0}
  end

  defp marker(_unknown, _body), do: Placeholder.new(:code_changed)

  # A shape entry keeps only its declared, bounded keys (the schema validated each value).
  defp shape_field(f) when is_map(f) do
    entry =
      %{
        key: str(f["key"]),
        type: str(f["type"]),
        length: len(f["length"]),
        class: str(f["class"]),
        value: shape_value(f["value"])
      }

    entry =
      if is_list(f["fields"]),
        do: Map.put(entry, :fields, Enum.flat_map(f["fields"], &shape_field/1)),
        else: entry

    [entry]
  end

  defp shape_field(_), do: []

  defp shape_value(v) when is_binary(v) or is_integer(v) or is_boolean(v), do: v
  defp shape_value(_), do: nil

  defp datetime(type, v) do
    result =
      case type do
        "date" -> Date.from_iso8601(v)
        "time" -> Time.from_iso8601(v)
        "datetime" -> with {:ok, dt, _off} <- DateTime.from_iso8601(v), do: {:ok, dt}
        "naive" -> NaiveDateTime.from_iso8601(v)
        _ -> :error
      end

    case result do
      {:ok, value} -> value
      _ -> Placeholder.new(:code_changed)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  @doc """
  The EXISTING atom a stored string names, or `nil`. Never creates an atom.
  """
  @spec existing_atom(term()) :: atom() | nil
  def existing_atom(s) when is_binary(s) and byte_size(s) in 1..255 do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> nil
  end

  def existing_atom(_), do: nil

  @doc """
  The loaded module a stored module name (`"Samen.Web.CRM.ContactsLive"`) names, or `nil`.
  Never creates an atom, never loads code that is not already on the code path.
  """
  @spec module(term()) :: module() | nil
  def module(name) when is_binary(name) do
    with true <- Regex.match?(~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/, name),
         mod when is_atom(mod) and not is_nil(mod) <- existing_atom("Elixir." <> name),
         true <- Code.ensure_loaded?(mod) do
      mod
    else
      _ -> nil
    end
  end

  def module(_), do: nil

  defp closed(v, set, default) when is_binary(v),
    do: Enum.find(set, default, &(Atom.to_string(&1) == v))

  defp closed(_v, _set, default), do: default

  defp pk(v) when is_integer(v), do: v
  defp pk(v) when is_binary(v), do: if(uuid?(v), do: String.downcase(v))
  defp pk(_), do: nil

  defp len(n) when is_integer(n) and n >= 0, do: n
  defp len(_), do: nil

  defp str(v) when is_binary(v), do: v
  defp str(_), do: nil

  defp uuid?(v), do: Regex.match?(@uuid, v)
end
