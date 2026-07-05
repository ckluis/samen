# CORPUS FILE — legitimate declaration sites. NOT compiled.
#
# These NAME pii attributes but are DECLARATIONS, not flows. The walker must
# NOT flag any of them (zero false positives here is an acceptance criterion).
# Labeled C1..C4 (declaration class).

defmodule Corpus.Person do
  use Samen.Resource

  # C1..C3 — a `pii do` block declaring three vault-routed attributes. The
  # attribute names (per_full_name, per_emails, pii_ssn) appear literally, but
  # inside a declaration block the walker skips entirely. A grep for `pii_`
  # would flag these; the AST walker must not.
  pii do
    pii_attribute(:per_full_name, Samen.Type.FullName, vault: :pii_name)
    pii_attribute(:per_emails, Samen.Type.Emails, vault: :pii_email)
    pii_attribute(:pii_ssn, :string, vault: :pii_ssn)
  end

  # C4 — a plain (non-pii) attribute declaration next to the pii block. Must
  # not be flagged; also proves the walker doesn't over-match declaration DSL.
  attributes do
    attribute(:com_status, :atom)
    attribute(:com_created_at, :utc_datetime)
  end
end

defmodule Corpus.Driver do
  use Samen.Resource

  # C5 — a second declaration site: the Driftwood freight driver's CDL number
  #      declared as a scalar pii_attribute. Named, but a declaration.
  pii do
    pii_attribute(:drv_cdl_number, :string, vault: :pii_cdl)
  end
end
