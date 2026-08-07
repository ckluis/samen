defmodule Samen.WebTest.OperatorScope do
  @moduledoc """
  T84 — the samen_web test-support mount of the operator-account ASSIGNMENT blueprint
  (`Samen.Fleet.Assignment`, ADR-044 §16.5 #1 / ruling R-A), the `Samen.WebTest.Fleet`
  precedent: mounts the samen_core-authored blueprint into samen_web's OWN test repo so
  the R-B drill-in scope gate + the real `scope_of/2` reader are exercised against a
  REAL `woa_assignment` table through the full mount/gate path, not a mock.

  Fresh `woa` abbrev reserved through the sanctioned allocator
  (`mix samen.abbrev.reserve --host samen_web`, ADR-023).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Fleet.Assignment,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.OperatorScope,
    abbrev: "woa"
end
