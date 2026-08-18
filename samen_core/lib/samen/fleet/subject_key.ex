defmodule Samen.Fleet.SubjectKey do
  @moduledoc """
  `fleet_subject_key(app_id)` — the per-product HMAC key `Samen.Fleet.Handle` uses to
  compute `fleet_handle = HMAC(fleet_subject_key(app_id), org_id)` (ADR-044 §5.3,
  amended §16.2 — carried-LOW 2, T82-owned custody statement).

  ## Custody (binding, ADR §16.2)

  Per-product, product-held, KMS-wrapped via the SAME `Samen.Kms` wrap hierarchy
  every other subject key uses (ADR-001) — **never** a plaintext column, **never**
  logged, and **never sent to the cockpit** (the cockpit must remain structurally
  unable to relate a wire handle to an `org_id`; only the owning product ever calls
  `unwrap/1`). This module never returns the raw key to a caller outside the owning
  product's process — `hmac/2` computes the digest in-process and returns only the
  16-byte handle.

  ## Reserved-subject treatment (never erasure-swept)

  `app_id` is a PRODUCT identifier, not a real PII subject — shredding it would break
  a shared mechanism (every tenant's handle in one product), not destroy one
  subject's data, exactly the `"sys:bidx"` precedent `Samen.Kms` already carries.
  Subject ids in the `"flt:subject:"` namespace are added to `Samen.Kms`'s
  `reserved_subject?/1` (a small, additive, backward-compatible edit) so the standing
  per-subject erasure sweep / destruction oracle skip them exactly like `"sys:bidx"`.

  ## Stability + rotation (ADR §16.2)

  The key must be stable for the lifetime of every stored report: **rotating it
  silently re-keys every handle** — handles already stored in `flt_report` were
  computed under the old key, recomputation under the new key matches nothing, and
  every tier-2 row in the cockpit masks until each app re-reports (30-day stored
  history permanently unresolvable under the old key). Rotation does **not** break
  access control (ADR §16.4a: the drill-in gate tests `org_id ∈ scope_of/2` directly
  and never touches this key) — it degrades only cockpit-side handle resolution and
  the relabeling of stored reports. `handle_key_version/1` is the additive `:number`
  field (inside §5.1's class discipline — does not reopen the wire's INV-2 proof)
  that makes a rotation an EXPLICIT, operator-visible operation rather than a silent
  config change: a report's `handle_key_version` names which key version its handles
  were computed under, so the cockpit can show *"handles computed under key v1 —
  rotated to v2; re-report to resolve"* instead of silently mismatching.
  """

  @subject_prefix "flt:subject:"

  @doc "The reserved KMS subject id for `app_id`'s fleet handle key."
  @spec subject_id(String.t()) :: String.t()
  def subject_id(app_id) when is_binary(app_id), do: @subject_prefix <> app_id

  @doc "The subject-id namespace prefix `Samen.Kms.reserved_subject?/1` matches on."
  @spec subject_prefix() :: String.t()
  def subject_prefix, do: @subject_prefix

  @doc """
  The current `fleet_subject_key(app_id)` handle-key version this process is
  configured for. Additive `:number` field (§5.1 class discipline), incremented by an
  explicit operator-visible rotation (never silent). Defaults to `1`.
  """
  @spec handle_key_version(keyword()) :: pos_integer()
  def handle_key_version(opts \\ []) do
    Keyword.get(opts, :version) ||
      Application.get_env(:samen_core, __MODULE__, []) |> Keyword.get(:handle_key_version, 1)
  end

  @doc """
  Fetch (provisioning on first use) the raw fleet subject key for `app_id`, unwrapped
  through the configured `Samen.Kms` adapter. Returns `{:ok, dek}` or
  `{:error, :not_configured | :shredded | :unavailable | term()}` — fail-honest: no
  KMS adapter configured never returns a fabricated key.

  The raw key NEVER leaves this module's callers' immediate stack frame into any
  wire payload, log line, or cockpit-bound value — only `hmac/2` (below) is meant to
  consume it.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch(app_id, opts \\ []) when is_binary(app_id) do
    # The KMS wrap SEAM always resolves (defaults to Samen.Kms.FileBacked — the
    # keyless/fail-honest local fake every other subject key uses; ADR-014/024/026).
    # "Unconfigured" in the fleet's fail-honest sense is the CREDENTIAL layer above
    # this (Samen.Fleet.Credential), not the KMS wrap itself.
    kms = Keyword.get(opts, :kms, Samen.Kms.adapter())
    subject = subject_id(app_id)

    case kms.unwrap(subject) do
      {:ok, dek} ->
        {:ok, dek}

      # :absent — no per-subject DEK yet (normal first use). :unavailable — the
      # FileBacked adapter also returns this when its OWN master key has never
      # been created yet (a brand-new, never-initialized key dir — the state a
      # fresh test/dev boot starts in). Both are worth ONE provision attempt: a
      # REAL outage fails provisioning too (generate_subject_key's own master()
      # call hits the same outage check), so the outage still correctly
      # propagates as :unavailable — this never masks a genuine outage.
      {:error, reason} when reason in [:absent, :unavailable] ->
        provision(kms, subject)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provision(kms, subject) do
    case kms.generate_subject_key(subject) do
      {:ok, _wrapped} -> kms.unwrap(subject)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compute `HMAC-SHA256(fleet_subject_key(app_id), org_id)`, truncated to the first 32
  hex chars (16 bytes) — the `fleet_handle` construction (§5.3). Returns
  `{:ok, handle_hex}` or `{:error, reason}` (fail-honest: no key ⇒ no handle, never a
  fabricated one).
  """
  @spec hmac(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def hmac(app_id, org_id, opts \\ []) when is_binary(app_id) and is_binary(org_id) do
    with {:ok, dek} <- fetch(app_id, opts) do
      digest =
        :crypto.mac(:hmac, :sha256, dek, org_id)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 32)

      {:ok, digest}
    end
  end
end
