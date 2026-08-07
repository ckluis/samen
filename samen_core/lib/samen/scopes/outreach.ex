defmodule Samen.Scopes.Outreach do
  @moduledoc """
  The **Outreach** universal scope (spec §I2 CRM sequences actually send, T75).
  Ships as a **library-authored blueprint** (ADR-004), same shape as
  `Samen.Scopes.Mailbox`: `use`-ing this module inside a host's Ash domain expands
  into three host-owned resources in the host's namespace, each a normal
  `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## Resources

    * **`Sequence`** — a tenant-defined multi-step outreach sequence (`steps`:
      bounded ordered jsonb, tenant-authored template config, no PII).
    * **`Enrollment`** — one CRM contact's (`person_id`, opaque uuid, no FK)
      membership in a `Sequence`; carries the AshOban `:sequence_step_due`
      schedule trigger.
    * **`StepSend`** — one step's honest send outcome
      (`:queued | :delivered | :blocked | :suppressed | :failed | :skipped`).

  See `Samen.Scopes.Outreach.Blueprint` for the full field map and the C2/reply-
  detection wiring this scope depends on (`Samen.Sequences`).

  ## Framework-first, ≈0-LOC adoption

  A vertical adopts sequences with ONE `use` line — no per-vertical resource,
  migration, policy, or send-path code is re-authored. Sends route through the
  SAME `Samen.Delivery.Chokepoint` (C2) every other send family uses; reply
  detection reads the SAME `Samen.Mailbox` seam (T74) a host that has already
  adopted two-way email sync gets for free by wiring
  `Samen.Sequences.MailboxReplyCheck` (`config :samen_core,
  Samen.Sequences.ReplyCheck, module: Samen.Sequences.MailboxReplyCheck`).

  ## Mounting the Outreach scope (the host side)

      defmodule Demo.Outreach do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Outreach,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Outreach,
          abbrevs: %{sequence: "dqs", enrollment: "dqe", step_send: "dqt"}
      end

  ## Abbrevs (permanent, registry-checked)

  No scope-default (mirrors Mailbox/Views/Docs/Tags): `abbrevs:` is REQUIRED and
  every host takes fresh allocator-proposed abbrevs reserved via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs):

    * `SamenCore.Support.OutreachFixture.Sequence`   → `sos`
    * `SamenCore.Support.OutreachFixture.Enrollment` → `soe`
    * `SamenCore.Support.OutreachFixture.StepSend`   → `sso`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    sequence_mod = Module.concat(namespace, Sequence)
    enrollment_mod = Module.concat(namespace, Enrollment)
    step_send_mod = Module.concat(namespace, StepSend)

    quote do
      require Samen.Scopes.Outreach.Blueprint

      resources do
        resource(unquote(sequence_mod))
        resource(unquote(enrollment_mod))
        resource(unquote(step_send_mod))
      end

      Samen.Scopes.Outreach.Blueprint.define_sequence(
        unquote(sequence_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.sequence)
      )

      Samen.Scopes.Outreach.Blueprint.define_enrollment(
        unquote(enrollment_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.enrollment),
        unquote(sequence_mod),
        unquote(step_send_mod)
      )

      Samen.Scopes.Outreach.Blueprint.define_step_send(
        unquote(step_send_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.step_send),
        unquote(enrollment_mod)
      )
    end
  end

  # No scope-default: `abbrevs:` is REQUIRED (mirrors Mailbox/Views/Docs/Tags).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Outreach, abbrevs: must be a compile-time map literal " <>
            "(%{sequence: \"sos\", enrollment: \"soe\", step_send: \"sso\"}). " <>
            "Got: #{Macro.to_string(other)}"
  end
end
