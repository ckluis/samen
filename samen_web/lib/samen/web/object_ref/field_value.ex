defmodule Samen.Web.ObjectRef.FieldValue do
  @moduledoc """
  Presentational formatting for a card field's ALREADY-RESOLVED value (ADR-012 §4.4) — the
  ONE place both the catalog-driven `DefaultCard` and the per-resource override cards format
  a value, so the masking discipline lives in exactly one module.

  ## The masking invariant (non-negotiable)

  A `%Samen.Masked{}` passes through EVERY function here UNTOUCHED — it is returned verbatim
  so the component renders it as `••••` through `Phoenix.HTML.Safe`. There is NO branch that
  inspects a `%Masked{}`'s token, coerces it to a string, or produces plaintext. This module
  NEVER unwraps a vault value; it only shapes values the resolver already resolved to
  PLAINTEXT (tenant plane) or left MASKED (operator plane).

  The kernel PII types serialize their PLAINTEXT form as a JSON binary on the tenant plane
  (`Samen.Api.PiiResolution` reveals through the vault as the field's stored JSON), so a
  revealed `full_name` arrives as `{"first":…,"last":…}` and a revealed `emails` as a JSON
  array — the SAME shapes `Samen.Web.CRM.ContactLive` decodes. We reuse that exact decoding so
  a card and a detail page render identically.
  """

  alias Samen.Masked

  @doc """
  Format a resolved `full_name` value for display. `%Masked{}` → itself (`••••`); a FullName
  JSON binary → `"First Last"`; a plain binary → itself; nil → the `display_name` fallback or
  the em-dash.
  """
  def full_name(value, display_name \\ nil)
  def full_name(%Masked{} = m, _display_name), do: m

  def full_name(json, _display_name) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> json
    end
  end

  def full_name(nil, display_name) when is_binary(display_name), do: display_name
  def full_name(nil, _display_name), do: "—"
  def full_name(other, _display_name), do: other

  @doc "Format the first email of a resolved `emails` value. `%Masked{}` passes through."
  def email(%Masked{} = m), do: m
  def email(%Samen.Type.Emails{entries: entries}), do: email(entries)

  def email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> email(list)
      _ -> "—"
    end
  end

  def email(emails) when is_list(emails) do
    case List.first(emails) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  def email(_), do: "—"

  @doc "Format the first phone of a resolved `phones` value. `%Masked{}` passes through."
  def phone(%Masked{} = m), do: m
  def phone(%Samen.Type.Phones{entries: entries}), do: phone(entries)

  def phone(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> phone(list)
      _ -> "—"
    end
  end

  def phone(phones) when is_list(phones) do
    case List.first(phones) do
      %{"number" => num} -> num
      %{number: num} -> num
      _ -> "—"
    end
  end

  def phone(_), do: "—"

  @doc """
  Format an ARBITRARY resolved attribute value for the catalog-driven default card. Masking-
  safe by the first clause. Handles the kernel PII shapes, atoms, booleans, money-ish integers,
  dates, and falls back to `to_string/1` for anything with `String.Chars`. A value with no
  safe string form is dropped (returns nil) so the default card never raises.
  """
  def generic(%Masked{} = m), do: m
  def generic(nil), do: nil
  def generic(value) when is_binary(value), do: maybe_decode_pii(value)
  def generic(value) when is_atom(value), do: humanize_atom(value)
  def generic(value) when is_integer(value), do: Integer.to_string(value)
  def generic(value) when is_float(value), do: Float.to_string(value)

  def generic(%Date{} = d), do: Date.to_iso8601(d)
  def generic(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  def generic(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  def generic(%Samen.Type.Emails{} = e), do: email(e)
  def generic(%Samen.Type.Phones{} = p), do: phone(p)

  # A list of PII-ish maps (emails/phones stored as list) — show the first.
  def generic([%{} | _] = list), do: first_map_value(list)

  # A map (custom bag / composite) — do not attempt to render arbitrary maps in a card.
  def generic(%{} = _map), do: nil
  def generic(list) when is_list(list), do: nil

  @doc "A human label for an atom/string field name (`:lifecycle_stage` -> \"Lifecycle stage\")."
  def humanize(name) when is_atom(name), do: name |> Atom.to_string() |> humanize()

  def humanize(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.trim()
    |> capitalize_first()
  end

  # -- private -----------------------------------------------------------------

  # A resolved binary MIGHT be a FullName/Emails JSON blob (the vault stores the JSON form).
  # Decode only the two known shapes; otherwise the binary is its own display value.
  defp maybe_decode_pii(value) do
    case Jason.decode(value) do
      {:ok, %{"first" => _} = _map} -> full_name(value)
      {:ok, [%{"address" => _} | _]} -> email(value)
      {:ok, [%{"number" => _} | _]} -> phone(value)
      _ -> value
    end
  end

  defp humanize_atom(value) do
    value |> Atom.to_string() |> String.replace("_", " ")
  end

  defp first_map_value([%{"address" => addr} | _]), do: addr
  defp first_map_value([%{"number" => num} | _]), do: num
  defp first_map_value(_), do: nil

  defp capitalize_first(""), do: ""
  defp capitalize_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
