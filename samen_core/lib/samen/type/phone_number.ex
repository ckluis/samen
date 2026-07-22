defmodule Samen.Type.PhoneNumber do
  @moduledoc """
  `Samen.Type.PhoneNumber` — H3's single-value phone scalar (ADR-036 D3;
  WS-H spec §H3), "for org-level, non-personal contact points."

  ## Storage shape

  `storage_type/1` is `:string`. The canonical value is a format-validated
  (E.164-ish) phone number string: an optional leading `+`, then 8-15 digits,
  first digit non-zero. Common human separators (spaces, dashes, parens,
  dots) are stripped before validation so `"+1 (555) 010-0100"` normalizes to
  `"+15550100100"`.

  ## PII posture — PII-BY-DEFAULT, deliberately UNCLASSIFIED (ADR-036 D3)

  Identical posture to `Samen.Type.EmailAddress` (see its moduledoc for the
  full rationale): this type does **NOT** export `samen_pii_class/0` and
  carries **NO** type-level `Samen.NonPii.TypeClearance` entry — it is
  deliberately left unclassified so `Samen.Pii.Classification.classify/1`
  falls through to the mask-unknown-by-default PII result. No config can make
  a bare `Samen.Type.PhoneNumber` column plaintext-by-type.

  ## Two usage shapes (ADR-036 D3)

    * **Personal (default, safe path):** `pii_attribute :phone,
      Samen.Type.PhoneNumber, vault: :pii_phone`.
    * **Org-level, non-personal** (e.g. a company's support line): a
      plaintext `attribute :support_phone, Samen.Type.PhoneNumber` —
      masks-by-default until cleared via `Samen.NonPii.register/1`.
  """
  use Ash.Type

  # E.164-ish: optional leading +, 8-15 digits, leading digit non-zero.
  @phone_regex ~r/^\+?[1-9]\d{7,14}$/
  @strip_chars ~r/[\s\-\(\)\.]/

  @impl true
  def storage_type(_constraints), do: :string

  @impl true
  def constraints do
    [max_length: [type: :pos_integer, doc: "Optional maximum length (checked pre-normalization)."]]
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    max_length = Keyword.get(constraints, :max_length)
    trimmed = String.trim(value)
    normalized = Regex.replace(@strip_chars, trimmed, "")

    cond do
      trimmed == "" ->
        :error

      is_integer(max_length) and byte_size(trimmed) > max_length ->
        :error

      Regex.match?(@phone_regex, normalized) ->
        {:ok, normalized}

      true ->
        :error
    end
  end

  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints) when is_binary(value), do: {:ok, value}
  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints) when is_binary(value), do: {:ok, value}
  def dump_to_native(_other, _constraints), do: :error
end
