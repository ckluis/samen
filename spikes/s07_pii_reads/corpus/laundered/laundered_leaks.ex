# CORPUS FILE — LAUNDERED leaks (LA1..LA3). NOT compiled.
#
# In each, a vault-declared pii value is passed THROUGH a helper function
# first; at the sink call site the AST no longer sees a pii field — it sees an
# opaque local parameter. A pure AST *match* (this spike) therefore MISSES
# these BY DESIGN. This is the documented expected-miss set.
#
# The doc's layered backstop (plan C3 + J2, doc §4b, §779): the build-time
# SINK SCHEMA ALLOW-LIST catches laundering — every span/wide-event field must
# be typed as a bounded ID / token / enum / number, so a laundered name cannot
# occupy a typed sink field. "Direct leak: AST. Laundered leak: the sink
# schema. Together they close the path without claiming full taint analysis."
# This spike does NOT implement J2; it proves the AST layer and documents the
# boundary honestly.

defmodule Corpus.Laundered do
  require Logger

  # LA1 — pii read passed to a local helper that logs it. At `log_it/1` the
  #       argument `val` is an opaque local; the pii field read happened at the
  #       call site but flows into `log_it`, not into a sink. Expected MISS.
  def leak_via_helper(contact) do
    log_it(contact.per_full_name)
  end

  defp log_it(val) do
    Logger.info("value=#{val}")
  end

  # LA2 — pii read stashed in a map, passed to a helper, then interpolated.
  #       The sink sees `payload.value`, not a declared pii attribute. MISS.
  def leak_via_map(subject) do
    ship_payload(%{value: subject.pii_ssn})
  end

  defp ship_payload(payload) do
    IO.puts("payload: #{payload.value}")
  end

  # LA3 — pii read bound to a non-pii-named var, passed to a helper 2 hops
  #       deep, then to a span. Two levels of indirection. MISS.
  def leak_two_hops(driver) do
    forward(driver.drv_cdl_number)
  end

  defp forward(x), do: sink_it(x)
  defp sink_it(x), do: Tracer.set_attribute("cdl", x)
end
