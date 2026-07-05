# CORPUS FILE — more intentional direct PII leaks (L7..L9). NOT compiled.

defmodule Corpus.MoreDirectLeaks do
  require Logger

  # L7 — IO.inspect of a pii field (a common debugging leak).
  def debug_row(person) do
    IO.inspect(person.per_emails, label: "emails")
  end

  # L8 — a *_sink bare function carrying a pii field.
  def ship(row) do
    analytics_sink(%{tax: row.pii_tax_id})
  end

  # L9 — a bare variable whose NAME is a vault-declared pii attribute flows
  #      into Logger (models a value bound directly from a pii read upstream,
  #      e.g. `per_full_name = contact.per_full_name`).
  def log_named(per_full_name) do
    Logger.warning("name=#{per_full_name}")
  end
end
