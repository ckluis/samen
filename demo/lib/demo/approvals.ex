require Samen.Approvals.Blueprint

Samen.Approvals.Blueprint.define_approval(
  Demo.Approvals.Approval,
  :demo,
  Demo.Approvals,
  Demo.Repo,
  "daa"
)

defmodule Demo.Approvals do
  @moduledoc """
  T35 §4.7 — the per-host materialization of the T34 E3 `Approval` resource
  (`Samen.Approvals.Blueprint.define_approval/5`), Demo's engine client for the
  `"pii_reveal"` kind (`Samen.Reveal.ApprovalHandler`; wired in `config/config.exs`).

  Deliberately NOT in `:ash_domains` — a kernel-owned decision table (see
  `Samen.Approvals.Blueprint` moduledoc), same posture as `SamenCore.Support.ApprovalsFixture`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Demo.Approvals.Approval)
  end
end
