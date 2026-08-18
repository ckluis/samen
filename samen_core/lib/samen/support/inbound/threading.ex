defmodule Samen.Support.Inbound.Threading do
  @moduledoc """
  Resolve an inbound email onto an EXISTING ticket, or signal a NEW one (T59) — the
  crux security property is that threading is **strictly org-scoped**.

  ## Why self-encoded tokens (no new Message-ID column)

  The shipped Support `Message` resource carries no RFC `Message-ID` storage, and T59
  is `HANDS-OFF` on the abbrev registry (no new columns/resources). So threading keys
  on ticket ids that OUR OWN outbound already encodes into headers/addresses it
  controls — no new persistence:

    * **plus-address token** — outbound `Reply-To: support+ticket-<uuid>@host`; a reply
      lands on `To: support+ticket-<uuid>@host`.
    * **subject token** — `[ticket-<uuid>]` / `[#<uuid>]` appended to the outbound subject.
    * **In-Reply-To / References** — our outbound `Message-ID: <ticket-<uuid>.<nonce>@host>`;
      the client quotes it back in `In-Reply-To`/`References`.

  `candidate_ticket_ids/2` extracts every ticket-id candidate from these
  attacker-quotable fields. **The candidates are UNTRUSTED** — a hostile sender can
  forge any In-Reply-To / subject token / plus-address. That is exactly why the second
  step matters:

  ## The cross-org refusal (`resolve/2`)

  Each candidate is resolved by reading the host `Ticket` resource filtered by
  `id == candidate AND org_id == config.org_id` — where `config.org_id` comes from the
  TRUSTED routing layer (which mailbox received the mail), NEVER from the email. A
  forged reference pointing at ANOTHER org's ticket simply does not match the
  `org_id` filter → no existing ticket → a NEW ticket is opened in the CORRECT org.
  There is no path by which a crafted header attaches an inbound message to a ticket in
  a different org (the ADR-defined `Samen.Policy.OrgScope` read policy is the
  defense-in-depth second layer behind the explicit filter). This is proven refutable
  by the 2-org test: a SAME-org reference DOES thread (positive control), a forged
  cross-org one does NOT.
  """

  require Ash.Query

  alias Samen.Support.Inbound.Config

  @uuid_re ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i

  @doc """
  Pure extraction of candidate ticket-id UUID strings from the parsed inbound. Ordered
  by specificity (plus-address, then subject token, then reference message-ids), unique.
  Untrusted — every candidate must still be org-scope-resolved by `resolve/2`.
  """
  @spec candidate_ticket_ids(map(), Config.t()) :: [String.t()]
  def candidate_ticket_ids(parsed, %Config{} = config) when is_map(parsed) do
    prefix = Regex.escape(config.ticket_token_prefix || "ticket-")

    from_plus = Enum.flat_map(Map.get(parsed, :to, []), &plus_address_ids(&1, prefix))
    from_subject = subject_ids(Map.get(parsed, :subject), prefix)

    from_refs =
      [Map.get(parsed, :in_reply_to) | Map.get(parsed, :references, [])]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&reference_ids(&1, prefix))

    (from_plus ++ from_subject ++ from_refs)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc """
  Org-scoped resolution of the candidates against the host `Ticket` resource. Returns
  `{:existing, ticket}` for the first candidate that resolves IN THIS ORG, else `:new`.
  A candidate at another org never matches the `org_id` filter (cross-org refusal).
  """
  @spec resolve([String.t()], Config.t()) :: {:existing, struct()} | :new
  def resolve(candidates, %Config{} = config) do
    Enum.find_value(candidates, :new, fn id ->
      case load_ticket(id, config) do
        nil -> false
        ticket -> {:existing, ticket}
      end
    end)
  end

  # --- org-scoped ticket read -------------------------------------------------

  defp load_ticket(id, %Config{} = config) do
    if valid_uuid?(id) do
      config.ticket_resource
      # The org filter IS the cross-org gate: id AND org_id must both match. org_id is
      # host-authoritative (trusted routing), never from the untrusted email.
      |> Ash.Query.filter(id == ^id and org_id == ^config.org_id)
      |> Ash.Query.limit(1)
      |> read_one(config)
    else
      nil
    end
  end

  defp read_one(query, %Config{actor: nil}) do
    # authz-scope: no-actor (system ingestion) ticket lookup — the sole caller
    # (load_ticket/2) filters `id == ^id and org_id == ^config.org_id`, so both the PK
    # and the org pin live at the call site; org_id is host-authoritative routing,
    # never from the untrusted email (T132).
    case Ash.read_one(query, authorize?: false) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  defp read_one(query, %Config{actor: actor}) do
    # Defense-in-depth: when the host supplies an org-scoped actor, authorize the read
    # so the OrgScope policy is ALSO in force behind the explicit filter.
    case Ash.read_one(query, actor: actor, authorize?: true) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  # --- pure token extraction --------------------------------------------------

  # `support+ticket-<uuid>@host` — the plus-address local extension carries the id.
  defp plus_address_ids(addr, prefix) when is_binary(addr) do
    case Regex.run(~r/\+#{prefix}(#{uuid_src()})@/i, addr) do
      [_, uuid] -> [uuid]
      _ -> []
    end
  end

  defp plus_address_ids(_, _), do: []

  # `[ticket-<uuid>]`, `[#<uuid>]`, or a bare `ticket-<uuid>` anywhere in the subject.
  defp subject_ids(subject, prefix) when is_binary(subject) do
    Regex.scan(~r/#{prefix}(#{uuid_src()})/i, subject)
    |> Enum.map(fn [_, uuid] -> uuid end)
  end

  defp subject_ids(_, _), do: []

  # A reference message-id from OUR outbound looks like `ticket-<uuid>.<nonce>@host`.
  # Only ids carrying our prefix are trusted as ticket references (a foreign
  # Message-ID with a random uuid must not be mistaken for a ticket id).
  defp reference_ids(msgid, prefix) when is_binary(msgid) do
    case Regex.run(~r/#{prefix}(#{uuid_src()})/i, msgid) do
      [_, uuid] -> [uuid]
      _ -> []
    end
  end

  defp reference_ids(_, _), do: []

  defp uuid_src, do: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

  defp valid_uuid?(id) when is_binary(id), do: Regex.match?(~r/\A#{@uuid_re |> Regex.source()}\z/i, id)
  defp valid_uuid?(_), do: false
end
