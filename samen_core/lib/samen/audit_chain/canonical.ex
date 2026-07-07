defmodule Samen.AuditChain.Canonical do
  @moduledoc """
  Deterministic canonical serialization + hashing for the audit hash chain
  (T4.3; ADR-002 §2.3).

  The chain hash MUST be reproducible: `verify_chain/1` recomputes every entry's
  hash from its stored fields and compares against the stored hash. That is only
  possible if the payload serialization is byte-for-byte deterministic. So this
  module hand-rolls a canonical JSON encoder (sorted keys, no incidental
  whitespace, explicit null encoding) rather than depending on `Jason`'s key
  ordering, which is map-insertion-order-dependent and NOT a stable contract.

  ## What is hashed (token-only)

  Every field in the canonical payload is a token / bounded id / enum / timestamp
  / hex digest — NEVER plaintext PII (ADR-002 §2.3). The `subject_id` is the
  subject's opaque UUID (the same token `aud_event` carries), `detail` is
  operator-authored metadata (the T2.2 allow-listed field), and
  `ciphertext_sha256` is the hex SHA-256 of the entry's per-subject
  key-destroyable ciphertext (§2.4) — the chain commits to the *digest of the
  ciphertext*, so destroying the subject key leaves the hash unchanged and the
  chain still verifies post-shred.

  ## Hash

      hash_n = SHA256( prior_hash_n <> canonical_json(payload_n) )

  `prior_hash` and `hash` are lowercase-hex SHA-256 strings. `genesis/0` is the
  fixed `prior_hash` of the first entry (seq 0) in every org chain.
  """

  @genesis_preimage "samen/audit-chain/genesis/v1"

  # The empty-ciphertext digest — the ciphertext_sha256 for an entry with no
  # per-subject ciphertext. A fixed constant (SHA-256 of the empty binary).
  @empty_ciphertext_sha256 :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  @typedoc """
  The token-only fields the chain hashes. Every value is a token / id / enum /
  timestamp / hex — never plaintext PII.
  """
  @type payload :: %{
          org_id: String.t(),
          seq: non_neg_integer(),
          aud_id: String.t() | nil,
          event_type: String.t(),
          subject_id: String.t() | nil,
          actor_id: String.t() | nil,
          correlation_id: String.t() | nil,
          detail: String.t() | nil,
          occurred_at: String.t(),
          ciphertext_sha256: String.t()
        }

  @doc "The genesis prior_hash — the fixed prior_hash of seq 0 in every org chain."
  @spec genesis() :: String.t()
  def genesis, do: :crypto.hash(:sha256, @genesis_preimage) |> Base.encode16(case: :lower)

  @doc "The digest of the empty (absent) ciphertext."
  @spec empty_ciphertext_sha256() :: String.t()
  def empty_ciphertext_sha256, do: @empty_ciphertext_sha256

  @doc """
  SHA-256 (lowercase hex) of a ciphertext binary. `nil` → the empty-ciphertext
  digest (a fixed constant), so an entry with no subject ciphertext still commits
  to a well-defined value.
  """
  @spec ciphertext_sha256(binary() | nil) :: String.t()
  def ciphertext_sha256(nil), do: @empty_ciphertext_sha256
  def ciphertext_sha256(ct) when is_binary(ct), do: :crypto.hash(:sha256, ct) |> Base.encode16(case: :lower)

  @doc """
  Compute the chain hash for `payload` given `prior_hash`.

      hash = SHA256( prior_hash <> canonical_json(payload) )
  """
  @spec hash(String.t(), payload()) :: String.t()
  def hash(prior_hash, payload) when is_binary(prior_hash) and is_map(payload) do
    preimage = prior_hash <> encode(payload)
    :crypto.hash(:sha256, preimage) |> Base.encode16(case: :lower)
  end

  @doc """
  Canonical JSON encoding of a payload map: keys sorted, no incidental
  whitespace, explicit null encoding. Deterministic across runs and OTP versions.
  """
  @spec encode(map()) :: String.t()
  def encode(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",", fn {k, v} -> encode_string(k) <> ":" <> encode_value(v) end)

    "{" <> inner <> "}"
  end

  # --- value encoders (a bounded set — payloads carry only these shapes) ---

  defp encode_value(nil), do: "null"
  defp encode_value(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_value(v) when is_binary(v), do: encode_string(v)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(%DateTime{} = dt), do: encode_string(DateTime.to_iso8601(dt))

  defp encode_string(s) when is_binary(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end
end
