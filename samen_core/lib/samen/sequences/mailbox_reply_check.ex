defmodule Samen.Sequences.MailboxReplyCheck do
  @moduledoc """
  The PRODUCTION `Samen.Sequences.ReplyCheck` implementation (spec §I2) — reads
  the ALREADY-SHIPPED T74 Mailbox seam. NO new inbound ingestion mechanism: this
  module only READS `Samen.Mailbox.MailMessage`-shaped rows the existing
  `Samen.Mailbox.Sync` engine already writes, using the SAME generic CRM object-
  ref anchor (`subject_key: "crm.person"`, `subject_id: person_id`) it anchors
  on.

  Wire it as:

      config :samen_core, Samen.Sequences.ReplyCheck,
        module: Samen.Sequences.MailboxReplyCheck

      config :samen_core, Samen.Sequences.MailboxReplyCheck,
        message_resource: MyApp.Mailbox.MailMessage

  ## Org-pinned by construction

  The read carries an explicit `org_id == ^org_id` filter (never relies on
  `Ash.Query`'s default policy-driven scoping, mirroring
  `Samen.Mailbox.Match.candidate_people/1`'s "org-id pinned from trusted config,
  never from the message" posture) — a reply recorded for a DIFFERENT org's
  identically-shaped `person_id` (UUIDs are global, not per-org) can never leak
  across the boundary.

  ## Two clocks, each compared with its own kind

  A message counts when it was INGESTED at or after the cutoff (`ingested_at`, our
  clock, microseconds) and SENT at or after the floor (`occurred_at`, the provider's
  clock). Comparing the provider's `occurred_at` with our cutoff (#116) missed a reply
  synced after a resume, re-paused on a provider clock running ahead of ours, and
  re-paused on a resume in the same second as the reply. `occurred_at` is stored to the
  second, so the floor is truncated to the second before comparing: a reply in the
  enrollment's own second still counts.

  ## Unconfigured => `false` (never raises the "unwired" case)

  No `:message_resource` configured is the SAME honest absence
  `Samen.Sequences.ReplyCheck` reports for a `nil` module — a host that has not
  adopted the Mailbox seam simply never auto-pauses on reply. A REAL query
  failure (a broken message_resource, a DB error) raises up through this
  function's `rescue`-free body so the caller (`ReplyCheck.replied_since?/4`,
  which wraps every configured module call in its own `rescue`) fails CLOSED.
  """

  @behaviour Samen.Sequences.ReplyCheck

  require Ash.Query

  @impl true
  def replied_since?(org_id, person_id, %DateTime{} = cutoff, %DateTime{} = floor) do
    case message_resource() do
      nil ->
        false

      resource ->
        sent_floor = DateTime.truncate(floor, :second)

        resource
        |> Ash.Query.new()
        |> Ash.Query.filter(
          org_id == ^org_id and subject_key == "crm.person" and subject_id == ^person_id and
            direction == :inbound and ingested_at >= ^cutoff and occurred_at >= ^sent_floor
        )
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
        |> Enum.any?()
    end
  end

  defp message_resource,
    do: Application.get_env(:samen_core, __MODULE__, []) |> Keyword.get(:message_resource)
end
