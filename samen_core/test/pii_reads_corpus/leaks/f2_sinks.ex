# CORPUS FILE — Gate-1 F2 sink-inventory expansion. NOT compiled (this dir is
# not in elixirc_paths); read as text by the Samen.PiiReads AST walker only.
#
# The Gate-1 report (F2) named four real sinks C3 did NOT model, so a plaintext
# PII value passed to them sailed past the verifier: `:telemetry.execute/3`,
# `Sentry.*`, `File.write/2`, and `send/2`. T2.7 grows the sink inventory to
# catch DIRECT flows into each (the LAUNDERED variants remain J2's job). Each
# function below is a seeded DIRECT leak that MUST now be flagged.
#
# PII names drawn from the real fixtures: :full_name :emails :dob :mrn (logical)
# and :pat_full_name :pii_pat_dob :pii_pat_mrn (storage).

defmodule Corpus.F2Sinks do
  # F2-1 — :telemetry.execute/3 with a pii value in the metadata map. This is the
  #        wide-event / metric emit path — the exact surface J2 governs, but a
  #        DIRECT flow of a name into it is a syntactic leak C3 now catches.
  def emit_wide(patient) do
    :telemetry.execute([:app, :request], %{count: 1}, %{actor_name: patient.full_name})
  end

  # F2-2 — Sentry.capture_message with an interpolated pii storage field. An
  #        error report is a third-party sink; a revealed name must not ride it.
  def report_error(record) do
    Sentry.capture_message("bad dob: #{record.pii_pat_dob}")
  end

  # F2-3 — File.write/2 of a pii value to disk (a plaintext-at-rest leak).
  def dump_to_disk(subject) do
    File.write("/tmp/leak.txt", subject.mrn)
  end

  # F2-4 — send/2 handing a pii value to another process (off to wherever that
  #        process ships it). `send` is a Kernel-imported bare call.
  def forward_to(pid, person) do
    send(pid, {:profile, person.emails})
  end
end
