defmodule SamenCore.Support.PiiReadsCorpusLabels do
  @moduledoc """
  Labels + registry for the `pii_reads` production verifier corpus (T1.8b).

  The corpus lives under `test/pii_reads_corpus/` — a directory NOT in
  `elixirc_paths`, so its `.ex` files are read as text by the AST walker only and
  are never compiled. The registry is built from the REAL fixture resources'
  `pii do` blocks (`Samen.Pii.Info` introspection), never a hand seed set — that
  is Gate-0 fix task #6 (c): "the PII registry comes from Samen.Pii.Info".
  """

  alias Samen.PiiReads.Registry

  @corpus_root Path.expand("../pii_reads_corpus", __DIR__)

  # The two fixture resources whose `pii do` blocks drive the corpus taint set
  # and reveal boundaries:
  #   * Patient      — full_name/emails/phones (composite) + dob/mrn (scalar),
  #                    storage pat_full_name/pat_emails/pat_phones/pii_pat_dob/
  #                    pii_pat_mrn. No reveal action declared.
  #   * RevealPerson — emails (composite, storage rvp_emails); declares
  #                    `reveal :reveal_email` (the real reveal boundary).
  @resources [
    SamenCore.Support.Clinical.Patient,
    SamenCore.Support.RevealDomain.RevealPerson
  ]

  @doc "The registry built from the real fixture resources (Samen.Pii.Info)."
  @spec registry() :: Registry.t()
  def registry, do: Registry.build(resources: @resources)

  @doc "Absolute path to a corpus subdir (leaks|clean|laundered)."
  @spec path(String.t()) :: String.t()
  def path(sub), do: Path.join(@corpus_root, sub)

  # ---- expected labels (kept in lock-step with the corpus files) ----------

  @doc """
  Seeded DIRECT leaks (must be caught): {relative_path, line, pii_atoms}. These
  are the direct_leaks.ex L1..L8 PLUS the closed_evasions.ex E1..E5 — every
  Gate-0 evasion that MUST now fail.
  """
  @spec direct_leaks() :: [{String.t(), non_neg_integer(), [atom()]}]
  def direct_leaks do
    [
      # closed_evasions.ex — the Gate-0 fix #6 evasions
      {"closed_evasions.ex", 15, [:pii_pat_dob]},
      {"closed_evasions.ex", 22, [:emails]},
      {"closed_evasions.ex", 36, [:pii_pat_dob]},
      {"closed_evasions.ex", 47, [:full_name]},
      {"closed_evasions.ex", 57, [:mrn]},
      # direct_leaks.ex — the classic direct-flow set
      {"direct_leaks.ex", 18, [:full_name]},
      {"direct_leaks.ex", 24, [:pii_pat_dob]},
      {"direct_leaks.ex", 29, [:mrn]},
      {"direct_leaks.ex", 34, [:pii_pat_dob]},
      {"direct_leaks.ex", 39, [:emails]},
      {"direct_leaks.ex", 44, [:full_name]},
      {"direct_leaks.ex", 49, [:pat_full_name]},
      {"direct_leaks.ex", 54, [:pii_pat_mrn]}
    ]
  end

  @spec direct_leak_count() :: non_neg_integer()
  def direct_leak_count, do: length(direct_leaks())

  @doc "Count of laundered (expected-miss) leaks in the laundered corpus."
  @spec laundered_count() :: non_neg_integer()
  def laundered_count, do: 3

  @doc """
  Number of legitimate sink call sites in the clean corpus — the false-positive
  denominator (declarations + reveal + non-pii logging).
  """
  @spec legit_sink_sites() :: non_neg_integer()
  def legit_sink_sites, do: 14
end
