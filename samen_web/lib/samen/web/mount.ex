defmodule Samen.Web.Mount do
  @moduledoc """
  The host-parameterization struct for a mounted `samen_web` module (ADR-009 §3 — the
  load-bearing decision).

  A framework LiveView must render a HOST's materialized scope resources without ever
  hardcoding a host module name (else, moved verbatim, `Samen.Web.CRM.ContactsLive` would
  render *Driftwood's* resources inside *PawChart*). This struct is the parameterization
  seam: it carries the three irreducibly-host facts (`namespace`, `repo`, `domain`) + the
  plane, and DERIVES each resource module by the ADR-004 naming convention
  (`Module.concat(namespace, Resource)`). A LiveView reads resources ONLY through
  `resource/2` — it never names a host module.

  ## Why deriving from `namespace` is enough (the key realization)

  ADR-004's blueprint materializes a scope's resources at exactly
  `Module.concat(namespace, Name)` (`samen_core/lib/samen/scopes/crm.ex`:
  `company_mod = Module.concat(namespace, Company)`). The convention IS the contract: given
  `namespace: Driftwood.Crm`, `resource(mount, Person)` derives `Driftwood.Crm.Person`;
  given `namespace: PawChart.Billing`, `resource(mount, Customer)` derives
  `PawChart.Billing.Customer`. The host supplies three facts; the struct derives the rest.

  ## Session transport (safe to sign into a cookie)

  `to_session/1` serializes only atoms/strings (module atoms, plane, label strings) — no
  PII, no live struct — so the mount travels in the signed `live_session` session and is
  present on BOTH the initial dead render and the websocket reconnect. `from_session/1`
  rebuilds it (module atoms are safe — they are compiled host modules, not user input).
  This mirrors `Samen.Scope`'s "bounded, safe to log" posture.
  """
  @enforce_keys [:scope_kind, :namespace, :repo, :domain, :plane]
  defstruct [
    :scope_kind,
    :namespace,
    :repo,
    :domain,
    :plane,
    :labels
  ]

  @type t :: %__MODULE__{
          scope_kind:
            :crm
            | :billing
            | :support
            | :marketing
            | :aggregate
            | :operator
            | :chat
            | :notifications
            | :flags
            | :files
            | :csv
            | :search
            | :settings
            | :auth
            | :automation,
          namespace: module(),
          repo: module(),
          domain: module(),
          plane: Samen.Web.Plane.t(),
          labels: map() | nil
        }

  @doc """
  Build a mount. `opts` accepts `:domain` (default `namespace`), `:plane`
  (default `%Samen.Web.Plane{kind: :tenant}`), and `:labels` (optional UI copy overrides).
  """
  def new(scope_kind, namespace, repo, opts \\ []) do
    %__MODULE__{
      scope_kind: scope_kind,
      namespace: namespace,
      repo: repo,
      domain: Keyword.get(opts, :domain, namespace),
      plane: Keyword.get(opts, :plane, Samen.Web.Plane.tenant()),
      labels: Keyword.get(opts, :labels)
    }
  end

  @doc "Derive a resource module by the ADR-004 `Module.concat(namespace, name)` convention."
  @spec resource(t(), atom()) :: module()
  def resource(%__MODULE__{namespace: ns}, name), do: Module.concat(ns, name)

  @doc "The `%Samen.Scope{}` for reading this mount's resources, on this mount's plane."
  def scope(%__MODULE__{plane: plane}, org_id), do: Samen.Web.Plane.scope(plane, org_id)

  @doc "Get a UI label with a neutral default (`labels` is optional per-host branding)."
  def label(%__MODULE__{labels: nil}, _key, default), do: default
  def label(%__MODULE__{labels: labels}, key, default), do: Map.get(labels, key, default)

  @doc """
  Serialize to a session-safe map. Module atoms are stored as strings and rebuilt with
  `String.to_existing_atom/1` (the host modules are compiled, so they always exist).
  """
  def to_session(%__MODULE__{} = m) do
    %{
      "scope_kind" => Atom.to_string(m.scope_kind),
      "namespace" => Atom.to_string(m.namespace),
      "repo" => Atom.to_string(m.repo),
      "domain" => Atom.to_string(m.domain),
      "plane" => Samen.Web.Plane.to_session(m.plane),
      "labels" => stringify_labels(m.labels)
    }
  end

  @doc "Rebuild a mount from its session map."
  def from_session(%{} = raw) do
    %__MODULE__{
      scope_kind: scope_kind(raw["scope_kind"]),
      namespace: mod(raw["namespace"]),
      repo: mod(raw["repo"]),
      domain: mod(raw["domain"]),
      plane: Samen.Web.Plane.from_session(raw["plane"] || %{}),
      labels: atomize_labels(raw["labels"])
    }
  end

  # `scope_kind` is a BOUNDED, framework-owned enum — map it explicitly rather than via
  # `to_existing_atom`. This is robust in ANY deserializing process: a host LiveView mount
  # runs `from_session` in a fresh process where the `:crm`/`:billing`/... atom may not be
  # resident yet (a compiled literal is not guaranteed loaded per-process), so
  # `binary_to_existing_atom("crm")` can raise. The explicit map cannot fail and keeps the
  # value inside the declared set.
  defp scope_kind("crm"), do: :crm
  defp scope_kind("billing"), do: :billing
  defp scope_kind("support"), do: :support
  # F1 / ADR-041 §3 (T43) — the Work scope (Project + the canonical Task).
  defp scope_kind("work"), do: :work
  defp scope_kind("marketing"), do: :marketing
  defp scope_kind("aggregate"), do: :aggregate
  defp scope_kind("operator"), do: :operator
  defp scope_kind("chat"), do: :chat
  defp scope_kind("notifications"), do: :notifications
  defp scope_kind("flags"), do: :flags
  defp scope_kind("files"), do: :files
  defp scope_kind("csv"), do: :csv
  defp scope_kind("search"), do: :search
  defp scope_kind("settings"), do: :settings
  # ADR-035 — the pre-actor identity-spine surfaces (signup/login/verify/reset/…,
  # §6 "pre-actor public" plane row). No org actor exists yet at this scope.
  defp scope_kind("auth"), do: :auth
  # T118 (ADR-039 §12 done-criterion 4 UI half) — the tenant-plane automation
  # (workflow) builder mount.
  defp scope_kind("automation"), do: :automation
  defp scope_kind(k) when is_atom(k), do: k

  # Module atoms serialize as "Elixir.Driftwood.Crm". Host modules are COMPILED, so their
  # atoms always exist in the table — `to_existing_atom` is the right safety here (it
  # rejects an unknown module string rather than minting an atom from cookie input).
  defp mod(str) when is_binary(str), do: String.to_existing_atom(str)
  defp mod(atom) when is_atom(atom), do: atom

  defp stringify_labels(nil), do: nil

  defp stringify_labels(labels) when is_map(labels),
    do: Map.new(labels, fn {k, v} -> {to_string(k), v} end)

  defp atomize_labels(nil), do: nil

  defp atomize_labels(labels) when is_map(labels),
    do: Map.new(labels, fn {k, v} -> {safe_label_key(k), v} end)

  # The BOUNDED, framework-owned set of mount label keys. Materialized as compile-time
  # atom literals HERE so they ALWAYS exist in the atom table in ANY deserializing
  # process — independent of which LiveView happens to have loaded first.
  #
  # WHY THIS EXISTS (the cold-start bug): `from_session/1` runs in a fresh host LiveView
  # `mount/3` process. `String.to_existing_atom("crm_namespace")` on a deserialized label
  # key raised on a COLD BEAM, because `:crm_namespace` was only minted as a literal inside
  # `LeadsLive` — so `/marketing/campaigns` 500'd until someone hit `/marketing/leads`
  # first (load-order dependence). Referencing every framework label key as a literal in
  # this always-loaded module removes the order dependence: the atoms are guaranteed
  # resident before any `from_session` runs.
  #
  # This is a whitelist, NOT a `to_string`/mint: an unknown key (never a framework label,
  # so cookie-injected garbage) still falls through to `String.to_existing_atom/1`, which
  # rejects a never-compiled string rather than minting an atom from session input.
  @label_keys ~w(
    crm_namespace crm_path crm_logo_style
    billing_logo_style support_path support_logo_style
    marketing_path
    crumb_root title glyph
    operator_org_id operator_title operator_workspace operator_glyph
    operator_initials operator_logo_style operator_role operator_user
    operator_authority
    aggregate_loader otp_app status
    user_name user_role user_initials
    chat_path pubsub presence object_cards
    default_org_id org_directory tenant_landing impersonate_path seed_command
    recipient_id
    flags_namespace flags_path revenue_plan_loader
    automation_path
    current_user_id current_membership_id
    authn authorized_orgs
    login_path spine_sessions
    settings_path plan_labels
  )a

  @label_key_strings Map.new(@label_keys, fn k -> {Atom.to_string(k), k} end)

  @doc false
  def label_keys, do: @label_keys

  # Label keys are a bounded, framework-owned set — resolve via the whitelist so the atoms
  # always exist regardless of load order; fall back to `to_existing_atom` for anything
  # outside the set (rejects unknown cookie input rather than minting).
  defp safe_label_key(k) when is_atom(k), do: k

  defp safe_label_key(k) when is_binary(k) do
    case @label_key_strings do
      %{^k => atom} -> atom
      _ -> String.to_existing_atom(k)
    end
  end
end
