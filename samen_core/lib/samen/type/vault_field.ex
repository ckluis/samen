defmodule Samen.Type.VaultField do
  @moduledoc """
  The storage type of a vault-routed `pii_attribute` (T1.4/T1.5; Gate-0 vault-stack
  fix, mandatory P0 integration + correctness).

  This is the type `Samen.Transformers.MaterializePii` gives the **logical** PII
  attribute (`:full_name`, `:emails`, `:dob`, …). It is what makes the domain
  column hold a `vt_*` **token**, never plaintext, while the field's *normal
  value* on read is `%Samen.Masked{}`.

  ## The three faces of a vault field

    * **Input face** (`cast_input/2`): accepts *anything* the caller sets —
      a composite plaintext struct (`%Samen.Type.FullName{}`), a scalar plaintext
      (`~D[1990-01-01]`, `"MRN-1"`), or a `%Masked{}` (re-set of an already-masked
      value). A raw string is ALWAYS plaintext, even one that starts with `"vt_"`: no
      external decoder (form params, CSV, JSON, automation attrs, inbound mail) can
      produce a `%Masked{}`, so input can never NAME a token; `Samen.Vault.Change`
      binds any `%Masked{}` to the record's subject and field. Casting does NOT encrypt: encryption is a
      side-effecting operation that needs the subject key, so it happens in
      `Samen.Vault.Change` (a changeset change), never in a pure type callback.
      A plaintext value is held as `%Samen.Pii.Plaintext{}` until then, whose
      `Inspect` is `**redacted**` (ADR-052 §2.1).

    * **Stored face** (`cast_stored/2`): a value read back from Postgres is ALWAYS
      a `vt_*` token string (or `nil`). `cast_stored` turns it into `%Masked{}` —
      so `Ash.read` returns `%Masked{}` as the field's normal value with no
      per-resource read hook. Plaintext is available ONLY via
      `Samen.Vault.reveal/3` (the single decrypt chokepoint).

    * **Dump face** (`dump_to_native/2`): only a `%Masked{}` or a bare string that is
      TOKEN-SHAPED (`Samen.Vault.token?/1`) may be written to the column — both dump to
      the token string; anything else (including `"vt_ please help"`) is refused. A raw plaintext
      value reaching `dump_to_native` is a BUG (it means `Samen.Vault.Change` did
      not run / did not replace the value), so it FAILS CLOSED with `:error`
      rather than writing plaintext to the domain table. This is the last-line
      guard behind the change: the column can only ever receive a token.

  The physical column is `:string` (`storage_type/1`), holding the opaque token.
  """
  use Ash.Type

  alias Samen.Masked

  @impl true
  def storage_type(_constraints), do: :string

  @doc "Self-classification for `Samen.Pii.Classification`: a vault field is PII."
  def samen_pii_class, do: :pii

  # ---------------------------------------------------------------------------
  # Input: accept anything; encryption happens in Samen.Vault.Change, not here.
  # Only a %Masked{} (the internal "already vaulted" marker) passes through; EVERY other
  # value, a "vt_"-prefixed string included, is PLAINTEXT: it is wrapped in %Samen.Pii.Plaintext{} so `inspect(changeset)` — a log
  # line, a crash report, a FunctionClauseError blame — prints `**redacted**`, never the
  # value, in the window before the vault write (ADR-052 §2.1 item 3; Ash redacts a
  # sensitive changeset ARGUMENT but not a sensitive ATTRIBUTE).
  # ---------------------------------------------------------------------------
  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%Masked{} = masked, _constraints), do: {:ok, masked}
  def cast_input(value, _constraints), do: {:ok, Samen.Pii.Plaintext.wrap(value)}

  # ---------------------------------------------------------------------------
  # Stored → the field's normal value is %Masked{}. A stored value is always a
  # token string (what dump_to_native wrote). Presenting %Masked{} here is what
  # makes "no leak by omission" hold on every Ash.read path.
  # ---------------------------------------------------------------------------
  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(token, _constraints) when is_binary(token) do
    {:ok, Masked.new(token, :vault)}
  end

  def cast_stored(_other, _constraints), do: :error

  # ---------------------------------------------------------------------------
  # Dump: ONLY a token (or a %Masked{} wrapping one) may be persisted. Raw
  # plaintext reaching here means the Change did not run — fail closed, never
  # write plaintext to the domain column.
  # ---------------------------------------------------------------------------
  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(%Masked{token: token}, constraints), do: dump_token(token, constraints)

  def dump_to_native(token, constraints) when is_binary(token), do: dump_token(token, constraints)

  # A raw plaintext value reaching dump means Samen.Vault.Change did not replace
  # it with a token. Refuse — the domain column must never hold plaintext.
  def dump_to_native(_plaintext, _constraints), do: :error

  # The column holds only tokens `Samen.Vault.generate_token/0` could have minted. A
  # "vt_"-prefixed plaintext is NOT one: it would sit unencrypted in a column the oracle and
  # the CDC mirror treat as token-only.
  defp dump_token(token, _constraints) do
    if Samen.Vault.token?(token), do: {:ok, token}, else: :error
  end
end
