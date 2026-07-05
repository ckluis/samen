# CORPUS FILE — the CLOSED EVASIONS (Gate-0 fix task #6). NOT compiled.
#
# These are the exact evasions the S0.7 spike could NOT catch. Production C3
# MUST flag every one of them.

defmodule Corpus.RevealPrefixEvasion do
  require Logger

  # E1 — THE reveal_* lexical-prefix evasion (spike caveat #1). A function whose
  #      NAME starts with `reveal` but is NOT a declared Ash reveal action. The
  #      spike suppressed ALL sinks in any `reveal*`-named function; production C3
  #      keys on the real `reveal :action` marker, so a bare `def reveal_report`
  #      is NOT a reveal boundary and this leak is CAUGHT.
  def reveal_report(patient) do
    Logger.info("ssn=#{patient.pii_pat_dob}")
  end

  # E2 — a `def reveal/1` (exact name `reveal`) that is NOT a declared reveal
  #      action on any resource. The spike suppressed `def reveal`; production C3
  #      does not — a plain function named `reveal` is not an Ash reveal action.
  def reveal(subject) do
    IO.puts("emails: #{subject.emails}")
  end
end

defmodule Corpus.UndeclaredActionEvasion do
  require Logger

  # E3 — an `action :reveal_report do … end` that was NEVER declared
  #      `reveal :reveal_report` in a `pii do` block. Because this file's module
  #      is not a Samen resource with `:reveal_report` as a declared reveal
  #      action, the registry returns false and the sink is FLAGGED. (Only a
  #      genuinely-declared reveal action suppresses — see clean/reveal_sites.ex,
  #      which uses the real RevealPerson resource + its declared :reveal_email.)
  action :reveal_report do
    Logger.error("leaked dob=#{subject.pii_pat_dob}")
  end
end

defmodule Corpus.AliasedLoggerEvasion do
  # E4 — aliased sink module (spike caveat #3). `alias Logger, as: L` then
  #      `L.info(...)` — the spike resolved only the literal `Logger` module;
  #      production C3 resolves the alias from module context and flags the leak.
  alias Logger, as: L

  def go(patient) do
    L.info("aliased leak: #{patient.full_name}")
  end
end

defmodule Corpus.AliasedSpanEvasion do
  # E5 — aliased OTel span module. `alias OpenTelemetry.Span, as: S` then
  #      `S.set_attribute(...)`.
  alias OpenTelemetry.Span, as: S

  def trace(span, patient) do
    S.set_attribute(span, "mrn", patient.mrn)
  end
end
