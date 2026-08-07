defmodule Samen.Mailbox.Match do
  @moduledoc """
  CRM matching for the mailbox sync (spec §I1, T74): resolve a message's
  COUNTERPARTY address to the Person (and, through it, the Company) whose timeline
  the message belongs on.

  ## Matching a VAULTED address

  A CRM `Person`'s `emails` is vault-routed (`:pii_email`) — there is no plaintext
  email column anywhere to `WHERE` against (INV-1), so matching cannot be a SQL
  predicate. It runs through the SAME governed read seam every other surface uses:

    1. read the org's candidate people (org-pinned, BOUNDED by
       `config.max_match_candidates` — never an unbounded table scan);
    2. resolve them through `Samen.Api.PiiResolution.resolve/4` on the **tenant
       plane** (the org reads its OWN contacts' PII in clear — the tenant-as-owner
       rule; no reveal grant is minted and the vault is never touched directly);
    3. compare NORMALIZED addresses (trim + NFC + downcase, the same normalization
       `Samen.Auth.BlindIndex.normalize/1` uses so `" A@Ex.TEST "` matches
       `a@ex.test`).

  This module NEVER calls `Samen.Vault.reveal/3` and never unwraps a `%Masked{}`.
  If resolution comes back masked (an actor/plane that may not read the PII), the
  address simply does not match — the honest, fail-closed answer. A message with no
  match is still recorded, anchored to nothing; it is never attached to an
  arbitrary record.

  ## Company

  Precedence: the matched person's `company_id` first (the authoritative CRM link),
  then the counterparty address's DOMAIN against `Company.domain` — a plain,
  non-PII column, so the domain fallback is an ordinary org-scoped query.
  """

  require Ash.Query

  alias Samen.Api.PiiResolution
  alias Samen.Mailbox.Config

  @doc """
  Normalize an address for comparison: trim + NFC + downcase (identical to
  `Samen.Auth.BlindIndex.normalize/1`).
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(address) when is_binary(address) do
    address
    |> String.trim()
    |> String.normalize(:nfc)
    |> String.downcase()
  end

  def normalize(_), do: nil

  @doc "The domain part of an address, normalized. `nil` when there is no `@`."
  @spec domain(term()) :: String.t() | nil
  def domain(address) do
    case normalize(address) do
      nil ->
        nil

      norm ->
        case String.split(norm, "@") do
          [_local, dom] when dom != "" -> dom
          _ -> nil
        end
    end
  end

  @doc """
  A stable, NON-REVERSIBLE thread key for a message: SHA-256 of the provider's
  thread id, else the RFC-5322 `In-Reply-To`/root `References` value, else the
  message's own external id. Hashing keeps a Message-ID (which can embed an
  address) out of a plain column while still grouping a conversation.
  """
  @spec thread_key(Samen.Mailbox.Message.t()) :: String.t() | nil
  def thread_key(%Samen.Mailbox.Message{} = msg) do
    seed =
      first_binary([
        msg.thread_id,
        msg.in_reply_to,
        List.first(msg.references || []),
        msg.external_id
      ])

    case seed do
      nil -> nil
      value -> :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
    end
  end

  @doc """
  Find the org's CRM `Person` whose vaulted `emails` contains `address`. Returns
  the resolved record or `nil`. `nil` person resource ⇒ matching disabled ⇒ `nil`.
  """
  @spec person_for_address(term(), Config.t()) :: struct() | nil
  def person_for_address(_address, %Config{person_resource: nil}), do: nil

  def person_for_address(address, %Config{} = config) do
    case normalize(address) do
      nil ->
        nil

      norm ->
        config
        |> candidate_people()
        |> Enum.find(fn person -> norm in resolved_addresses(person) end)
    end
  end

  @doc """
  Find the CRM `Company` for a message: the matched person's `company_id` first,
  then the address DOMAIN against the non-PII `Company.domain` column.
  """
  @spec company_for(struct() | nil, term(), Config.t()) :: struct() | nil
  def company_for(_person, _address, %Config{company_resource: nil}), do: nil

  def company_for(person, address, %Config{} = config) do
    company_by_id(person, config) || company_by_domain(address, config)
  end

  # ---------------------------------------------------------------------------
  # Private

  # Org-pinned, BOUNDED candidate read. `authorize?: false` with an explicit
  # `org_id` filter is the same posture the C5 inbound consumer uses: the org
  # boundary is pinned from trusted config, never from the message.
  defp candidate_people(%Config{} = config) do
    records =
      config.person_resource
      |> Ash.Query.new()
      # `emails` is vault-routed: it must be EXPLICITLY selected or the resolver has
      # nothing to resolve and every match would silently miss.
      |> Ash.Query.ensure_selected([:emails, :company_id])
      |> Ash.Query.filter(org_id == ^config.org_id)
      |> Ash.Query.limit(config.max_match_candidates)
      |> Ash.read!(authorize?: false)

    PiiResolution.resolve(records, config.person_resource, %{plane: :tenant}, repo: config.repo)
  rescue
    _ -> []
  end

  # A `%Samen.Masked{}` (or anything that is not a resolved composite) yields NO
  # addresses — an unresolvable person simply does not match. Never unwrapped.
  defp resolved_addresses(%{emails: %Samen.Type.Emails{entries: entries}}) when is_list(entries),
    do: entries |> Enum.map(&entry_address/1) |> Enum.reject(&is_nil/1)

  defp resolved_addresses(%{emails: entries}) when is_list(entries),
    do: entries |> Enum.map(&entry_address/1) |> Enum.reject(&is_nil/1)

  # A resolved composite can come back as its JSON encoding (the same shape the CRM
  # render helpers already handle — `Samen.Web.CRM.ContactLive.render_email/1`).
  defp resolved_addresses(%{emails: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> resolved_addresses(%{emails: list})
      {:ok, %{"entries" => list}} when is_list(list) -> resolved_addresses(%{emails: list})
      _ -> []
    end
  end

  defp resolved_addresses(_), do: []

  defp entry_address(%{address: address}), do: normalize(address)
  defp entry_address(%{"address" => address}), do: normalize(address)
  defp entry_address(_), do: nil

  defp company_by_id(%{company_id: company_id}, config) when is_binary(company_id) do
    config.company_resource
    |> Ash.Query.new()
    |> Ash.Query.filter(org_id == ^config.org_id and id == ^company_id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  defp company_by_id(_person, _config), do: nil

  defp company_by_domain(address, config) do
    case domain(address) do
      nil ->
        nil

      dom ->
        config.company_resource
        |> Ash.Query.new()
        |> Ash.Query.filter(org_id == ^config.org_id and domain == ^dom)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
        |> List.first()
    end
  rescue
    _ -> nil
  end

  defp first_binary(values) do
    Enum.find(values, fn v -> is_binary(v) and v != "" end)
  end
end
