# TASK CORPUS — clean content that does NOT depend on RevealDomain (which is not
# in the configured :ash_domains). Declarations + non-pii logging only. NOT
# compiled. Used by the mix-task subprocess exit-code test: `mix
# samen.verify.pii_reads --source-dirs test/pii_reads_corpus/task_clean` exits 0.

defmodule Corpus.TaskClean do
  use Samen.Resource
  require Logger

  # Declaration site — names pii fields but is a declaration, not a flow.
  pii do
    pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
    pii_attribute(:dob, :date, vault: :pii_dob)
  end

  # Non-pii logging — bounded tokens only.
  def log_request(scope), do: Logger.info("org=#{scope.pat_org_id}")
  def log_count(n), do: Logger.info("rows=#{n}")
end
