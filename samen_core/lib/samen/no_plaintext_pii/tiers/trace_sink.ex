defmodule Samen.NoPlaintextPii.Tiers.TraceSink do
  @moduledoc """
  CI-mode + ingress-class tier: **the trace/event sink schema (span attrs +
  wide-event fields) exposes ONLY bounded ID / token / enum / number fields**
  (doc §runs oracle block "the trace/event sink schema … exposes ONLY … columns";
  doc §runs 4b; plan J2 / T2.7).

  This tier folds the SAME `Samen.WideEvent.Schema` J2 check the dedicated
  `mix samen.verify.sink_schema` task runs into the `no_plaintext_pii` oracle
  roster, so the destruction oracle (CI mode AND the T2.9 post-shred `--tiers all`
  run) also fails on a broken sink schema. One schema, two entry points.

  ## Ingress-class, not destruction-class

  The trace sink is third-party (Honeycomb/Tempo/Loki) and append-only — key-shred
  cannot reach it, so it is held to an **ingress rule**: the oracle asserts it only
  ever RECEIVED tokens / bounded IDs / per-subject-keyed pseudonyms (token-only by
  construction at write). There is no post-shred content scan of the sink; the
  `actor_id` pseudonym (`HMAC(psk_S, subject_id)`) goes unlinkable the moment the
  subject's KMS key is destroyed (rides oracle check 3, not an epoch). This tier's
  `mode/0` is `:ci` — it is a SCHEMA assertion (static), valid in every run,
  including post-shred, because the schema is the invariant, not the data.

  ## What it asserts

  `Samen.WideEvent.Schema.violations/0` — every declared wide-event/span field is a
  bounded type; no `:string`/`:binary`/`:map`/untyped field exists (the
  laundered-name-carrier surface). A violation here is a `:violation` finding that
  fails the oracle.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.WideEvent.Schema

  @tier :trace_sink

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do:
      "trace/event sink schema (wide-event + span fields) is bounded ID/token/enum/number only " <>
        "— ingress-class (J2 allow-list); pseudonym unlinks on key-shred"

  @impl true
  def check(%Context{} = _context) do
    Schema.violations()
    |> Enum.map(fn detail ->
      Finding.violation(@tier, "wide_event/span schema", detail)
    end)
  end
end
