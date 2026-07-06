defmodule Mix.Tasks.Samen.Verify.SinkSchema do
  @shortdoc "J2 build-time check: every wide-event/span sink field must be a bounded ID/token/enum/number."

  @moduledoc """
  `mix samen.verify.sink_schema` — **the J2 build-time schema allow-list check**
  (plan J2 / T2.7; doc §runs 4b).

  This is the **laundered-leak backstop** the plan's layered privacy design
  promises. The C3 `pii_reads` AST verifier catches a *direct* flow of a PII value
  into a sink; a value *laundered* through a helper first is an expected miss at
  the AST layer (`Corpus.Laundered` LA1–LA3). J2 closes that path at the SINK: the
  wide-event / span field schema (`Samen.WideEvent.Schema`) declares every field
  with a **bounded type**, and this check **fails the build** on any field typed as
  a free-form string / binary / map / untyped value — the surfaces a laundered
  name could occupy. If no string field exists, a laundered name has nowhere to
  land.

  > "a build-time check fails on any span/wide-event field not typed as a bounded
  > ID / token / enum / number, so a future debug field can't smuggle a name into
  > Honeycomb." (doc §runs 4b)

  ## What it checks

  `Samen.WideEvent.Schema.violations/0` over the declared canonical field set:

    * a field whose declared type is NOT one of `:opaque_id | :token | :enum |
      :number` (a `:string`/`:binary`/`:map`/… name-carrier) → FAIL;
    * an `:enum` field with no closed `allowed:` set → FAIL.

  ## Exit code (fail-closed)

  Exits 0 when the schema is clean, 1 otherwise (via `Samen.Verifier`). A seeded
  string-typed field in the schema fails the build.

  ## Relationship to no_plaintext_pii

  The doc's `no_plaintext_pii` CI-mode invariant already asserts "the trace/event
  sink schema (span attrs + wide-event fields) exposes ONLY bounded columns". This
  task is the **dedicated** J2 check for the wide-event field schema, and the
  `Samen.NoPlaintextPii.Tiers.TraceSink` tier folds the SAME schema assertion into
  the oracle roster so `no_plaintext_pii` (CI + the T2.9 post-shred oracle) also
  fails on a broken sink schema. Two entry points, one schema (report: this task
  is the build check; the tier is the oracle fold — both call
  `Samen.WideEvent.Schema.violations/0`).
  """

  use Mix.Task

  @task_name "samen.verify.sink_schema"

  # Test seam (red-path exit-code proof): when this env var is set, a seeded
  # string field is appended to the schema field list so the subprocess red-path
  # test can prove the task exits 1 on a name-carrier field WITHOUT mutating the
  # real schema source. Absent in every non-test invocation.
  @inject_env "SAMEN_SINK_SCHEMA_INJECT_STRING_FIELD"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    violations = Samen.WideEvent.Schema.violations(fields())
    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  defp fields do
    base = Samen.WideEvent.Schema.canonical_fields()

    case System.get_env(@inject_env) do
      nil -> base
      name -> base ++ [{String.to_atom(name), :string, []}]
    end
  end
end
