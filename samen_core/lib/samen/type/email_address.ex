defmodule Samen.Type.EmailAddress do
  @moduledoc """
  `Samen.Type.EmailAddress` — H3's single-value email scalar (ADR-036 D3;
  WS-H spec §H3), "for org-level, non-personal contact points."

  ## Storage shape

  `storage_type/1` is `:string`. The canonical value is a format-validated
  (RFC-ish) email address string.

  ## PII posture — PII-BY-DEFAULT, deliberately UNCLASSIFIED (ADR-036 D3)

  Unlike `Percent/Score/Duration/Priority/URL` (ADR-036 D2), this type does
  **NOT** export `samen_pii_class/0` at all, and carries **NO** type-level
  `Samen.NonPii.TypeClearance` entry. Per ADR-036 D3 verbatim: an org-level
  plaintext use is "being UNCLASSIFIED, masks-by-default until that specific
  column is cleared through the two-distinct-party `Samen.NonPii.register/1`."
  So `Samen.Pii.Classification.classify/1` falls through every precedence tier
  to the mask-unknown-by-default PII result (`Samen.Pii.Classification` step
  4) — deliberately, not by omission.

  This also means the escape hatch is structurally NOT type-level: even if a
  host misconfigured `config :samen_core, :non_pii_type_clearances` to name
  this module, it would have **zero effect** — `classify/1`'s `:non_pii`
  branch is gated on `self_class(module) == :non_pii`, and this module never
  claims that self-class. There is no config that can make a bare
  `Samen.Type.EmailAddress` column plaintext-by-type; only the PER-COLUMN
  `Samen.NonPii.register/1` (org-contact case) or vaulting via `pii_attribute`
  (personal case, the safe default) clears a specific column.

  ## Two usage shapes (ADR-036 D3)

    * **Personal (default, safe path):** `pii_attribute :email,
      Samen.Type.EmailAddress, vault: :pii_email` — the `VaultField` storage
      guard applies; the value is validated on input, tokenized at rest,
      `%Samen.Masked{}` on read.
    * **Org-level, non-personal** (e.g. a company's `support@`): a plaintext
      `attribute :billing_email, Samen.Type.EmailAddress` — masks-by-default
      until that specific column is cleared via `Samen.NonPii.register/1`.
  """
  use Ash.Type

  # RFC-ish (not full RFC 5322): local-part@domain, no whitespace, at least one
  # dot in the domain part — deliberately conservative (reject garbage) rather
  # than exhaustively RFC-compliant.
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @impl true
  def storage_type(_constraints), do: :string

  @impl true
  def constraints do
    [max_length: [type: :pos_integer, doc: "Optional maximum length."]]
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    max_length = Keyword.get(constraints, :max_length)
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        :error

      is_integer(max_length) and byte_size(trimmed) > max_length ->
        :error

      Regex.match?(@email_regex, trimmed) ->
        {:ok, trimmed}

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
