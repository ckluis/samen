defmodule PiiReads.CorpusLabels do
  @moduledoc """
  Ground-truth labels for the seeded corpus, used to compute catch rate and
  false-positive rate numerically (plan S0.7 acceptance).

  The corpus is deliberately labeled so the test suite can assert exact
  counts, not just "some findings appeared".
  """

  @corpus_root Path.expand("../corpus", __DIR__)

  def corpus_root, do: @corpus_root

  # Seeded DIRECT leaks: {file, line, expected_pii_atoms}. The walker must
  # produce exactly one :direct_leak finding per entry.
  @direct_leaks [
    {"leaks/direct_leaks.ex", 13, [:per_full_name]},
    {"leaks/direct_leaks.ex", 19, [:pii_ssn]},
    {"leaks/direct_leaks.ex", 24, [:pii_email]},
    {"leaks/direct_leaks.ex", 29, [:drv_cdl_number]},
    {"leaks/direct_leaks.ex", 34, [:pii_dob]},
    {"leaks/direct_leaks.ex", 39, [:per_full_name]},
    {"leaks/more_direct_leaks.ex", 8, [:per_emails]},
    {"leaks/more_direct_leaks.ex", 13, [:pii_tax_id]},
    {"leaks/more_direct_leaks.ex", 20, [:per_full_name]}
  ]

  # LAUNDERED leaks: real leaks that a pure AST match is EXPECTED to miss
  # (caught downstream by the sink schema allow-list, plan J2). The walker must
  # produce ZERO findings for these files — that is the honest documented miss.
  @laundered_files [
    "laundered/laundered_leaks.ex"
  ]
  @laundered_count 3

  # LEGIT call sites the FP-rate is measured against: every sink call in the
  # clean corpus that must NOT be flagged (declarations + reveal sites + the
  # non-pii logging). Counted from the corpus below.
  @legit_sink_sites 4 + 12

  def direct_leaks, do: @direct_leaks
  def direct_leak_count, do: length(@direct_leaks)
  def laundered_files, do: @laundered_files
  def laundered_count, do: @laundered_count
  def legit_sink_sites, do: @legit_sink_sites

  def path(rel), do: Path.join(@corpus_root, rel)
end
