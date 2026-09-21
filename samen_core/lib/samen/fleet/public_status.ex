defmodule Samen.Fleet.PublicStatus do
  @moduledoc """
  T166 / ADR-050 (G11) — the PUBLIC-plane projection of the fleet substrate.

  This module computes NOTHING about health. Every status it reports is
  `Samen.Fleet.Registry.build_row/3`'s already-computed one — the same dead-man
  staleness ADR-044 §4.6 ships, derived from `received_at` and the app's own
  `stale_after_s`, never from a producer-chosen `generated_at_us`. Re-implementing
  probing here would have given the public page a SECOND notion of "up", free to
  disagree with the cockpit's; it does not have one.

  What this module does is NARROW. The cockpit row is:

      %{app_id:, slug:, display_name:, mode:, status:, transport:, received_at:,
        stale_after_s:, publish_status:, report:}

  and the public entry is `%Entry{slug:, status:}` — nothing else, ever. The two
  fields are `@enforce_keys` on a closed struct precisely so that widening the
  public plane is a visible, reviewable act rather than a passing `Map.put/3`.

  ## What is deliberately NOT published (INV-2 posture, ADR-050 §5)

    * `app_id` / `org_id` — an identifier correlatable across surfaces;
    * `display_name` — operator- or enrollment-authored text, the most likely
      place a tenant's legal name appears;
    * `base_url` — internal topology;
    * `transport` / `received_at` / `mode` — operational detail that tells a
      reader how often a tenant's infrastructure answers;
    * `report` — the producer's own payload. It is schema-validated at ingest but
      it is still the one field on the row carrying values this cockpit did not
      author, so it never crosses. That is what makes the page token-blind by
      construction rather than by scrubbing.

  ## The two closed vocabularies (ADR-050 §4.2)

  The public vocabulary is SMALLER than the internal one, and the mapping is
  lossy on purpose — the public plane never reports an operator or security ACT:

  | internal (`build_row/3`) | public          | why |
  |--------------------------|-----------------|-----|
  | `:active`                | `:operational`  | reporting inside its window |
  | `:stale`                 | `:degraded`     | dead-man overdue |
  | `:unreachable`           | `:down`         | never reported |
  | `:revoked` (suspended)   | `:maintenance`  | a credential/suspension act is NOT public |
  | `:deregistered`          | — (excluded)    | the app is gone; it is not "down" |
  | anything else            | `:down`         | fail closed: never an all-clear |

  ## Opt-in

  `flt_app.publish_status` defaults to `false`, so an app is unpublished until an
  operator says otherwise through `Samen.Fleet.Registry.set_publish_status/4`
  (admin-gated; see that function). A read of an unreadable namespace is
  `{:error, :unavailable}` — never an empty all-clear page.

  ## Masking

  `slug` is the one string that crosses, and ADR-044 §5.2 already makes it
  cockpit-side/operator-typed only (never read from an enroll request or a
  report). This module does not take that on trust: a slug that is not the bounded
  operator shape `#{inspect(~S"[a-z0-9][a-z0-9-]{0,62}")}` renders `••••` instead.
  A vault token (`vt_`-prefixed, and `_` is outside the shape) therefore renders
  `••••` on both counts, and so does a legal name, an e-mail, or anything with
  whitespace, punctuation or capitals in it.
  """

  alias Samen.Fleet.Registry

  defmodule Entry do
    @moduledoc """
    One published component: a bounded slug and a bounded public status. A closed
    two-field struct — see the parent module on why it is closed.
    """
    @enforce_keys [:slug, :status]
    defstruct [:slug, :status]

    @type t :: %__MODULE__{slug: String.t(), status: atom()}
  end

  @masked "••••"

  # The closed PUBLIC vocabulary (ADR-050 §4.2). `:unknown` is `overall`'s only —
  # it is what an empty page reports, so the page never claims "operational" for a
  # fleet it is publishing nothing about.
  @public_statuses [:operational, :degraded, :down, :maintenance]
  @overall_statuses [:unknown | @public_statuses]

  # Severity ranking for `overall` — highest wins.
  @severity %{operational: 0, maintenance: 1, degraded: 2, down: 3}

  # The bounded operator slug shape (ADR-044 §5.2). Anchored, length-capped,
  # lowercase-and-dash only: no `_` (so every `vt_*` token fails it), no `@`, no
  # whitespace, no capitals.
  @slug_shape ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @type view :: %{entries: [Entry.t()], overall: atom()}

  @doc "The closed public status vocabulary an `Entry` can carry."
  @spec public_statuses() :: [atom()]
  def public_statuses, do: @public_statuses

  @doc "The closed vocabulary `overall` can carry (`public_statuses/0` plus `:unknown`)."
  @spec overall_statuses() :: [atom()]
  def overall_statuses, do: @overall_statuses

  @doc "The mask rendered in place of a slug that is not the bounded operator shape."
  @spec masked() :: String.t()
  def masked, do: @masked

  @doc """
  The public view for a `Samen.Fleet.Scope`-mounted `namespace`: the opted-in,
  non-deregistered apps as `Entry` structs sorted by slug, plus the worst published
  status as `overall`.

  `opts` is passed through to `Samen.Fleet.Registry.read_rows/2` (so a caller may
  supply the internal aggregate actor it already uses); it is NEVER derived from a
  web request — a public request carries no identity and grants none.

  Any failure collapses to `{:error, :unavailable}` with no detail: a public
  surface that cannot read its own substrate says so rather than rendering a page
  that looks healthy (ADR-014/024 fail-honest).
  """
  @spec read(module(), keyword()) :: {:ok, view()} | {:error, :unavailable}
  def read(namespace, opts \\ []) when is_atom(namespace) do
    case Registry.read_rows(namespace, opts) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        entries =
          rows
          |> Enum.filter(&published?/1)
          |> Enum.map(&entry/1)
          |> Enum.sort_by(& &1.slug)

        {:ok, %{entries: entries, overall: overall(entries)}}

      _other ->
        {:error, :unavailable}
    end
  rescue
    # A namespace that is not a mounted `Samen.Fleet.Scope` raises on resource
    # resolution. The public surface must not 500 on that, and must not render an
    # empty page that reads as "all clear" either.
    _ -> {:error, :unavailable}
  end

  @doc """
  The worst public status among `entries`, or `:unknown` when there are none.
  """
  @spec overall([Entry.t()]) :: atom()
  def overall([]), do: :unknown

  def overall(entries) when is_list(entries) do
    entries
    |> Enum.max_by(&Map.fetch!(@severity, &1.status))
    |> Map.fetch!(:status)
  end

  # Opt-in AND still registered. A deregistered app is not "down" — it is gone, so
  # it leaves the page entirely. Anything that is not literally `true` is unpublished
  # (fail closed: a `nil` from a namespace mid-migration publishes nothing).
  defp published?(%{publish_status: true, status: status}), do: status != :deregistered
  defp published?(_row), do: false

  defp entry(%{slug: slug, status: status}) do
    %Entry{slug: public_slug(slug), status: public_status(status)}
  end

  # The lossy internal -> public mapping. The `_other` clause is the fail-closed
  # one: an internal state this module has never heard of is `:down`, never
  # `:operational`.
  defp public_status(:active), do: :operational
  defp public_status(:stale), do: :degraded
  defp public_status(:unreachable), do: :down
  defp public_status(:revoked), do: :maintenance
  defp public_status(_other), do: :down

  defp public_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_shape, slug) and not String.starts_with?(slug, "vt_") do
      slug
    else
      @masked
    end
  end

  defp public_slug(_slug), do: @masked
end
