defmodule Samen.Gen.FieldTypeMenu do
  @moduledoc """
  H7 (ADR-036 §3 H7; T15 done-criteria 1/2): the FULL type menu `mix
  samen.gen.resource --field-type <kind>` offers for the scaffolded resource's
  ONE scalar `pii do` vault field — every H1-H5 `Ash.Type` T12/T13/T14 landed
  (`Money`/`Percent`/`Score`/`Duration`/`Priority`/`URL`/`EmailAddress`/
  `PhoneNumber`/`Address`), plus the pre-existing bare `:string` (the default —
  `--field-type` omitted is byte-identical to pre-T15 output).

  ## The migration DOES need a per-type column NAME (attempt-2 fix)

  A `pii_attribute` ALWAYS materializes as a `Samen.Type.VaultField` column
  (`Samen.Transformers.MaterializePii`) regardless of its declared LOGICAL
  type — the physical column is always `:text`, holding a `vt_*` token — but
  its NAME is not uniform. `MaterializePii.source_for/2` gives a SCALAR
  `pii_attribute` the `pii_<abbrev>_<name>` prefix, while a COMPOSITE PII type
  (one whose `samen_pii_class => :pii` AND `storage_type/1` is `:map`/`:array`
  — currently only `Samen.Type.Address` in this menu) routes by vault name
  with NO `pii_` prefix: `<abbrev>_<name>` (the SAME convention
  `FullName`/`Emails`/`Phones` use — see `Samen.Type.Address`'s own moduledoc
  "PII routing note"). `composite?/1` + `vault_column/2` below mirror
  `MaterializePii`'s OWN `composite_pii?/1`/`composite_storage?/1` predicates
  exactly (calling the real `Samen.Pii.Classification.classify/1` +
  `storage_type/1`, not a hand-maintained "just address" list) so this can
  never silently drift from the transformer it must match.

  **T15 attempt-1 defect (fixed here):** the migration template unconditionally
  emitted `add(:pii_<abbrev>_secret, :text)` for every menu entry. For
  `--field-type address` the resource's REAL materialized column is
  `<abbrev>_secret` (no `pii_` prefix) — the migration created the WRONG
  physical column, so `catalog_sync` (which reads the resource's declared
  `source`) registered a `fld_field` row for a column that did not exist in
  the table, and `mix samen.verify.catalog_parity` correctly flagged the
  mismatch. `gen_resource_type_menu_probe.exs` (done-criterion 2) was
  DESIGNED to catch exactly this — it could not run until a concurrent task
  (T06x) fixed an unrelated abbrev collision that was blocking ALL THREE
  `gen_app` probes upstream of this one ever reaching this check.

  ## Two independent sample slots

  * `dynamic_sample/2` — the `policy_matrix_test`/`rbac_red_path_test` value,
    embedded inside a `fn org_id -> n = System.unique_integer(...); %{... secret:
    HERE} end` closure. For `"string"` this preserves the pre-existing
    `"SECRET-<abbrev>-\#{n}"` runtime-interpolated shape (the literal `\#{n}` is
    real Elixir source text the EMITTED test evaluates, not this generator);
    every other kind uses a FIXED, type-valid literal (per-row uniqueness of a
    vaulted secret is not load-bearing for those tests).
  * `vault_sample/2` + `vault_plaintext/2` — `vault_routing_test`'s OWN fixed
    literal, used BOTH as the create attrs value and as the plaintext-hunt
    marker searched for absence in the raw row / vault ciphertext (mirrors the
    pre-existing `"VAULT-PLAINTEXT-<abbrev>-hunt"` used for both purposes) — kept
    a DIFFERENT literal family from `dynamic_sample` purely so the two files'
    fixtures never accidentally collide, not because it's required.

  Every returned `*_sample` value is Elixir SOURCE TEXT (a valid RHS
  expression, already quoted where it needs to be) — the templates splice it
  in verbatim as `secret: <%= ... %>`.
  """

  @menu ~w(string money percent score duration priority url email phone address)

  @doc "The full ordered type menu — the `--field-type` allowlist."
  @spec menu() :: [String.t()]
  def menu, do: @menu

  @doc "True if `field_type` is a member of the menu."
  @spec valid?(String.t()) :: boolean()
  def valid?(field_type), do: field_type in @menu

  @doc "The Elixir type expression for the resource's `pii_attribute` declaration."
  @spec ash_type(String.t()) :: String.t()
  def ash_type("string"), do: ":string"
  def ash_type("money"), do: "Samen.Type.Money"
  def ash_type("percent"), do: "Samen.Type.Percent"
  def ash_type("score"), do: "Samen.Type.Score"
  def ash_type("duration"), do: "Samen.Type.Duration"
  def ash_type("priority"), do: "Samen.Type.Priority"
  def ash_type("url"), do: "Samen.Type.URL"
  def ash_type("email"), do: "Samen.Type.EmailAddress"
  def ash_type("phone"), do: "Samen.Type.PhoneNumber"
  def ash_type("address"), do: "Samen.Type.Address"

  @doc """
  True when `field_type`'s `pii_attribute` materializes via
  `Samen.Transformers.MaterializePii`'s COMPOSITE routing (no `pii_` column
  prefix) rather than the scalar `pii_<abbrev>_<name>` shape. Mirrors the
  transformer's own `composite_pii?/1` exactly — a type self-classifies `:pii`
  (always-honored, e.g. `Samen.Type.Address` — D4) AND its `storage_type/1` is
  `:map`/`:array`. Currently true only for `"address"`, but computed from the
  REAL type module (not hardcoded) so a future composite menu addition stays
  correct by construction.
  """
  @spec composite?(String.t()) :: boolean()
  def composite?("string"), do: false

  def composite?(field_type) do
    module = field_type |> ash_type() |> String.split(".") |> Module.concat()
    Samen.Pii.Classification.classify(module) == :pii and composite_storage?(module)
  end

  defp composite_storage?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :storage_type, 1) and
      module.storage_type([]) in [:map, :array, {:array, :map}]
  end

  @doc """
  The physical vault column name for the resource's ONE `:secret`
  `pii_attribute`, matching `Samen.Transformers.MaterializePii.source_for/2`
  exactly: `pii_<abbrev>_secret` for a scalar menu type, `<abbrev>_secret`
  (no `pii_` prefix) for a composite one.
  """
  @spec vault_column(String.t(), String.t()) :: String.t()
  def vault_column(field_type, abbrev) do
    if composite?(field_type), do: "#{abbrev}_secret", else: "pii_#{abbrev}_secret"
  end

  @doc "The policy_matrix_test / rbac_red_path_test sample (Elixir source text)."
  @spec dynamic_sample(String.t(), String.t()) :: String.t()
  def dynamic_sample("string", abbrev), do: "\"SECRET-#{abbrev}-\#{n}\""
  def dynamic_sample("money", _abbrev), do: "\"USD 12.34\""
  def dynamic_sample("percent", _abbrev), do: "\"42.5\""
  def dynamic_sample("score", _abbrev), do: "\"87\""
  def dynamic_sample("duration", _abbrev), do: "\"PT1H30M\""
  def dynamic_sample("priority", _abbrev), do: "\"high\""
  def dynamic_sample("url", abbrev), do: "\"https://example.test/#{abbrev}\""
  def dynamic_sample("email", abbrev), do: "\"secret-#{abbrev}@example.test\""
  def dynamic_sample("phone", _abbrev), do: "\"+15550100100\""

  def dynamic_sample("address", _abbrev),
    do:
      ~s(%{line1: "123 Test St", city: "Testville", region: "TS", postal_code: "00000", country: "US"})

  @doc """
  The vault_routing_test create-attrs sample (Elixir source text).

  Attempt-2 fix: `vault_routing`'s red path scans the WHOLE raw row (id,
  org_id — random UUIDs — and inserted_at/updated_at timestamps included) for
  each `plaintexts` marker as a bare substring. A SHORT, purely-numeric marker
  (the original `score: "64"`) has a real, empirically-confirmed chance of
  coincidentally appearing inside an unrelated column's random bytes/digits —
  a false "leak" that flakes the probe, not a masking defect. Every sample
  below is now either naturally long/lettered (money/url/email/phone/address —
  already safe) or, for the types the Ash constraint genuinely caps at a tiny
  numeric range (`score`: integer 0-100; `percent`: 2-decimal 0-100.00), value
  ITSELF cannot carry more entropy — so those two use their type's WIDEST
  available representation (`score`'s max `100`; `percent`'s full 2-decimal
  precision `73.42`) to minimize (not eliminate) the same class of collision.
  `duration` has no upper bound, so it uses a long, high-entropy second count
  instead of a short round number.
  """
  @spec vault_sample(String.t(), String.t()) :: String.t()
  def vault_sample("string", abbrev), do: "\"VAULT-PLAINTEXT-#{abbrev}-hunt\""
  def vault_sample("money", _abbrev), do: "\"EUR 500123.87\""
  def vault_sample("percent", _abbrev), do: "\"73.42\""
  def vault_sample("score", _abbrev), do: "\"100\""
  def vault_sample("duration", _abbrev), do: "\"918273645\""
  def vault_sample("priority", _abbrev), do: "\"urgent\""
  def vault_sample("url", abbrev), do: "\"https://vault.example.test/#{abbrev}\""
  def vault_sample("email", abbrev), do: "\"vault-#{abbrev}@example.test\""
  def vault_sample("phone", _abbrev), do: "\"+15559998888\""

  def vault_sample("address", _abbrev),
    do:
      ~s(%{line1: "999 Vault Ave", city: "Cryptoville", region: "CV", postal_code: "11111", country: "US"})

  @doc """
  The RAW (unquoted) plaintext substring `vault_routing_test` hunts for absence
  of in the raw domain row + vault ciphertext — must be a genuine substring of
  whatever `vault_sample/2` writes (see that function's moduledoc for the
  attempt-2 collision-risk fix).
  """
  @spec vault_plaintext(String.t(), String.t()) :: String.t()
  def vault_plaintext("string", abbrev), do: "VAULT-PLAINTEXT-#{abbrev}-hunt"
  def vault_plaintext("money", _abbrev), do: "EUR 500123.87"
  def vault_plaintext("percent", _abbrev), do: "73.42"
  def vault_plaintext("score", _abbrev), do: "100"
  def vault_plaintext("duration", _abbrev), do: "918273645"
  def vault_plaintext("priority", _abbrev), do: "urgent"
  def vault_plaintext("url", abbrev), do: "https://vault.example.test/#{abbrev}"
  def vault_plaintext("email", abbrev), do: "vault-#{abbrev}@example.test"
  def vault_plaintext("phone", _abbrev), do: "+15559998888"
  def vault_plaintext("address", _abbrev), do: "999 Vault Ave"
end
