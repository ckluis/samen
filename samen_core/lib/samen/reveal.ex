defmodule Samen.Reveal.Context do
  @moduledoc """
  The context a `Samen.Reveal.Grant` implementation decides on: who is asking
  (`actor`), for whose data (`subject_id`), on which `resource`/`action`, and the
  masked field's `label`. T1.6's grant model keys its distinct-party / time-boxed
  lookup on these.
  """
  @enforce_keys [:actor, :resource, :action]
  defstruct [:actor, :subject_id, :resource, :action, :label]

  @type t :: %__MODULE__{
          actor: term(),
          subject_id: String.t() | nil,
          resource: module(),
          action: atom(),
          label: atom() | nil
        }
end

defmodule Samen.Reveal.Grant do
  @moduledoc """
  Behaviour for the reveal grant seam (T1.6 fills this).

  A single callback, `granted?/1`, decides whether the given
  `Samen.Reveal.Context` is authorized to reveal plaintext. Return `true` ONLY for
  an active, unexpired, distinct-party-approved grant (T1.6). Anything else must
  return `false` — the reveal runtime treats `false` as `{:error, :denied}` and
  never touches the vault decrypt path.

  The DEFAULT implementation is `Samen.Reveal.DenyAll` (returns `false` for
  everything). Configure the real model with:

      config :samen_core, :reveal_grant, MyApp.Reveal.Grant
  """
  @callback granted?(Samen.Reveal.Context.t()) :: boolean()
end

defmodule Samen.Reveal.DenyAll do
  @moduledoc """
  Default `Samen.Reveal.Grant` implementation: **deny everything**.

  This is the fail-closed seam T1.6 replaces. With no grant model configured,
  every `:reveal` denies — plaintext is never produced without an explicit,
  approving grant. A test or host that needs a reveal to succeed must configure an
  approving checker; the kernel ships denying.
  """
  @behaviour Samen.Reveal.Grant

  @impl true
  def granted?(_context), do: false
end

defmodule Samen.Reveal do
  @moduledoc """
  The `:reveal` runtime seam (T1.5 clause (c)): return vault plaintext for a
  **granted** actor, and **deny by default** otherwise.

  A reveal action is a first-class, introspectable marker on an Ash action
  (`reveal :action` in the `pii do` block; see `Samen.Pii.RevealAction` /
  `Samen.Pii.Info.reveal_action?/2`). This module is what such an action calls to
  actually produce plaintext. It enforces two gates in order:

    1. **Marker gate** — the action must be a declared reveal action for the
       resource. A non-reveal action can never produce plaintext through here.
    2. **Grant gate** — a `Samen.Reveal.Grant` implementation must approve the
       (actor, subject, resource, action) tuple. Without an approving grant, this
       denies with `{:error, :denied}` and NEVER touches the vault decrypt path.

  Only after BOTH gates pass does it call the single vault chokepoint
  (`Samen.Vault.reveal/3`). Plaintext is therefore produced by exactly one code
  path, guarded by the grant model.

  ## The grant seam T1.6 fills (default deny)

  `Samen.Reveal.Grant` is a behaviour with a single callback,
  `granted?(context) :: boolean`. The DEFAULT implementation is
  `Samen.Reveal.DenyAll`, which returns `false` for everything — so with no grant
  model wired, every ungranted `:reveal` denies (fail closed). T1.6 ships the real
  `RevealRequest` → distinct-party-approval → time-boxed grant model and configures
  it here:

      config :samen_core, :reveal_grant, MyApp.Reveal.Grant

  Until then, `Samen.Reveal.reveal/5` denies unless a test/host explicitly
  configures an approving grant checker. This is the policy seam, not a policy.
  """

  alias Samen.Masked
  alias Samen.Pii.Info
  alias Samen.Reveal.Context

  @doc """
  Reveal the plaintext behind a `%Masked{}` value for `actor` performing
  `action_name` on `resource`.

  Denies (`{:error, :denied}`) unless BOTH:
    * `action_name` is a declared reveal action on `resource`
      (`Samen.Pii.Info.reveal_action?/2`), and
    * the configured `Samen.Reveal.Grant` implementation approves the context.

  Only then does it call `Samen.Vault.reveal/3` (the single decrypt chokepoint),
  which itself fails closed on shred / KMS outage. Returns:

    * `{:ok, plaintext}` — granted and decryptable
    * `{:error, :not_reveal_action}` — the action is not a declared reveal action
    * `{:error, :denied}` — no approving grant (default with DenyAll)
    * `{:error, :shredded | :unavailable | :not_found | term}` — from the vault

  Required option:
    * `:repo` — the Ecto repo for the vault-row lookup.

  Optional:
    * `:subject_id` — the subject the grant is checked against (lets the grant
      model scope by subject before any vault hit).
    * `:vault` — the `Samen.Vault` module to call (defaults to `Samen.Vault`,
      injectable for tests).
    * `:grant` — override the configured grant checker (injectable for tests).
  """
  @spec reveal(term(), Masked.t(), atom(), module(), keyword()) ::
          {:ok, binary()}
          | {:error, :not_reveal_action | :denied | :shredded | :unavailable | :not_found | term}
  def reveal(actor, %Masked{} = masked, action_name, resource, opts \\ []) do
    vault_mod = Keyword.get(opts, :vault, Samen.Vault)
    grant_mod = Keyword.get(opts, :grant, grant_checker())

    context = %Context{
      actor: actor,
      subject_id: Keyword.get(opts, :subject_id),
      resource: resource,
      action: action_name,
      label: masked.label
    }

    cond do
      # Marker gate: only a declared reveal action can produce plaintext here.
      not Info.reveal_action?(resource, action_name) ->
        {:error, :not_reveal_action}

      # Grant gate: default-deny. No approving grant → deny, never decrypt.
      not grant_mod.granted?(context) ->
        {:error, :denied}

      true ->
        # Both gates passed → the single vault chokepoint.
        repo = Keyword.fetch!(opts, :repo)
        vault_mod.reveal(masked, repo, Keyword.take(opts, [:subject_id]))
    end
  end

  @doc """
  The configured `Samen.Reveal.Grant` implementation. Defaults to
  `Samen.Reveal.DenyAll` (fail closed) until T1.6 wires the real grant model via
  `config :samen_core, :reveal_grant, MyApp.Reveal.Grant`.
  """
  @spec grant_checker() :: module()
  def grant_checker do
    Application.get_env(:samen_core, :reveal_grant, Samen.Reveal.DenyAll)
  end
end
