defmodule PiiReads.PiiRegistry do
  @moduledoc """
  Stub for the vault PII-declaration registry.

  In the real Samen substrate this information comes from Spark DSL
  introspection (`Ash.Resource.Info` over the `pii do ... pii_attribute ... end`
  section — see plan D2). The verifier "keys on the `pii do` / vault
  declaration, not the column name alone" (plan C3, doc §runs 3).

  For this AST-feasibility spike we approximate that registry two ways:

    1. A *static* seed set of attribute names known to be vault-routed
       (the names a real registry would have produced). This is what the
       walker consults when deciding whether a field read is "tainted".

    2. A *discovered* set: the walker itself scans each source for
       `pii_attribute :name, ...` calls inside a `pii do` block and reports
       those spans as DECLARATION SITES — which must never be flagged as
       leaks even though the pii name literally appears there.

  The two together let us prove the scope-awareness the plan demands:
  "knows a declaration site from a sink, which a grep cannot."
  """

  # The vault-declared attribute names for the corpus. In production these are
  # discovered from every resource's `pii do` block; here they are the union of
  # what the corpus resources declare. Includes both the composite-routed names
  # (per_full_name, per_emails — carry the resource abbrev, no pii_ prefix) and
  # the scalar pii_-prefixed names (pii_ssn, pii_dob, drv_cdl_number-style).
  @seed_pii_attributes MapSet.new([
                         # composite-type fields routed by vault name (doc §396):
                         :per_full_name,
                         :per_emails,
                         :per_phones,
                         # scalar pii_attribute fields carrying the pii_ prefix:
                         :pii_ssn,
                         :pii_dob,
                         :pii_mrn,
                         :pii_email,
                         :pii_tax_id,
                         # Driftwood freight vertical scalar (plan §M):
                         :drv_cdl_number
                       ])

  @doc "The seed set of vault-declared attribute names (as atoms)."
  @spec pii_attributes() :: MapSet.t()
  def pii_attributes, do: @seed_pii_attributes

  @doc "True if `name` (atom) is a vault-declared PII attribute."
  @spec pii_attribute?(atom()) :: boolean()
  def pii_attribute?(name) when is_atom(name),
    do: MapSet.member?(@seed_pii_attributes, name)

  def pii_attribute?(_), do: false
end
