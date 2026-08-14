defmodule Samen.AI.Domain do
  @moduledoc """
  The Ash domain that hosts the reusable AI-plane resources: the D3 managed-prompt
  resource (`Samen.AI.Prompt`, ADR-043 §7.5, T68), the D5 AI-support-operator draft
  resource (`Samen.AI.SupportReplyDraft`, ADR-043 §6.3, T70), and the agent-loop
  run/turn cursor rows (`Samen.AI.Agent.Run` / `Samen.AI.Agent.Turn`, ADR-047 A1).

  These are reusable kernel infrastructure, not per-host fixtures, so they live in their
  own domain a host mounts by adding `Samen.AI.Domain` to its own `:ash_domains` config
  (framework-first — the host's only authored line, INV-5). samen_core registers it in ITS
  OWN `:ash_domains` (config.exs) so the kernel's own test/dev suite can exercise the
  resources against `SamenCore.TestRepo` with real migrations, exactly as
  `Samen.CustomObjects.Domain` does for `tnt_record`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.AI.Prompt)
    resource(Samen.AI.SupportReplyDraft)
    resource(Samen.AI.Agent.Run)
    resource(Samen.AI.Agent.Turn)
  end
end
