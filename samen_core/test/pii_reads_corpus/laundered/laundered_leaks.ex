# CORPUS FILE — LAUNDERED leaks (LA1..LA3). NOT compiled.
#
# In each, a vault-declared pii value is passed THROUGH a local helper first; at
# the sink call site the AST sees an opaque local, not a pii field. A pure AST
# *match* (this verifier) MISSES these BY DESIGN — the documented expected-miss
# set. The layered backstop (plan C3 + J2, doc §4b): the build-time SINK SCHEMA
# ALLOW-LIST (Phase 2, T2.7) catches laundering — every span/wide-event field
# must be a bounded ID/token/enum/number, so a laundered name cannot occupy a
# typed sink field.
#
# Production C3 emits a `:laundered_hint` (advisory, NEVER a failing finding)
# when a pii read is passed to a KNOWN local helper — so the honest boundary is
# visible in output and cites J2.

defmodule Corpus.Laundered do
  require Logger

  # LA1 — pii read passed to a local helper that logs it. Expected MISS at the
  #       sink; a :laundered_hint fires at the call to log_it/1.
  def leak_via_helper(patient) do
    log_it(patient.full_name)
  end

  defp log_it(val) do
    Logger.info("value=#{val}")
  end

  # LA2 — pii read stashed in a map, passed to a helper, then interpolated.
  def leak_via_map(subject) do
    ship_payload(%{value: subject.pii_pat_dob})
  end

  defp ship_payload(payload) do
    IO.puts("payload: #{payload.value}")
  end

  # LA3 — pii read forwarded two hops, then to a span. Two levels of indirection.
  def leak_two_hops(patient) do
    forward(patient.mrn)
  end

  defp forward(x), do: sink_it(x)
  defp sink_it(x), do: Tracer.set_attribute("mrn", x)
end
