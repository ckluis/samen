defmodule Samen.Scopes.Chat do
  @moduledoc """
  The **Chat** universal scope (ADR-012 §2) — the flagship cross-plane realtime chat model.

  Ships as a **library-authored blueprint** (ADR-004 shape), hosted in `samen_web` — the
  framework-web library — because chat is a framework-web capability (it consumes
  `Samen.Web.ObjectRef`, `Samen.Web.Plane`, PubSub, Presence) and the hard rule keeps
  `samen_core` code untouched. `use`-ing this module inside a host's Ash domain expands into
  FOUR host-owned resources in the host's namespace — each a normal `use Samen.Resource` (the
  untouched kernel macro) with the host's `otp_app`, `repo`, and `domain`, so every resource
  inherits the SAME vault routing, PII verifiers, `OrgScope`, `SameOrgFk`, and catalog wiring
  as CRM/Billing/Support. Any vertical that mounts this scope inherits realtime chat + object
  unfurl + the 3-state identity model for free.

  ## The four resources (ADR-012 §2.2)

    * `<Host>.Chat.ChatThread`            — a conversation that may span two planes (no PII).
    * `<Host>.Chat.ChatParticipant`       — 🔒 membership + the cross-plane grant carrier
      (`full_name` vault-routed; `handle` the safe label).
    * `<Host>.Chat.ChatMessage`           — 🔒 a single message (`body` vault-routed, the
      Support.Message shape verbatim; `refs` the parsed object refs).
    * `<Host>.Chat.ChatDisclosureSetting` — Tier-0 per-org identity-disclosure config (no PII).

  ## Mounting the Chat scope (the host side)

      defmodule Driftwood.Chat do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Chat,
          otp_app: :driftwood,
          repo: Driftwood.Repo,
          namespace: Driftwood.Chat,
          abbrevs: %{thread: "dct", participant: "dcp", message: "dcm", disclosure_setting: "dcd"}
      end

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name. The framework defaults
  (`cth`/`chp`/`cmg`/`cds`, ADR-012 §11) are provided for the canonical mount; each host passes
  its own prefixed set (driftwood `dct/dcp/dcm/dcd`; the samen_web test host `wct/wcp/wcm/wcd`).
  The macro does NOT invent abbrevs.
  """

  @default_abbrevs %{
    thread: "cth",
    participant: "chp",
    message: "cmg",
    disclosure_setting: "cds"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    thread_mod = Module.concat(namespace, ChatThread)
    participant_mod = Module.concat(namespace, ChatParticipant)
    message_mod = Module.concat(namespace, ChatMessage)
    disclosure_mod = Module.concat(namespace, ChatDisclosureSetting)

    quote do
      require Samen.Scopes.Chat.Blueprint

      resources do
        resource(unquote(thread_mod))
        resource(unquote(participant_mod))
        resource(unquote(message_mod))
        resource(unquote(disclosure_mod))
      end

      Samen.Scopes.Chat.Blueprint.define_thread(
        unquote(thread_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.thread)
      )

      Samen.Scopes.Chat.Blueprint.define_participant(
        unquote(participant_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.participant),
        unquote(thread_mod)
      )

      Samen.Scopes.Chat.Blueprint.define_message(
        unquote(message_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.message),
        unquote(thread_mod),
        unquote(participant_mod)
      )

      Samen.Scopes.Chat.Blueprint.define_disclosure_setting(
        unquote(disclosure_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.disclosure_setting)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain %{atom => string} map,
  # merged over the defaults. Fail closed if a caller passes a non-map or a non-string abbrev.
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Chat, abbrevs: must be a compile-time map literal " <>
            "(%{thread: \"cth\", ...}). Got: #{Macro.to_string(other)}"
  end
end
