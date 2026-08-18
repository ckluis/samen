defmodule SamenCore.Support.MailboxFixture do
  @moduledoc """
  A SECOND materialization of the already-shipped Mailbox scope blueprint
  (`Samen.Scopes.Mailbox`, T74) inside `samen_core`'s own test suite (T74
  mounted it ONLY in `samen_web`). This exists so
  `samen_core/test/crm/sequence_send_test.exs` can prove
  `Samen.Sequences.MailboxReplyCheck` reads REAL `MailMessage` rows written by
  the SAME anchor convention `Samen.Mailbox.Sync` uses — no new inbound path,
  just a second host mount of the existing blueprint (exactly how CRM is
  already mounted in five-plus hosts).

  Fresh `scm`/`smm` abbrevs (reserved via `mix samen.abbrev.reserve --host
  samen_core --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Mailbox,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.MailboxFixture,
    abbrevs: %{connection: "scm", mail_message: "smm"}
end
