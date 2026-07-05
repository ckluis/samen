# CORPUS FILE — legitimate DECLARED-:reveal-action sites. NOT compiled.
#
# These DO flow a pii value into a sink, but lexically inside an Ash action that
# is a DECLARED reveal action on a real Samen resource. By design (plan S0.7 /
# Gate-0 fix #6a) the walker allows these — flow into a sink is permitted only
# inside a declared :reveal action.
#
# The module name here is the REAL resource `SamenCore.Support.RevealDomain.
# RevealPerson`, which declares `reveal :reveal_email` in its `pii do` block.
# The walker resolves this defmodule to that module and asks the registry:
# reveal_action?(RevealPerson, :reveal_email) == true  → suppress.
# reveal_action?(RevealPerson, :read_email_looks_like_reveal) == false → flag.

defmodule SamenCore.Support.RevealDomain.RevealPerson do
  require Logger

  # R1 — the DECLARED reveal action, in the EXACT on-disk Ash generic-action
  #      shape `action :name, :return_type do … end` (matches the real
  #      RevealPerson fixture). Its body logs the revealed value. Allowed: this
  #      IS the reveal chokepoint (declared `reveal :reveal_email`).
  action :reveal_email, :string do
    subject = fetch_subject()
    Logger.info("revealed emails for #{subject.emails}")
  end

  defp fetch_subject, do: %{emails: "…"}
end
