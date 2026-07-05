# CORPUS FILE — legitimate :reveal-scoped sites. NOT compiled.
#
# These DO flow a pii value into a sink, but lexically INSIDE a :reveal-scoped
# action / function. By design (plan S0.7) the walker allows these — flow into
# a sink is permitted only inside :reveal scope. Labeled R1..R4 (reveal class).

defmodule Corpus.RevealActions do
  require Logger

  # R1 — an `action :reveal do ... end` Ash-style action whose body logs the
  #      revealed value. Allowed: this IS the reveal chokepoint.
  action :reveal do
    subject = fetch_subject()
    Logger.info("revealed for #{subject.per_full_name}")
  end

  # R2 — a plain function named `reveal/1`. Reveal-scoped by head name.
  def reveal(subject) do
    IO.puts("revealed ssn: #{subject.pii_ssn}")
    subject.pii_ssn
  end

  # R3 — a reveal-prefixed helper `reveal_email/1`. Reveal-scoped by prefix.
  def reveal_email(contact) do
    Tracer.set_attribute("revealed.email", contact.pii_email)
  end

  # R4 — an explicit `samen_reveal_scope do ... end` marker inside a plain fn,
  #      modelling an explicit reveal chokepoint that is not a `def reveal`.
  def show(patient) do
    samen_reveal_scope do
      IO.puts("dob revealed: #{patient.pii_dob}")
    end
  end

  defp fetch_subject, do: %{per_full_name: "…"}
end
