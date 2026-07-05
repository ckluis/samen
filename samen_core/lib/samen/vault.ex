defmodule Samen.Vault do
  @moduledoc """
  The PII vault runtime: write → per-subject-encrypted ciphertext + FK token in
  domain rows; default read → `%Masked{}`; a single `:reveal` chokepoint →
  plaintext; crypto-shred via the `Samen.Kms` adapter (ADR-001; doc D3/D5/D6/D7).

  ## The single reveal chokepoint (D5)

  `reveal/3` is the ONLY function in this module that returns subject plaintext.
  It is the one place `Samen.Kms.unwrap/1` + `Kms.Crypto.decrypt/2` are called
  for a read. Everything else (`load_masked/3`, JSON, CSV, logs) sees `%Masked{}`,
  which holds no plaintext. Structural invariants:

    1. `Kms.Crypto.decrypt/2` for a vault read is called from exactly one private
       function body (`do_decrypt/2`), invoked only by `reveal/3`.
    2. `%Masked{}` never contains plaintext, so no serialization path can emit
       it "by omission."

  ## Crypto-shred (D7)

  `shred/1` calls `Samen.Kms.shred/1`, destroying the subject's DEK. After that,
  `reveal/3` returns `{:error, :shredded}` for every vault row of that subject —
  live, replica, backup/PITR, everywhere — because the *key* is gone, not the
  ciphertext (ADR-001 §7).

  ## Vault routing and the T1.3 DSL (what is actually wired)

  The vault runtime is wired to the DSL declarations via `Samen.Pii.Info`.

  **Write is transparent** and IS built: `Samen.Vault.Change` — a global
  `Ash.Resource.Change` that `Samen.Transformers.MaterializePii` injects into every
  resource with a `pii do` block — intercepts the real Ash `create`/`update`
  actions. In a `before_action`, for each `pii_attribute` the changeset sets, it:
    1. Resolves the subject_id (the resource's primary key) and ensures the
       subject has a wrapped DEK in the KMS adapter.
    2. Encrypts the plaintext field value into a `pii_vault` row via
       `store_fields/4`.
    3. Replaces the changeset attribute value with the opaque `vt_*` FK token
       (`force_change_attribute`), so the domain column receives ONLY the token.

  **Read presents `%Masked{}` by construction**, not by a per-resource hook: the
  vault-routed column is typed `Samen.Type.VaultField`, whose `cast_stored/2` turns
  the stored token into `%Masked{}`. So `Ash.read` returns `%Masked{}` as the
  field's normal value. `materialize/2` remains for callers holding a raw
  (non-Ash) struct, but the Ash read path is covered by the type. Plaintext is
  available only via `reveal/3`.

  **The last-line guard is fail-closed:** `Samen.Type.VaultField.dump_to_native/2`
  refuses to persist anything that is not already a `vt_*` token, so even a bug
  that skipped `Samen.Vault.Change` cannot write plaintext to the domain column —
  the insert fails instead.

  ## Adapter configuration

  The KMS adapter is `Samen.Kms.adapter()` — configurable via
  `Application.put_env(:samen_core, :kms_adapter, SomeModule)`. Default is
  `Samen.Kms.FileBacked` for tests; switch to `Samen.Kms.InMemory` for
  unit tests that do not need the PITR physical proof.
  """

  alias Samen.Kms
  alias Samen.Kms.Crypto
  alias Samen.Masked
  alias Samen.Vault.VaultRow

  import Ecto.Query, only: [from: 2]

  @doc """
  Ensure a subject has a wrapped DEK in the KMS adapter. Idempotent: if the
  subject already has an active key, this is a no-op. Generates one if absent.
  """
  @spec ensure_subject_key(String.t(), Ecto.Repo.t()) :: :ok | {:error, term}
  def ensure_subject_key(subject_id, _repo) do
    case Kms.adapter().attest(subject_id) do
      {:ok, %{state: :active}} ->
        :ok

      _ ->
        case Kms.adapter().generate_subject_key(subject_id) do
          {:ok, _wrapped} -> :ok
          error -> error
        end
    end
  end

  @doc """
  Store a PII field value into the vault for `subject_id`. Returns the opaque
  FK token (a `"vt_*"` string) that goes into the domain row's token column.

  Encrypts under the subject's DEK per ADR-001 §2.
  """
  @spec store_field(String.t(), atom(), atom(), binary(), Ecto.Repo.t()) ::
          {:ok, String.t()} | {:error, term}
  def store_field(subject_id, vault_name, field_name, plaintext, repo) do
    with :ok <- ensure_subject_key(subject_id, repo),
         {:ok, dek} <- Kms.adapter().unwrap(subject_id) do
      token = generate_token()
      ciphertext = Crypto.encrypt(dek, plaintext)

      %VaultRow{}
      |> Ecto.Changeset.change(
        token: token,
        subject_id: subject_id,
        vault_name: to_string(vault_name),
        field_name: to_string(field_name),
        ciphertext: ciphertext,
        label: "#{vault_name}/#{field_name}"
      )
      |> repo.insert!()

      {:ok, token}
    end
  end

  @doc """
  Store multiple PII field values for a subject in one call. Returns a map of
  `field_name => token` for all stored fields. Used by `Samen.Vault.Change` to
  process all pii_attributes in a changeset at once.
  """
  @spec store_fields(String.t(), atom(), [{atom(), binary()}], Ecto.Repo.t()) ::
          {:ok, %{atom() => String.t()}} | {:error, term}
  def store_fields(subject_id, vault_name, fields, repo) do
    with :ok <- ensure_subject_key(subject_id, repo),
         {:ok, dek} <- Kms.adapter().unwrap(subject_id) do
      tokens =
        Map.new(fields, fn {field_name, plaintext} ->
          token = generate_token()
          ciphertext = Crypto.encrypt(dek, plaintext)

          %VaultRow{}
          |> Ecto.Changeset.change(
            token: token,
            subject_id: subject_id,
            vault_name: to_string(vault_name),
            field_name: to_string(field_name),
            ciphertext: ciphertext,
            label: "#{vault_name}/#{field_name}"
          )
          |> repo.insert!()

          {field_name, token}
        end)

      {:ok, tokens}
    end
  end

  @doc """
  Materialize a domain struct read OUTSIDE the Ash type path (e.g. a raw
  non-Ash query that returns the token string in the field): replace each
  vault-routed field that still holds a raw `vt_*` token with `%Masked{}`.

  The normal Ash read path does NOT need this — `Samen.Type.VaultField.cast_stored/2`
  already presents `%Masked{}`. This helper is only for callers holding a struct
  whose vault fields are still raw token strings. Already-`%Masked{}` and `nil`
  fields are left unchanged. No-op if the resource has no pii_attributes.
  """
  @spec materialize(struct(), module()) :: struct()
  def materialize(record, resource_module) do
    pii_fields = Samen.Pii.Info.fields(resource_module)

    Enum.reduce(pii_fields, record, fn field, acc ->
      case Map.get(acc, field.name) do
        "vt_" <> _ = token ->
          Map.put(acc, field.name, Masked.new(token, field.name))

        _ ->
          acc
      end
    end)
  end

  # =====================================================================
  # THE SINGLE REVEAL CHOKEPOINT — the only path that returns plaintext.
  # =====================================================================

  @doc """
  Reveal the plaintext for a `%Masked{}` value.

  This is the **one** chokepoint. It:
    1. Looks up the vault row for the token.
    2. Unwraps the subject's DEK via the KMS adapter (fails closed on shred /
       outage).
    3. Decrypts the ciphertext.

  Returns `{:ok, plaintext}` or `{:error, :shredded | :unavailable | :not_found}`.
  Post-shred and during a store outage it returns an error, never plaintext.

  `repo` is the Ecto repo to use for the vault row lookup. Must be provided.
  """
  @spec reveal(Masked.t(), Ecto.Repo.t(), keyword()) ::
          {:ok, binary()} | {:error, :shredded | :unavailable | :not_found | term}
  def reveal(%Masked{token: token}, repo, _opts \\ []) do
    reveal_token(token, repo)
  end

  defp reveal_token(token, repo) do
    case repo.get(VaultRow, token) do
      nil ->
        {:error, :not_found}

      %VaultRow{subject_id: subject_id, ciphertext: ciphertext} ->
        with {:ok, dek} <- Kms.adapter().unwrap(subject_id) do
          do_decrypt(dek, ciphertext)
        end
    end
  end

  # The ONLY call site of Crypto.decrypt/2 for a vault read. A second decrypt
  # path anywhere else is a structural violation caught by the C3 pii_reads verifier
  # and by the plaintext-leak structural test in T1.4.
  defp do_decrypt(dek, ciphertext) do
    case Crypto.decrypt(dek, ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> {:error, :decrypt_failed}
    end
  end

  # =====================================================================
  # Crypto-shred (D7)
  # =====================================================================

  @doc """
  Crypto-shred a subject: destroy the DEK via the KMS adapter. All of that
  subject's vault ciphertext becomes permanently undecryptable across every
  tier at once, and the trace-sink pseudonym becomes unrecomputable (RQ5).
  Returns the KMS attestation.
  """
  @spec shred(String.t()) :: {:ok, Kms.attestation()} | {:error, term}
  def shred(subject_id), do: Kms.adapter().shred(subject_id)

  @doc """
  Attestation for the destruction oracle (oracle check 3).

  Oracle semantics per ADR-001 §5:
  - `:shredded` with `destroyed_at` = PASS
  - `:active` when expected erased = FAIL (oracle exits 1)
  - `:absent` = FAIL — positive tombstone required (ADR-001 red path 3)
  """
  @spec attest(String.t()) :: {:ok, Kms.attestation()} | {:error, term}
  def attest(subject_id), do: Kms.adapter().attest(subject_id)

  @doc """
  The J2 trace-sink pseudonym `actor_id = HMAC(psk_S, subject_id)` for a
  subject, keyed off the SAME DEK. Fails `:shredded` after shred (RQ5).
  """
  @spec pseudonym(String.t()) :: {:ok, binary()} | {:error, :shredded | term}
  def pseudonym(subject_id), do: Kms.adapter().pseudonym(subject_id, subject_id)

  @doc """
  Oracle-style scan: does any decryptable plaintext remain for `subject_id`
  across the vault rows in `repo`? Returns `{:ok, :no_plaintext}` when every
  ciphertext row for the subject is undecryptable (post-shred), else lists the
  tokens that still decrypt.

  Used by the destruction oracle (T2.9) in its DB-tier content scan.
  """
  @spec scan_no_plaintext(String.t(), Ecto.Repo.t()) ::
          {:ok, :no_plaintext} | {:leaks, [String.t()]}
  def scan_no_plaintext(subject_id, repo) do
    rows =
      repo.all(from(r in VaultRow, where: r.subject_id == ^subject_id, select: r.token))

    leaks =
      Enum.filter(rows, fn token ->
        match?({:ok, _plaintext}, reveal_token(token, repo))
      end)

    if leaks == [], do: {:ok, :no_plaintext}, else: {:leaks, leaks}
  end

  @doc """
  Whether the configured KMS adapter's backup/PITR is disabled (oracle check 2).

  For the dev adapters (InMemory, FileBacked) this is always `true` by
  construction. For AwsKmsDynamo in production, this calls
  `DescribeContinuousBackups` and returns `false` if PITR is accidentally
  enabled — which must cause the oracle's check-2 to exit non-zero (ADR-001
  §8.2 red path 6).
  """
  @spec backups_disabled?() :: boolean()
  def backups_disabled?, do: Kms.adapter().backups_disabled?()

  # =====================================================================
  # Helpers
  # =====================================================================

  @doc false
  @spec generate_token() :: String.t()
  def generate_token do
    "vt_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end
end
