# CORPUS FILE — legitimate declaration sites. NOT compiled.
#
# These NAME pii attributes but are DECLARATIONS, not flows. The walker must NOT
# flag any of them (zero false positives here is an acceptance criterion). A grep
# for `pii_` flags these; the AST walker structurally skips `pii do` blocks.

defmodule Corpus.Person do
  use Samen.Resource

  # A `pii do` block declaring vault-routed attributes. The attribute names
  # (full_name, emails, dob) appear literally, but inside a declaration block the
  # walker skips entirely.
  pii do
    vault(:pii_name)
    vault(:pii_email)
    vault(:pii_dob)

    pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
    pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)
    pii_attribute(:dob, :date, vault: :pii_dob)
  end

  # A plain (non-pii) attribute declaration next to the pii block. Must not be
  # flagged; proves the walker doesn't over-match declaration DSL.
  attributes do
    attribute(:pat_status, :atom)
    attribute(:pat_created_at, :utc_datetime)
  end
end
