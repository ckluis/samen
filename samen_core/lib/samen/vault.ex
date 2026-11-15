defmodule Samen.Vault do
  @moduledoc """
  The PII vault runtime: write → per-subject-encrypted ciphertext + FK token in
  domain rows; default read → `%Masked{}`; a single `:reveal` chokepoint →
  plaintext; crypto-shred via the `Samen.Kms` adapter (ADR-001; doc D3/D5/D6/D7).

  ## The single reveal chokepoint (D5)

  `reveal/3` is the ONLY function in this module that returns subject plaintext.
  It is the one place `Kms.Crypto.decrypt/2` is called for a read, and the one
  place `Samen.Kms.unwrap/1` is called per value. `unwrap_subjects/1` is the only
  other read-side unwrap: it returns raw DEKs in a `Samen.Vault.DekMemo` that
  `reveal/3` accepts as `deks:` (see its docs for the single-use contract).
  Everything else (`load_masked/3`, JSON, CSV, logs) sees `%Masked{}`,
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
  alias Samen.Vault.{DekMemo, VaultRow}

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
    2. **Binds the caller-asserted subject to the token's REAL subject** — when a
       `:subject_id` opt is present (the accountability paths always thread it:
       `Samen.BreakGlass.reveal/1`, `Samen.Reveal.reveal/5`), it MUST equal the
       loaded `VaultRow.subject_id` or the reveal denies `{:error, :subject_mismatch}`
       BEFORE any decrypt. This closes the F4.1 accountability-evasion: without it,
       a caller could decrypt subject A's plaintext while the tamper-evident audit /
       breadth budget recorded subject B. The bind is at the single plaintext
       chokepoint, so every path through here is covered.
    3. Obtains the subject's DEK: a live `Samen.Kms.unwrap/1` (fails closed on shred /
       outage), or, when a `Samen.Vault.DekMemo` is passed as `:deks`, the DEK that memo
       already holds for this subject. The shred check IS the unwrap
       (`{:error, :shredded}`); `reveal/3` reads no other shred state. So the shred check
       runs once per SUBJECT per call when a memo is passed, once per value otherwise. A
       subject shredded after the memo was built can still be served for the remainder of
       THAT call, never by a later call. `reveal/3` has no audit or breadth ledger; the
       audited paths (`Samen.Reveal`, `Samen.BreakGlass`) never pass a memo.
    4. Decrypts the ciphertext.

  Returns `{:ok, plaintext}` or
  `{:error, :subject_mismatch | :shredded | :unavailable | :not_found}`.
  Post-shred and during a store outage it returns an error, never plaintext.

  `repo` is the Ecto repo to use for the vault row lookup. Must be provided.

  Options:
    * `:subject_id` — the subject the caller asserts this reveal is ABOUT. When
      present it is bound to the token's real subject (see step 2). When absent
      (raw internal callers, e.g. oracle scans), no bind is applied.
    * `:prefetched` — a `prefetch_rows/2` map; a row in it is used instead of a repo read.
    * `:deks` — a `Samen.Vault.DekMemo` from `unwrap_subjects/1`. SINGLE-USE: it holds raw
      DEKs and is valid only inside the resolve call that built it. Never store it (assign,
      GenServer state, ETS, job args, cache), never hand it across a process or call
      boundary: a stored memo would serve plaintext for a subject shredded since it was
      built. A memo presented by a process other than the one that built it is ignored
      (live unwrap); that does not stop same-process storage, which the source-scan test
      `Samen.VaultDekCallSiteScanTest` pins by call site.
  """
  @spec reveal(Masked.t(), Ecto.Repo.t(), keyword()) ::
          {:ok, binary()}
          | {:error, :subject_mismatch | :shredded | :unavailable | :not_found | term}
  def reveal(%Masked{token: token}, repo, opts \\ []) do
    reveal_token(
      token,
      repo,
      Keyword.get(opts, :subject_id),
      Keyword.get(opts, :prefetched),
      Keyword.get(opts, :deks)
    )
  end

  @doc """
  Are `pairs` (`[{field, token}]`, `field` anything with `:name` and `:vault`, i.e. a
  `Samen.Pii.Info.Field`) all bound to `subject_id`? ONE query for all tokens.

  A token is bound when its vault row's `subject_id` equals `subject_id` (the record's primary
  key), its `vault_name` equals the field's vault and its `field_name` equals the field's
  logical name: exactly what `store_fields/4` wrote. Returns `:ok` or
  `{:error, [{field_name, :not_found | :foreign_subject | :field_mismatch}]}`; the failures never
  carry a token. Used by `Samen.Vault.Change` for every `%Masked{}` a write sets that differs
  from the stored value.
  """
  @spec check_bindings([{map(), String.t()}], String.t(), Ecto.Repo.t()) ::
          :ok | {:error, [{atom(), :not_found | :foreign_subject | :field_mismatch}]}
  def check_bindings([], _subject_id, _repo), do: :ok

  def check_bindings(pairs, subject_id, repo) when is_list(pairs) do
    tokens = pairs |> Enum.map(fn {_field, token} -> token end) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    rows =
      case tokens do
        [] -> %{}
        _ -> repo.all(from(r in VaultRow, where: r.token in ^tokens)) |> Map.new(&{&1.token, &1})
      end

    failures =
      for {field, token} <- pairs,
          reason = binding_failure(Map.get(rows, token), subject_id, field),
          reason != nil,
          do: {field.name, reason}

    if failures == [], do: :ok, else: {:error, failures}
  end

  # nil = bound. Order matters: a missing row, then another subject's, then the right subject
  # but another vault/field.
  defp binding_failure(nil, _subject_id, _field), do: :not_found

  defp binding_failure(%VaultRow{subject_id: subject}, subject_id, _field) when subject != subject_id,
    do: :foreign_subject

  defp binding_failure(%VaultRow{vault_name: vault, field_name: name}, _subject_id, field) do
    if vault == to_string(field.vault) and name == to_string(field.name), do: nil, else: :field_mismatch
  end

  @doc """
  Read the vault rows of `tokens` in ONE query (ADR-052 §2.4.1 — no N+1 on a list or a replay
  frame): `%{token => %VaultRow{} | nil}`, a key for EVERY requested token (`nil` = no row).
  Ciphertext only — nothing is decrypted here. Pass the map to `reveal/3` as `prefetched:`;
  the decrypt and subject bind still happen per value in `reveal/3`; the shred check is the
  DEK unwrap, per value unless `deks:` is passed (see `unwrap_subjects/1`). Nothing is
  cached across calls: the caller holds the map for one resolve call.

  See `unwrap_subjects/1` for the per-call DEK reuse that rides on these rows.
  """
  @spec prefetch_rows([String.t()], Ecto.Repo.t()) :: %{String.t() => struct() | nil}
  def prefetch_rows(tokens, repo) when is_list(tokens) do
    tokens = tokens |> Enum.filter(&is_binary/1) |> Enum.uniq()

    found =
      case tokens do
        [] -> %{}
        _ -> repo.all(from(r in VaultRow, where: r.token in ^tokens)) |> Map.new(&{&1.token, &1})
      end

    Map.new(tokens, &{&1, Map.get(found, &1)})
  end

  @doc """
  Unwrap each DISTINCT subject of `rows` (a `prefetch_rows/2` map) ONCE: a `Samen.Vault.DekMemo`
  for one resolve call — one KMS unwrap per subject instead of per value (evaluation ARCH-2).
  Pass it to `reveal/3` as `deks:`.

  The memo is a value, not a cache: it lives in the caller's local `opts` for that one call and
  is unreachable after it (no process dictionary, ETS, `persistent_term` or TTL — a cross-call
  cache needs a shred-epoch invalidation design of its own). Only rows the caller already chose
  to decrypt should be passed, so a value the plane denies never triggers an unwrap. A failed
  unwrap is held as that subject's `{:error, _}` (denying only its values), never as a key.
  Entries are keyed `{adapter, subject_id}`; `reveal/3` takes a memoised DEK only for the
  subject of the row it is decrypting, under the adapter now configured. Subject binding and
  decryption stay per value in `reveal/3`. The shred check is the unwrap, so with a memo it runs
  once per subject per call: a subject shredded mid-call can still be served for the rest of
  THAT call, never after it. `reveal/3` and the `PiiResolution` path have no audit or breadth
  ledger (the audited `Samen.Reveal`/`BreakGlass` paths never take a memo).

  CONTRACT: the returned memo holds raw DEKs and is single-use. Use it inside the function
  that built it; never store it in an assign, process state, ETS, a job or a cache, and never
  pass it across a process or call boundary. The same holds for any `opts` that carry it
  (`Samen.Api.PiiResolution.prefetch/4`). `reveal/3` ignores a memo built by another process.
  """
  @spec unwrap_subjects(%{String.t() => struct() | nil}) :: DekMemo.t()
  def unwrap_subjects(rows) when is_map(rows) do
    adapter = Kms.adapter()

    # DISTINCT subjects first: the comprehension's `uniq` dedups results, not the unwrap calls.
    subjects =
      rows
      |> Enum.flat_map(fn
        {_token, %VaultRow{subject_id: subject_id}} when is_binary(subject_id) -> [subject_id]
        _ -> []
      end)
      |> Enum.uniq()

    entries = Map.new(subjects, &{{adapter, &1}, adapter.unwrap(&1)})

    DekMemo.new(entries)
  end

  # The subject's DEK: the call's memo when it holds THIS subject under the CURRENT adapter,
  # else a live unwrap (today's behaviour).
  defp unwrap_dek(subject_id, %DekMemo{} = memo) do
    adapter = Kms.adapter()

    # A memo built by another process is not this call's memo: ignore it (live unwrap).
    with true <- DekMemo.owned_by_caller?(memo),
         {:ok, result} <- DekMemo.fetch(memo, adapter, subject_id) do
      result
    else
      _ -> adapter.unwrap(subject_id)
    end
  end

  defp unwrap_dek(subject_id, _no_memo), do: Kms.adapter().unwrap(subject_id)

  defp reveal_token(token, repo, asserted_subject_id, prefetched, deks) do
    case fetch_row(token, repo, prefetched) do
      nil ->
        {:error, :not_found}

      %VaultRow{subject_id: subject_id, ciphertext: ciphertext} ->
        with :ok <- bind_subject(asserted_subject_id, subject_id),
             {:ok, dek} <- unwrap_dek(subject_id, deks) do
          do_decrypt(dek, ciphertext)
        end
    end
  end

  # A prefetched row is used only when it IS the row for this token (`prefetch_rows/2`'s
  # shape); anything else in the map — or a token it does not cover — is read from the repo.
  defp fetch_row(token, repo, %{} = prefetched) do
    case Map.fetch(prefetched, token) do
      {:ok, %VaultRow{token: ^token} = row} -> row
      {:ok, nil} -> nil
      _ -> repo.get(VaultRow, token)
    end
  end

  defp fetch_row(token, repo, _prefetched), do: repo.get(VaultRow, token)

  # F4.1 accountability bind: a caller-asserted subject MUST match the token's
  # real subject. `nil` (no assertion) is allowed for internal/raw callers; a
  # present-but-mismatched assertion fails closed BEFORE the DEK is touched, so
  # no PII for the real subject is ever produced under a wrong subject's audit.
  defp bind_subject(nil, _real), do: :ok
  defp bind_subject(same, same), do: :ok
  defp bind_subject(_asserted, _real), do: {:error, :subject_mismatch}

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

  Rides `Samen.Kms.shred/1` — the governed chokepoint that refuses a RESERVED
  synthetic subject (ADR-035 §4.1, e.g. `"sys:bidx"`, the blind-index HMAC key)
  before it ever reaches the adapter: `{:error, :reserved_subject}`.
  """
  @spec shred(String.t()) :: {:ok, Kms.attestation()} | {:error, :reserved_subject | term}
  def shred(subject_id), do: Kms.shred(subject_id)

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

    # Same direction as `scan_pitr_key_absent/2`: a failed probe (KMS outage) is not "no plaintext".
    leaks =
      Enum.flat_map(rows, fn token ->
        case probe_token(token, repo) do
          :decryptable -> [token]
          :clean -> []
          {:failed, reason} -> [probe_failed_message(token, reason)]
        end
      end)

    if leaks == [], do: {:ok, :no_plaintext}, else: {:leaks, leaks}
  end

  @doc """
  Oracle backup/PITR-history probe (T2.9, check 2): is the subject key ABSENT
  from a given DB tier / PITR snapshot repo, and does no ciphertext there decrypt?

  ADR-001's load-bearing claim: the per-subject key is an external KMS handle,
  NOT a Postgres row, so a PITR restore of any DB tier brings back ciphertext but
  never the key. This probe proves it against a specific `repo` (the live DB, the
  simulated replica, or a restored pg_dump snapshot from the T2.5 drill):

    1. Every `pii_vault` row for the subject carries a `ciphertext` binary and NO
       plaintext DEK — a wrapped DEK is never stored in Postgres (the vault schema
       has no key column). We assert there is no `wrapped_dek`-shaped column on
       `pii_vault` (fail closed if the schema ever grew one).
    2. Reveal against THIS repo's ciphertext denies (the key is not resurrectable
       from the snapshot) — the same `reveal_token/5` path, which routes through
       the external KMS adapter and returns `:shredded`/`:absent`/`:unavailable`
       post-shred.

  Returns `{:ok, :key_absent}` when the key is provably absent and no ciphertext
  decrypts; `{:leaks, details}` if a row decrypts or a key-shaped column exists.
  """
  @spec scan_pitr_key_absent(String.t(), Ecto.Repo.t()) ::
          {:ok, :key_absent} | {:leaks, [String.t()]}
  def scan_pitr_key_absent(subject_id, repo) do
    case key_shaped_columns(repo, "pii_vault") do
      {:ok, key_columns} ->
        scan_pitr_key_absent(subject_id, repo, key_columns)

      {:error, :unavailable} ->
        # A failed column probe is NOT "no key-shaped column": the old `rescue _ -> []` made this verifier answer
        # `{:ok, :key_absent}` (erasure proven) because the probe could not run. It fails closed instead.
        {:leaks, ["pii_vault key-material column probe FAILED — cannot prove the key is absent (fail closed)"]}
    end
  end

  defp scan_pitr_key_absent(subject_id, repo, key_columns) do
    # Only `:shredded` / `:absent` / `:not_found` prove the key is gone. `{:error, :unavailable}` (a KMS outage) or
    # any other failure is a PROBE failure, not "not decryptable": it used to read as proof of erasure.
    decryptable =
      repo.all(from(r in VaultRow, where: r.subject_id == ^subject_id, select: r.token))
      |> Enum.flat_map(fn token ->
        case probe_token(token, repo) do
          :decryptable -> ["decryptable ciphertext for token #{token}"]
          :clean -> []
          {:failed, reason} -> [probe_failed_message(token, reason)]
        end
      end)

    key_col_leaks =
      Enum.map(key_columns, fn col ->
        "pii_vault carries a key-material-shaped column '#{col}' — the wrapped DEK " <>
          "must NEVER be a Postgres row (ADR-001); a PITR restore would resurrect it."
      end)

    case decryptable ++ key_col_leaks do
      [] -> {:ok, :key_absent}
      leaks -> {:leaks, leaks}
    end
  end

  @clean_reveal_reasons [:shredded, :absent, :not_found]

  # :decryptable | :clean | {:failed, reason}
  defp probe_token(token, repo) do
    case reveal_token(token, repo, nil, nil, nil) do
      {:ok, _plaintext} ->
        :decryptable

      {:error, reason} when reason in @clean_reveal_reasons ->
        :clean

      {:error, reason} ->
        Samen.Observability.Failure.report(:vault_reveal_probe, nil, reason)
        {:failed, reason}
    end
  end

  defp probe_failed_message(token, reason),
    do: "key-absence probe FAILED for token #{token} (#{inspect(reason)}) — cannot prove the key is absent (fail closed)"

  # Columns on `table` whose name looks like it could hold key material. The vault
  # schema stores only `ciphertext`; a `wrapped_dek` / `dek` / `key`-named column
  # would mean the key entered the Postgres/PITR surface — a fail-closed leak.
  defp key_shaped_columns(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    rows
    |> List.flatten()
    |> Enum.filter(fn name ->
      n = String.downcase(to_string(name))
      String.contains?(n, "wrapped_dek") or n == "dek" or String.ends_with?(n, "_dek") or
        String.contains?(n, "master_key") or String.contains?(n, "key_material")
    end)
    |> then(&{:ok, &1})
  rescue
    e ->
      Samen.Observability.Failure.report(:vault_key_column_probe, nil, e)
      {:error, :unavailable}
  end

  @doc """
  Oracle wrong-key probe (T2.9): does any of `subject_id`'s vault ciphertext
  decrypt under a key OTHER than the (destroyed) subject key?

  The doc's DB-tier scan fails not only on plaintext / self-decryptable ciphertext
  but on "ciphertext that decrypts under any key other than the destroyed one" —
  the defence against a bug that re-wrapped a subject's ciphertext under a
  different, still-live subject key (which crypto-shred of the ORIGINAL key would
  not reach). This probe attempts every one of the subject's vault rows against
  every OTHER currently-active subject DEK in the store.

  Returns:
    * `{:ok, :no_cross_decrypt}` — no subject row decrypts under any foreign live
      key (the expected post-shred state);
    * `{:cross_decrypt, [%{token: t, under_subject: other_id}]}` — rows that DO
      decrypt under a foreign key (a violation);
    * `{:error, :unsupported}` — the adapter cannot enumerate its live keys
      (production `AwsKmsDynamo`); the caller records a documented seam, never a
      fake pass.
  """
  @spec scan_no_wrong_key(String.t(), Ecto.Repo.t()) ::
          {:ok, :no_cross_decrypt} | {:cross_decrypt, [map()]} | {:error, :unsupported | term}
  def scan_no_wrong_key(subject_id, repo) do
    adapter = Kms.adapter()

    if function_exported?(adapter, :list_active_subjects, 0) do
      case adapter.list_active_subjects() do
        {:ok, active_subjects} ->
          do_scan_no_wrong_key(subject_id, repo, active_subjects, adapter)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsupported}
    end
  end

  defp do_scan_no_wrong_key(subject_id, repo, active_subjects, adapter) do
    rows =
      repo.all(
        from(r in VaultRow,
          where: r.subject_id == ^subject_id,
          select: {r.token, r.ciphertext}
        )
      )

    # Every currently-live key that is NOT the erased subject's own.
    foreign_keys =
      active_subjects
      |> Enum.reject(&(&1 == subject_id))
      |> Enum.flat_map(fn other ->
        case adapter.unwrap(other) do
          {:ok, dek} -> [{other, dek}]
          _ -> []
        end
      end)

    # Route every decrypt attempt through the SINGLE reveal chokepoint
    # (`do_decrypt/2`) — never a second Crypto.decrypt/2 call site
    # (Samen.Chokepoint enforces exactly one).
    cross =
      for {token, ciphertext} <- rows,
          {other, dek} <- foreign_keys,
          match?({:ok, _}, do_decrypt(dek, ciphertext)),
          do: %{token: token, under_subject: other}

    if cross == [], do: {:ok, :no_cross_decrypt}, else: {:cross_decrypt, cross}
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

  @token_shape ~r/\Avt_[0-9a-f]{32}\z/

  @doc """
  Is `value` shaped like a token `generate_token/0` mints (`"vt_"` + 32 lowercase hex)?

  A grammar check ONLY: it says nothing about whether a `pii_vault` row exists or whom it
  belongs to (that is `check_bindings/3`). `Samen.Type.VaultField.dump_to_native/2` persists
  only token-shaped values, and `Samen.Vault.BindingScan` reads any other value in a vault
  column as plaintext at rest.
  """
  @spec token?(term()) :: boolean()
  def token?(value) when is_binary(value), do: Regex.match?(@token_shape, value)
  def token?(_other), do: false
end
