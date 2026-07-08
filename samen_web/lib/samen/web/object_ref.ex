defmodule Samen.Web.ObjectRef do
  @moduledoc """
  The **object-unfurl** framework capability (ADR-012 §4) — the crown jewel. Turns a
  catalogued object reference (`samen:<resource-key>:<id>`) pasted into ANY text into a
  render-ready, **masking-aware-per-viewer** card, by construction.

  This is a STANDALONE framework service — chat is its first consumer, not its owner. A CRM
  detail page can unfurl a related object, an audit log can unfurl an event's subject, a
  notification can unfurl its target. Every vertical inherits object unfurl for every
  catalogued resource, for free.

  ## The ref format

  `samen:<resource-key>:<id>` where `<resource-key>` is the resource-qualified catalog key
  (`crm.person`, `support.ticket`, `billing.invoice`, `freight.driver`) and `<id>` is a
  UUID-shaped id. The key is NOT a raw module name — a paste never leaks `Driftwood.Crm.Person`.
  A bare UUID with no `samen:` prefix is NOT unfurled (the scheme is the explicit opt-in; this
  avoids false positives on arbitrary ids).

  ## Masking BY CONSTRUCTION (the single most important invariant, ADR-012 §1.1)

  `resolve/3` is a COMPOSITION of two kernel gates over the host's OWN resource — it adds no
  new masking code and no new authorization check:

    1. **Load through Ash with the VIEWER'S scope.** `Samen.Policy.OrgScope` narrows the read
       to `scope.actor.org_id`. A ref the viewer's org can't read returns `[]` →
       `{:error, :not_found}` — indistinguishable from a nonexistent id (no cross-org existence
       oracle, no leak). This is the "org-scope the resolve" requirement, satisfied by REUSING
       the kernel policy, not by a bespoke check.
    2. **Resolve PII for the viewer's plane.** `Samen.Api.PiiResolution.resolve/4` rewrites each
       vaulted field to its plane-correct value: the SAME record resolves CLEAR for a
       `plane: :tenant` viewer and `%Masked{}` (→ `••••`) for a `plane: :operator` viewer. This
       is literally the ADR-010 resolver, reused — the per-viewer unfurl-masking property.

  There is NO code path here that reads a column directly, unwraps a `%Masked{}`, calls
  `Samen.Vault.reveal/3`, or bypasses `Ash.read`. The card carries the ALREADY-RESOLVED record;
  a `%Masked{}` in any field renders `••••` verbatim through `Phoenix.HTML.Safe`. A resolver
  failure fails SAFE: `{:error, _}` renders an inert chip, never plaintext, never a raise.
  """

  alias Samen.Web.Mount
  alias Samen.Web.ObjectRef.{Card, Catalog, Registry}

  require Ash.Query

  @enforce_keys [:key, :id]
  defstruct [:key, :id, :raw]

  @type t :: %__MODULE__{key: String.t(), id: String.t(), raw: String.t()}

  @typedoc "The resolver's failure reasons. Each renders an inert chip, never plaintext."
  @type error :: :not_found | :unknown_key | :forbidden

  # A resource key: dotted, lowercase (`crm.person`, `support.ticket`, `freight.driver`).
  @key_rx "[a-z][a-z0-9_]*(?:\\.[a-z][a-z0-9_]*)+"
  # A UUID-shaped id (the kernel mints v4 UUIDs). Bounded so a ref is auditable.
  @uuid_rx "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

  @ref_rx Regex.compile!("samen:(#{@key_rx}):(#{@uuid_rx})")

  @doc """
  Parse every `samen:<key>:<id>` ref out of `text`, in order, de-duplicated.

  Runs ONCE at send time on the PLAINTEXT body (before the body is vaulted) so unfurl never
  re-parses ciphertext (§4.2). A bare UUID with no `samen:` prefix is ignored. Returns a list
  of `%Samen.Web.ObjectRef{}`; the empty list for text with no refs.
  """
  @spec parse(String.t() | nil) :: [t()]
  def parse(nil), do: []

  def parse(text) when is_binary(text) do
    @ref_rx
    |> Regex.scan(text)
    |> Enum.map(fn [raw, key, id] -> %__MODULE__{key: key, id: id, raw: raw} end)
    |> Enum.uniq_by(fn %__MODULE__{key: k, id: i} -> {k, i} end)
  end

  @doc """
  Rebuild an `%ObjectRef{}` from a stored ref string (`ChatMessage.refs` entries) —
  `{:ok, ref}` or `:error` for a malformed string. The inverse of `to_string/1`.
  """
  @spec from_string(String.t()) :: {:ok, t()} | :error
  def from_string(str) when is_binary(str) do
    case parse(str) do
      [%__MODULE__{raw: ^str} = ref | _] -> {:ok, ref}
      [%__MODULE__{} = ref | _] -> {:ok, ref}
      [] -> :error
    end
  end

  @doc "The canonical ref string for a resource key + id (the composer's \"copy ref\" output)."
  @spec to_string(String.t(), String.t()) :: String.t()
  def to_string(key, id) when is_binary(key) and is_binary(id), do: "samen:#{key}:#{id}"

  @doc "The canonical ref string for a resource module + id (derives the key from the module)."
  @spec ref_for(module(), String.t()) :: String.t()
  def ref_for(resource, id) when is_atom(resource) and is_binary(id) do
    __MODULE__.to_string(Catalog.key_for(resource), id)
  end

  @doc """
  Resolve a ref into a render-ready, per-viewer `%Card{}` — masking BY CONSTRUCTION.

  `mount` is the viewer's `%Samen.Web.Mount{}` (carries namespace + repo + plane); `scope` is
  the viewer's `%Samen.Scope{}` (carries the actor whose `org_id`/`plane` drive both gates).

    * `{:ok, %Card{}}`         — resolved; every field already run through `PiiResolution`.
    * `{:error, :unknown_key}` — the key maps to no catalogued resource for this mount.
    * `{:error, :not_found}`   — no row for this id under the viewer's org-scope (also the
                                 cross-org case: the row exists for another org → zero rows →
                                 not_found, no existence oracle).
    * `{:error, :forbidden}`   — a load raised under authorization (fail-safe).
  """
  @spec resolve(Mount.t(), Samen.Scope.t(), t()) :: {:ok, Card.t()} | {:error, error()}
  def resolve(%Mount{} = mount, scope, %__MODULE__{key: key, id: id}) do
    with {:ok, resource} <- Catalog.resource_for(mount, key),
         {:ok, record} <- load_scoped(resource, id, scope),
         resolved <- resolve_pii(record, resource, mount, scope) do
      {:ok, Registry.card_for(mount, key, resource, resolved)}
    end
  end

  @doc """
  Resolve a stored ref STRING directly into `{:ok, %Card{}} | {:error, reason}` — the shape a
  message-render loop wants (it stores refs as strings on `ChatMessage.refs`). A malformed
  string is `{:error, :unknown_key}` (an inert chip, never a raise).
  """
  @spec resolve_string(Mount.t(), Samen.Scope.t(), String.t()) ::
          {:ok, Card.t()} | {:error, error()}
  def resolve_string(%Mount{} = mount, scope, str) when is_binary(str) do
    case from_string(str) do
      {:ok, ref} -> resolve(mount, scope, ref)
      :error -> {:error, :unknown_key}
    end
  end

  # -- private -----------------------------------------------------------------

  # Load the ONE row by id through Ash WITH THE VIEWER'S SCOPE. OrgScope narrows to
  # scope.actor.org_id — a cross-org id returns [] (→ not_found), never a leak. A raise
  # (authorization / bad id) is caught and mapped to :forbidden (fail-safe: no plaintext).
  #
  # `ensure_selected/2` all of the resource's own attributes (including the vaulted ones,
  # which load as `%Masked{}`) so the default/override card has the fields to render — a
  # not-selected vaulted field would come back `%Ash.NotLoaded{}`, not `%Masked{}`. Selecting
  # the vault field NEVER leaks: it loads as the token-only `%Masked{}`, and PiiResolution
  # (step 3) resolves it per plane. Same discipline as `Samen.Web.CRM.Reads`.
  defp load_scoped(resource, id, scope) do
    resource
    |> Ash.Query.ensure_selected(selectable_attrs(resource))
    |> Ash.Query.filter(id == ^id)
    |> Ash.read!(scope: scope)
    |> case do
      [record | _] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :forbidden}
  end

  # All of the resource's own attribute names (public + private) so the card can render them.
  # A vaulted attribute is selected as its `%Masked{}` token value, never plaintext.
  defp selectable_attrs(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.map(& &1.name)
  rescue
    _ -> []
  end

  # Resolve vaulted fields through the shared chokepoint for the viewer's plane. Fail-safe:
  # on any resolver error the fields stay %Masked{} (`••••`) — NEVER a plaintext downgrade.
  # This is the SAME discipline as Samen.Web.CRM.Reads.resolve_pii/4.
  defp resolve_pii(record, resource, mount, scope) do
    [resolved] =
      Samen.Api.PiiResolution.resolve([record], resource, actor_of(scope), repo: mount.repo)

    resolved
  rescue
    _ -> record
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
