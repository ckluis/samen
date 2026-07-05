defmodule Samen.Vault do
  @moduledoc """
  The PII vault: write → per-subject-encrypted ciphertext + FK token; default
  read → `%Masked{}`; a single `:reveal` chokepoint → plaintext; crypto-shred
  via the `Samen.Kms` adapter (ADR-001; doc D3/D5/D6/D7).

  ## The single reveal chokepoint (D5/D6)

  `reveal/2` is the ONLY function in the system that returns subject plaintext.
  It is the one place `Samen.Kms.unwrap/1` + `Crypto.decrypt/2` are called for a
  read. Everything else (`load_person/1`, JSON, CSV, logs) sees `%Masked{}`,
  which holds no plaintext. Structural invariants (tested in
  `test/plaintext_leak_test.exs`):

    1. `Crypto.decrypt/2` for a vault read is called from exactly one function
       body (`do_decrypt/2`, invoked only by `reveal/2`).
    2. `%Masked{}` never contains plaintext, so no serialization path can emit
       it "by omission."

  ## Crypto-shred (D7)

  `shred/1` calls `Samen.Kms.shred/1`, destroying the subject's DEK. After that,
  `reveal/2` returns `{:error, :shredded}` for every vault row of that subject —
  live, replica, backup/PITR, everywhere — because the *key* is gone, not the
  ciphertext (ADR-001 §7).
  """

  alias Samen.Kms
  alias Samen.Kms.Crypto
  alias Samen.Masked
  alias Samen.Repo
  alias Samen.Vault.{Person, PiiEmail}

  import Ecto.Query, only: [from: 2]

  @doc """
  Ensure a subject has a wrapped DEK. Idempotent-ish for the spike: generates
  one if the KMS has none.
  """
  @spec ensure_subject_key(String.t()) :: :ok | {:error, term}
  def ensure_subject_key(subject_id) do
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
  Store an email into the vault for `subject_id` and return a domain `Person`
  row carrying the FK token (no plaintext on the domain row). Encrypts under the
  subject's DEK.
  """
  @spec store_email(String.t(), String.t(), String.t()) ::
          {:ok, Person.t()} | {:error, term}
  def store_email(subject_id, display_name, email_plaintext) do
    with :ok <- ensure_subject_key(subject_id),
         {:ok, dek} <- Kms.adapter().unwrap(subject_id) do
      token = "vt_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
      ciphertext = Crypto.encrypt(dek, email_plaintext)

      %PiiEmail{}
      |> Ecto.Changeset.change(
        token: token,
        subject_id: subject_id,
        ciphertext: ciphertext,
        label: "email"
      )
      |> Repo.insert!()

      attrs = %{subject_id: subject_id, display_name: display_name, pii_email_token: token}

      %Person{}
      |> Person.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, person} -> {:ok, materialize(person)}
        error -> error
      end
    end
  end

  @doc """
  Default read: load a domain row and materialize its PII field as `%Masked{}`.
  This is the normal path — plaintext is NOT produced here.
  """
  @spec load_person(String.t()) :: Person.t() | nil
  def load_person(id) do
    case Repo.get(Person, id) do
      nil -> nil
      person -> materialize(person)
    end
  end

  @doc "Materialize a raw domain row: set `email` to its `%Masked{}` normal value."
  @spec materialize(Person.t()) :: Person.t()
  def materialize(%Person{pii_email_token: token} = person) when is_binary(token) do
    %{person | email: Masked.new(token, :email)}
  end

  def materialize(%Person{} = person), do: person

  # =====================================================================
  # THE SINGLE REVEAL CHOKEPOINT — the only path that returns plaintext.
  # =====================================================================

  @doc """
  Reveal the plaintext email for a `%Masked{}` value or a `Person`.

  This is the **one** chokepoint. It:
    1. resolves the vault row for the token,
    2. unwraps the subject's DEK via the KMS adapter (fails closed on shred /
       outage),
    3. decrypts the ciphertext.

  Returns `{:ok, plaintext}` or `{:error, :shredded | :unavailable | :not_found}`.
  Post-shred and during a store outage it returns an error, never plaintext.
  """
  @spec reveal(Masked.t() | Person.t(), keyword()) ::
          {:ok, String.t()} | {:error, :shredded | :unavailable | :not_found | term}
  def reveal(masked_or_person, _opts \\ [])

  def reveal(%Masked{token: token}, _opts), do: reveal_token(token)

  def reveal(%Person{pii_email_token: token}, _opts) when is_binary(token),
    do: reveal_token(token)

  def reveal(%Person{}, _opts), do: {:error, :not_found}

  defp reveal_token(token) do
    case Repo.get(PiiEmail, token) do
      nil ->
        {:error, :not_found}

      %PiiEmail{subject_id: subject_id, ciphertext: ciphertext} ->
        with {:ok, dek} <- Kms.adapter().unwrap(subject_id) do
          do_decrypt(dek, ciphertext)
        end
    end
  end

  # The ONLY call site of Crypto.decrypt/2 for a vault read. A second decrypt
  # path anywhere else is a structural violation (see plaintext_leak_test).
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
  The J2 trace-sink pseudonym `actor_id = HMAC(psk_S, subject_id)` for a
  subject, keyed off the SAME DEK. Fails `:shredded` after shred (RQ5).
  """
  @spec pseudonym(String.t()) :: {:ok, binary()} | {:error, :shredded | term}
  def pseudonym(subject_id), do: Kms.adapter().pseudonym(subject_id, subject_id)

  @doc "Attestation for the destruction oracle (check 3)."
  @spec attest(String.t()) :: {:ok, Kms.attestation()} | {:error, term}
  def attest(subject_id), do: Kms.adapter().attest(subject_id)

  @doc """
  Oracle-style scan (spike scope): does any decryptable plaintext remain for
  `subject_id` across the vault rows? Returns `{:ok, :no_plaintext}` when every
  ciphertext row for the subject is undecryptable (post-shred), else lists the
  tokens that still decrypt.
  """
  @spec scan_no_plaintext(String.t()) :: {:ok, :no_plaintext} | {:leaks, [String.t()]}
  def scan_no_plaintext(subject_id) do
    rows =
      Repo.all(from p in PiiEmail, where: p.subject_id == ^subject_id, select: p.token)

    leaks =
      Enum.filter(rows, fn token ->
        match?({:ok, _plaintext}, reveal_token(token))
      end)

    if leaks == [], do: {:ok, :no_plaintext}, else: {:leaks, leaks}
  end
end
