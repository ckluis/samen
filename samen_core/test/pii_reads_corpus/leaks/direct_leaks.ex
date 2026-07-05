# CORPUS FILE — intentional PII leaks. NOT compiled (this dir is not in
# elixirc_paths); read as text by the Samen.PiiReads AST walker only.
#
# Every function below is a SEEDED DIRECT LEAK: a vault-declared PII value
# (a name the REAL registry knows via Samen.Pii.Info introspection over the
# fixture resources' `pii do` blocks) flows into a Logger / span / event sink
# OUTSIDE a declared :reveal action. The walker MUST flag all of these.
#
# PII names used here are drawn from the real fixtures:
#   * logical:  :full_name :emails :dob :mrn         (Patient / RevealPerson)
#   * storage:  :pat_full_name :pii_pat_dob :pii_pat_mrn :rvp_emails

defmodule Corpus.DirectLeaks do
  require Logger

  # L1 — Logger.info with a pii composite field (logical name full_name).
  def audit_login(patient) do
    Logger.info("user logged in: #{patient.full_name}")
  end

  # L2 — Logger.error with a scalar pii field by its STORAGE name (pii_pat_dob).
  #      Keys on the declaration, not on any prefix convention.
  def report_dob(record) do
    Logger.error("dob mismatch for #{record.pii_pat_dob}")
  end

  # L3 — span attribute set to a pii field (Tracer.set_attribute).
  def trace_subject(subject) do
    Tracer.set_attribute("subject.mrn", subject.mrn)
  end

  # L4 — span attributes map carrying a pii storage field (OpenTelemetry.Span).
  def annotate_span(span, patient) do
    OpenTelemetry.Span.set_attributes(span, %{dob: patient.pii_pat_dob})
  end

  # L5 — string interpolation into IO.puts (a raw stdout sink).
  def dump_emails(person) do
    IO.puts("emails: #{person.emails}")
  end

  # L6 — a pii value fetched via Map.get flows into a bare event sink.
  def emit_profile(row) do
    emit_event(%{name: Map.get(row, :full_name), kind: :profile})
  end

  # L7 — IO.inspect of a pii storage field (a common debugging leak).
  def debug_row(patient) do
    IO.inspect(patient.pat_full_name, label: "name")
  end

  # L8 — a *_sink bare function carrying a pii field.
  def ship(row) do
    analytics_sink(%{mrn: row.pii_pat_mrn})
  end
end
