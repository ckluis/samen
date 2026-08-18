defmodule SamenCore.Support.RevealFixtures do
  @moduledoc """
  T1.5 test fixtures for the `:reveal` marker + `Samen.Reveal` grant seam.

  `RevealPerson` declares a vault-routed PII field and marks `:reveal_email` as a
  reveal action via the first-class `reveal :action` DSL. Downstream introspection
  (`Samen.Pii.Info.reveal_action?/2`) resolves the marker from the DECLARATION,
  never from the action name — `:reveal_email` and the deliberately-named
  `:read_email_looks_like_reveal` (NOT declared) prove that.
  """
end

defmodule SamenCore.Support.RevealDomain do
  @moduledoc "Kernel test fixture domain for the reveal marker."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.RevealDomain.RevealPerson)
  end
end

defmodule SamenCore.Support.RevealDomain.RevealPerson do
  @moduledoc """
  A resource with a vault-routed PII field and a declared `reveal` action.

  Note the two custom actions:
    * `:reveal_email` — DECLARED as a reveal action via `reveal :reveal_email`.
    * `:read_email_looks_like_reveal` — its name contains "reveal" but it is NOT
      declared. `Samen.Pii.Info.reveal_action?/2` must return `false` for it,
      proving the marker is declaration-driven, not name-matched (Gate-0 fix #6).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.RevealDomain,
    data_layer: AshPostgres.DataLayer,
    abbrev: "rvp"

  postgres do
    table("rvp_reveal_person")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:display_name, :string, public?: true)
  end

  pii do
    vault(:pii_email)
    pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)

    # First-class reveal marker: :reveal_email is a reveal action.
    reveal(:reveal_email)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # A generic action declared as the reveal action.
    action :reveal_email, :string do
    end

    # A non-reveal action whose NAME contains "reveal" — the false-positive trap.
    action :read_email_looks_like_reveal, :string do
    end
  end

  # ai_prompt_masking (b) non-vacuity hook (ADR-043 §7.2 / T65): this fixture MODELS the leak
  # the verifier must catch — it declares its vault-routed field (`:emails`) "embeddable". The
  # `mix samen.verify.ai_prompt_masking` (b) cross-check flags exactly this. RevealPerson is
  # test-support only (never in a configured `:ash_domains`), so the CI verifier run does not
  # scan it — only the unit test does, explicitly, as the sabotage-refutable proof.
  def embeddable_fields, do: [:emails]
end
