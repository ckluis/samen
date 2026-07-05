# TASK CORPUS — a single direct leak using a PII name the DEFAULT registry (the
# configured :ash_domains) knows (Clinical.Patient's :full_name). NOT compiled.
# Used by the mix-task subprocess exit-code test: `mix samen.verify.pii_reads
# --source-dirs test/pii_reads_corpus/task_leak` must exit 1.

defmodule Corpus.TaskLeak do
  require Logger

  def go(patient) do
    Logger.info("leaked name: #{patient.full_name}")
  end
end
