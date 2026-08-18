defmodule Samen.Scopes.Mailbox do
  @moduledoc """
  The **Mailbox** universal scope (spec §I1 CRM two-way email sync, T74). Ships as a
  **library-authored blueprint** (ADR-004), same shape as
  `Samen.Scopes.Views`/`Samen.Scopes.Tags`: `use`-ing this module inside a host's Ash
  domain expands into two host-owned resources in the host's namespace, each a normal
  `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## Resources

    * **`Connection`** 🔒 — one user's connected mailbox (`address` → `:pii_email`).
    * **`MailMessage`** 🔒 — one synced or sent email (`subject`/`body` →
      `:pii_body`, `counterparty_address` → `:pii_email`), anchored to the CRM by
      the generic `(subject_key, subject_id)` object-ref.

  See `Samen.Scopes.Mailbox.Blueprint` for the full field/PII map.

  ## Framework-first, ≈0-LOC adoption

  A vertical that already mounts CRM adopts two-way email sync with ONE `use` line
  plus a `Samen.Mailbox.Config` naming its own modules — no per-vertical resource,
  migration logic, policy, matching, or masking is re-authored. The CRM detail
  timelines pick the messages up automatically (`Samen.Web.CRM.Reads` derives the
  host's `Mailbox.MailMessage` from the CRM mount and returns an HONEST empty list
  when the scope is not mounted). `Samen.WebTest.Mailbox` is the reference adopter.

  ## Mounting the Mailbox scope (the host side)

      defmodule Demo.Mailbox do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Mailbox,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Mailbox,
          abbrevs: %{connection: "dmc", mail_message: "dmm"}
      end

  ## Abbrevs (permanent, registry-checked)

  No scope-default (mirrors Views/Docs/Tags): `abbrevs:` is REQUIRED and every host
  takes fresh allocator-proposed abbrevs reserved via `mix samen.abbrev.reserve`
  (ADR-023 — the macro does NOT invent abbrevs):

    * `Samen.WebTest.Mailbox.Connection`  → `mwc`
    * `Samen.WebTest.Mailbox.MailMessage` → `wmm`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    connection_mod = Module.concat(namespace, Connection)
    mail_message_mod = Module.concat(namespace, MailMessage)

    quote do
      require Samen.Scopes.Mailbox.Blueprint

      resources do
        resource(unquote(connection_mod))
        resource(unquote(mail_message_mod))
      end

      Samen.Scopes.Mailbox.Blueprint.define_connection(
        unquote(connection_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.connection)
      )

      Samen.Scopes.Mailbox.Blueprint.define_mail_message(
        unquote(mail_message_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.mail_message),
        unquote(connection_mod)
      )
    end
  end

  # No scope-default: `abbrevs:` is REQUIRED (mirrors Views/Docs/Tags — every host
  # takes fresh allocator-proposed abbrevs).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Mailbox, abbrevs: must be a compile-time map literal " <>
            "(%{connection: \"mwc\", mail_message: \"wmm\"}). Got: #{Macro.to_string(other)}"
  end
end
