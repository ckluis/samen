# CORPUS FILE — intentional PII leaks. NOT compiled by the build
# (elixirc_paths is ["lib"]); read as text by the AST walker only.
#
# Every function below is a SEEDED DIRECT LEAK: a vault-declared PII value
# flows into a Logger / span / sink call OUTSIDE a :reveal-scoped action.
# The walker MUST flag all of these. Each is labeled L1..L6.

defmodule Corpus.DirectLeaks do
  require Logger

  # L1 — Logger.info with a pii composite field (per_full_name), interpolated.
  def audit_login(contact) do
    Logger.info("user logged in: #{contact.per_full_name}")
  end

  # L2 — Logger.error with a scalar pii_ field (pii_ssn), plain concatenation
  #      via interpolation.
  def report_mismatch(record) do
    Logger.error("ssn mismatch for #{record.pii_ssn}")
  end

  # L3 — span attribute set to a pii field (Tracer.set_attribute).
  def trace_subject(subject) do
    Tracer.set_attribute("subject.email", subject.pii_email)
  end

  # L4 — span attributes map carrying a pii field (OpenTelemetry.Span).
  def annotate_span(span, driver) do
    OpenTelemetry.Span.set_attributes(span, %{cdl: driver.drv_cdl_number})
  end

  # L5 — string interpolation into IO.puts (a raw stdout sink).
  def dump_dob(patient) do
    IO.puts("DOB: #{patient.pii_dob}")
  end

  # L6 — a pii value fetched via Map.get flows into a bare event sink.
  def emit_profile(row) do
    emit_event(%{name: Map.get(row, :per_full_name), kind: :profile})
  end
end
