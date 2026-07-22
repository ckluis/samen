defmodule Samen.Type.URL do
  @moduledoc """
  `Samen.Type.URL` — H3's link scalar (ADR-036 D2/H3; WS-H spec §H3), a
  scheme/host-validating `Ash.Type` for an absolute URL.

  ## Storage shape

  `storage_type/1` is `:string`. The canonical value is the normalized
  absolute URL string (as given, once it has parsed to an absolute URL with an
  allowed scheme and a non-blank host).

  ## Constraints (ADR-036 §3 H3 table)

    * `:schemes`    — default `["http", "https"]`
    * `:max_length` — optional

  `cast_input/2` validates the value parses as an absolute URL (`URI.new/1`)
  with a non-blank host and a scheme in `:schemes` — FAILS `:error` on a
  relative URL, an unparseable string, an out-of-allowlist scheme (e.g.
  `javascript:`), or a length over `:max_length`.

  ## PII posture — non-PII BY DEFAULT, but see the personal-profile caveat (D2/H3)

  A URL (a marketing site, a docs link, a webhook target) is categorically
  **not** PII. This module self-classifies `:non_pii`, and `samen_core` SHIPS
  the two-distinct-party `Samen.NonPii.TypeClearance` entry that governs it —
  a bare `attribute :website, Samen.Type.URL` column is plaintext by default.

  **Personal-profile caveat (mirrors D3 — NOT a structural block, a usage
  rule):** a URL that *identifies a natural person* (a personal social/profile
  link) IS PII and must NOT live in a bare plaintext column — it must route
  through a vaulted `pii_attribute :x, Samen.Type.URL, vault: :pii_x`. The
  type's non-PII clearance does not prevent that: `pii_attribute` still
  vault-routes a `Samen.Type.URL` field exactly like any other logical type
  (the field materializes as `Samen.Type.VaultField`, per
  `Samen.Transformers.MaterializePii`), so the escape hatch for a personal URL
  is the SAME vault mechanism email/phone use — the type-level clearance means
  "URL columns are non-PII by default," never "every URL is always safe to
  leave plaintext" (ADR-036 §3 H3).
  """
  use Ash.Type

  @default_schemes ["http", "https"]

  @doc "Self-classification for `Samen.Pii.Classification`: a URL is non-PII by default (ADR-036 D2)."
  def samen_pii_class, do: :non_pii

  @impl true
  def storage_type(_constraints), do: :string

  @impl true
  def constraints do
    [
      schemes: [
        type: {:list, :string},
        default: @default_schemes,
        doc: "Allowed URL schemes."
      ],
      max_length: [type: :pos_integer, doc: "Optional maximum length."]
    ]
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    schemes = Keyword.get(constraints, :schemes, @default_schemes)
    max_length = Keyword.get(constraints, :max_length)

    cond do
      is_integer(max_length) and byte_size(value) > max_length ->
        :error

      true ->
        case URI.new(value) do
          {:ok, %URI{scheme: scheme, host: host}}
          when is_binary(scheme) and is_binary(host) and host != "" ->
            if scheme in schemes, do: {:ok, value}, else: :error

          _ ->
            :error
        end
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
