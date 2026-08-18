defmodule Samen.Policy.Verified do
  @moduledoc """
  ADR-035 §5 A2 — the capability-limiting gate for an unverified `Credential`.

  A `SimpleCheck` that authorizes only when `actor.verified?` is `true`. Reads
  `actor.verified?` — the ADR-035 actor-map addition, set by the auth seam
  once `Credential.verified_at` resolves (`false`/absent while
  `verified_at: nil`).

  ## Usage

      policies do
        policy action(:create) do
          authorize_if(Samen.Policy.Verified)
        end
      end

  Fail closed: an actor with no `verified?` key, a `false` value, or a
  non-map actor is DENIED. ADR-035 §5 A2's bounded allowed set for an
  unverified principal (onboarding, own-profile edit, resend verification,
  logout) never routes through a `Samen.Policy.Verified`-gated action —
  invitations (`Identity.Invitation.create`, wired here) are the ADR's named
  example of a capability an unverified account may NOT reach.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor.verified? is true"

  @impl true
  def match?(actor, _context, _opts) when is_map(actor), do: Map.get(actor, :verified?) == true
  def match?(_actor, _context, _opts), do: false
end
