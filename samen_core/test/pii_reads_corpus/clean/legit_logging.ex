# CORPUS FILE — legitimate NON-PII sink call sites. NOT compiled.
#
# These hit the same sinks (Logger, IO, span, aliased Logger) but carry NO
# vault-declared pii value. The walker must NOT flag any of them. They form the
# bulk of the false-positive denominator (plan S0.7: "< ~1 FP per 50 legit call
# sites"). Labeled N1..N13.

defmodule Corpus.LegitLogging do
  require Logger
  alias Logger, as: L

  # N1 — a bounded ID (org_id token).
  def log_request(scope), do: Logger.info("request org=#{scope.pat_org_id}")

  # N2 — a trace_id token.
  def log_trace(ctx), do: Logger.debug("trace=#{ctx.trace_id}")

  # N3 — an enum result.
  def log_result(res), do: Logger.info("result=#{res.status}")

  # N4 — a numeric row count.
  def log_count(n), do: Logger.info("rows=#{n}")

  # N5 — a span with a bounded ID attribute (the allow-listed reveal attrs).
  def span_reveal(_span, g), do: Tracer.set_attribute("grant_id", g.grant_id)

  # N6 — span subject_id (a token, not the name).
  def span_subject(_span, s), do: Tracer.set_attribute("subject_id", s.subject_id)

  # N7 — IO.puts of a static string.
  def banner, do: IO.puts("=== worker started ===")

  # N8 — IO.inspect of an enum/atom.
  def dbg_state(s), do: IO.inspect(s.state, label: "state")

  # N9 — a wide event of bounded fields (emit_event with only tokens/enums).
  def emit_wide(ctx) do
    emit_event(%{
      request_id: ctx.request_id,
      tenant_id: ctx.tenant_id,
      action: ctx.action,
      duration_ms: ctx.duration_ms
    })
  end

  # N10 — a field whose name merely CONTAINS a substring of a pii name but is
  #        NOT a declared pii attribute (pat_emails_verified? is not :emails).
  #        Proves the walker keys on the EXACT declared name, not a substring.
  def log_verified(u), do: Logger.info("verified=#{u.pat_emails_verified?}")

  # N11 — Map.get of a NON-pii key.
  def log_plan(row), do: Logger.info("plan=#{Map.get(row, :pat_plan)}")

  # N12 — Logger.metadata with bounded IDs.
  def set_meta(ctx), do: Logger.metadata(trace_id: ctx.trace_id, org: ctx.org_id)

  # N13 — the ALIASED Logger carrying a NON-pii token. Proves alias resolution
  #        does not itself create false positives — only pii payloads leak.
  def log_via_alias(ctx), do: L.info("id=#{ctx.request_id}")
end
