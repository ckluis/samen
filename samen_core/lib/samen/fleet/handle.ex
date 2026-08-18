defmodule Samen.Fleet.Handle do
  @moduledoc """
  `fleet_handle` — the per-product HMAC pseudonym for a tenant org (ADR-044 §5.3):

      fleet_handle = first 32 hex chars (16 bytes) of
                     HMAC-SHA256(fleet_subject_key(app_id), org_id)

  Class `:token {:hex, 32}` on the wire — no `h_` prefix, the class is declared, not
  encoded (T81 fix-round LOW). Stable within one product, non-reversible, unlinkable
  across products, and unlinkable at all once the key is destroyed. It is **not** an
  `org_id` and this module never exposes a reverse mapping — only the owning product,
  holding its own `fleet_subject_key(app_id)`, can relate a handle back to an org
  (and only by recomputing the SAME HMAC over a candidate `org_id` — there is no
  stored reverse index).
  """

  alias Samen.Fleet.SubjectKey

  @doc """
  Compute the `fleet_handle` for `{app_id, org_id}`. Delegates to
  `Samen.Fleet.SubjectKey.hmac/3` — fail-honest: `{:error, reason}` when the KMS seam
  cannot produce this product's fleet subject key, never a fabricated handle.
  """
  @spec compute(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def compute(app_id, org_id, opts \\ []), do: SubjectKey.hmac(app_id, org_id, opts)

  @doc """
  Product-local membership test: does `org_id` hash to `handle` under this product's
  CURRENT fleet subject key? Used by the owning product to relate a wire handle back
  to a real org — never by the cockpit (§16.2: the cockpit is structurally unable to
  perform this test, since it never holds `fleet_subject_key(app_id)`).
  """
  @spec matches?(String.t(), String.t(), String.t(), keyword()) :: boolean()
  def matches?(app_id, org_id, handle, opts \\ []) do
    case compute(app_id, org_id, opts) do
      {:ok, ^handle} -> true
      _ -> false
    end
  end

  @doc "Structural shape check only — `:token {:hex, 32}` (32 lowercase hex chars)."
  @spec well_formed?(term()) :: boolean()
  def well_formed?(value) when is_binary(value) do
    byte_size(value) == 32 and Regex.match?(~r/\A[0-9a-f]{32}\z/, value)
  end

  def well_formed?(_), do: false
end
