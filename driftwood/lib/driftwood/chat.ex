defmodule Driftwood.Chat do
  @moduledoc """
  Driftwood's Chat domain — mounts the framework `Samen.Scopes.Chat` blueprint (ADR-012, the
  FLAGSHIP cross-plane realtime chat), exactly as `Driftwood.Support` mounts the Support scope.
  One `use Samen.Scopes.Chat` expands into four host-owned resources in `Driftwood.Chat.*`:

    * `Driftwood.Chat.ChatThread`            — a conversation that may span the operator↔tenant
      plane boundary (no PII).
    * `Driftwood.Chat.ChatParticipant`       — 🔒 membership + the cross-plane grant carrier
      (`full_name` vault-routed; `handle` the safe label).
    * `Driftwood.Chat.ChatMessage`           — 🔒 a message (`body` vault-routed; `refs` the
      parsed object refs — a pasted `samen:crm.person:<id>` / `samen:freight.driver:<id>`
      unfurls per viewer).
    * `Driftwood.Chat.ChatDisclosureSetting` — Tier-0 per-org identity-disclosure config.

  Fresh `dc*` abbrevs (the `d`-for-driftwood prefix), reserved append-only in the global
  registry. No samen_core CODE changed — only the data-file registry gained the rows.

  Because Driftwood catalogs `freight.driver`, a `samen:freight.driver:<id>` pasted into a chat
  message unfurls via the framework `DefaultCard` for free; Driftwood ALSO registers a bespoke
  `freight.driver` card (`DriftwoodWeb.Chat.DriverCard`) via the mount's `:object_cards` label —
  proving the vertical override seam.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Chat,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Chat,
    abbrevs: %{
      thread: "dct",
      participant: "dcp",
      message: "dcm",
      disclosure_setting: "dcd"
    }
end
