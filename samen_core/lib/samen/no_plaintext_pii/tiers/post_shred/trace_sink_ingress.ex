defmodule Samen.NoPlaintextPii.Tiers.PostShred.TraceSinkIngress do
  @moduledoc """
  **Post-shred INGRESS-CLASS assertion for the trace/event sink** (doc §runs oracle
  block "INGRESS-CLASS tier (not destruction-class)"; plan T2.9).

  > The third-party trace_sink is append-only + NOT key-reachable, so it is held to
  > a schema-asserted INGRESS rule — the oracle asserts it only ever RECEIVED
  > tokens / bounded IDs / per-subject-KEYED pseudonyms (token-only by construction
  > at write), so there is no plaintext to shred and the pseudonym
  > HMAC(subject_key, subject_id) goes unlinkable the moment that subject's KMS key
  > is destroyed (rides check 3, not an epoch). It is NOT a post-shred content scan.

  This tier is the destruction-oracle counterpart to the CI-mode `TraceSink` tier.
  It is deliberately a **SCHEMA assertion, not a content scan** — the sink is
  third-party (Honeycomb/Tempo/Loki) and append-only, so key-shred cannot reach it.
  The oracle instead proves that only tokens / bounded IDs / per-subject-keyed
  pseudonyms could EVER have entered it (`Samen.WideEvent.Schema.violations/0` —
  the same J2 build-time allow-list), and that the subject's `actor_id` pseudonym
  goes unlinkable on key destruction (RQ5): `Samen.Vault.pseudonym/1` must FAIL
  (`:shredded`) post-shred, riding oracle check 3's KMS destruction.

  A string field smuggled into the wide-event/span schema is a violation here (the
  laundered-name-carrier surface), exactly as in CI mode — the schema is the
  invariant, valid in every run.

  ## Positive attestation

  `:post_shred` tier: emits `:pass` for the two ingress guarantees it clears (schema
  bounded, pseudonym unlinked), `:violation` on a schema hole or a still-computable
  pseudonym. Never empty.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.WideEvent.Schema
  alias Samen.Vault

  @tier :trace_sink

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do:
      "post-shred trace-sink INGRESS assertion (schema bounded token/ID/pseudonym-only; " <>
        "pseudonym unlinks on key-shred) — NOT a content scan"

  @impl true
  def check(%Context{subject_id: nil}) do
    [
      Finding.violation(
        @tier,
        "<subject>",
        "post-shred trace-sink assertion requires --subject <uuid> — fail closed."
      )
    ]
  end

  def check(%Context{subject_id: sid}) do
    schema_findings() ++ pseudonym_findings(sid)
  end

  # ---------------------------------------------------------------------------

  defp schema_findings do
    case schema_violations() do
      [] ->
        [
          Finding.pass(
            @tier,
            "schema",
            "every wide-event/span field is a bounded ID / token / enum / number (J2 " <>
              "allow-list) — the sink only ever RECEIVED token-only data; no plaintext to shred"
          )
        ]

      violations ->
        Enum.map(violations, fn detail ->
          Finding.violation(
            @tier,
            "schema",
            "trace-sink ingress schema admits a non-bounded field (name-carrier surface): " <>
              detail
          )
        end)
    end
  end

  # The wide-event/span schema the ingress rule asserts over. Defaults to the
  # canonical J2 schema; a red-path test may inject a deliberately-broken field
  # set via `:samen_core, :wide_event_schema_override` (the same seam LogTelemetry
  # uses for its config-driven red path) — proving the tier maps a smuggled string
  # field to a `:violation` WITHOUT mutating the real schema module.
  defp schema_violations do
    case Application.get_env(:samen_core, :wide_event_schema_override) do
      nil -> Schema.violations()
      fields when is_list(fields) -> Schema.violations(fields)
    end
  end

  defp pseudonym_findings(sid) do
    case Vault.pseudonym(sid) do
      {:error, reason} when reason in [:shredded, :absent, :unavailable] ->
        [
          Finding.pass(
            @tier,
            "pseudonym",
            "the subject's actor_id pseudonym HMAC(subject_key, #{sid}) is no longer " <>
              "computable (#{inspect(reason)}) — the trace-sink handle went unlinkable the " <>
              "moment the KMS key was destroyed (RQ5; rides oracle check 3)"
          )
        ]

      {:ok, _pseudonym} ->
        [
          Finding.violation(
            @tier,
            "pseudonym",
            "the subject's actor_id pseudonym is STILL COMPUTABLE after shred — the " <>
              "trace-sink handle is still linkable to the subject. The pseudonym key must " <>
              "ride the destroyed DEK. Fail closed."
          )
        ]

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            "pseudonym",
            "pseudonym probe returned an unexpected error #{inspect(reason)} — fail closed."
          )
        ]
    end
  end
end
