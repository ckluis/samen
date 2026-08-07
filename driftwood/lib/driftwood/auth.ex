defmodule Driftwood.Auth do
  @moduledoc """
  Driftwood's BYO-auth REFERENCE credential store (F2 / ADR-031).

  Auth is host-owned (ADR-029). This module is the driftwood-local proof that a real,
  fail-closed login CAN sit under the framework session seam (`Samen.Web.Auth` +
  `Samen.Web.CurrentOrg`) — it is NOT what samen ships. A production deploy replaces it with
  `phx.gen.auth` or an external IdP (see `docs/adr/031-*` and `docs/launch-checklist.md`); the
  session seam and the `CurrentOrg` actor gate stay exactly the same underneath.

  ## What it does

  Verifies an email + password against a salted PBKDF2-SHA256 (`:crypto`, no new dep) credential
  record and returns the authenticated user id plus the org ids that user is provisioned for.
  The `authorized_org_ids/1` function is the membership seam `CurrentOrg` calls to constrain the
  tenant actor to the user's own orgs.

  ## No baked backdoor (public-repo hygiene)

  The credential store is EMPTY by default — `config :driftwood, :auth_credentials` is `%{}`
  unless an operator provisions it. This repo commits no working password/hash. Tests inject a
  freshly-hashed credential at runtime; the launch checklist documents provisioning for real.

  Credential record shape (keyed by lowercased email):

      %{"a@ex.test" => %{user_id: "<uuid>", org_ids: ["<tenant_org_id>", …],
                         salt: "<b64>", pbkdf2: "<b64 of hash(password, salt)>"}}
  """

  @iterations 120_000
  @derived_len 32

  @doc "The configured credential store (empty by default — no committed backdoor)."
  @spec credentials() :: map()
  def credentials, do: Application.get_env(:driftwood, :auth_credentials, %{})

  @doc "PBKDF2-SHA256 (Base64) of `password` under `salt`. The digest stored in a credential record."
  @spec hash(String.t(), String.t()) :: String.t()
  def hash(password, salt) when is_binary(password) and is_binary(salt) do
    :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, @derived_len) |> Base.encode64()
  end

  @doc """
  Verify `email` + `password`. Returns `{:ok, user_id, org_ids}` on a constant-time digest match,
  else `:error`. An unknown email still runs a decoy hash (timing-equalized) before failing.
  """
  @spec verify(String.t(), String.t()) :: {:ok, String.t(), [String.t()]} | :error
  def verify(email, password) when is_binary(email) and is_binary(password) do
    case Map.get(credentials(), String.downcase(String.trim(email))) do
      %{salt: salt, pbkdf2: expected, user_id: user_id} = rec
      when is_binary(salt) and is_binary(expected) and is_binary(user_id) ->
        if Plug.Crypto.secure_compare(hash(password, salt), expected) do
          {:ok, user_id, org_ids(rec)}
        else
          :error
        end

      _ ->
        # Timing-equalize: hash even when the email is unknown, then fail.
        _ = hash(password, "driftwood-decoy-salt")
        :error
    end
  end

  def verify(_, _), do: :error

  @doc """
  The tenant org ids the authenticated `user_id` may act on — the `:authorized_orgs` membership
  seam `Samen.Web.CurrentOrg` calls. Sourced from the credential store here; a production deploy
  swaps this for real `Identity.Membership` rows. Unknown user → `[]` (deny).
  """
  @spec authorized_org_ids(String.t()) :: [String.t()]
  def authorized_org_ids(user_id) when is_binary(user_id) do
    credentials()
    |> Enum.find_value([], fn {_email, rec} ->
      if Map.get(rec, :user_id) == user_id, do: org_ids(rec), else: nil
    end)
  end

  def authorized_org_ids(_), do: []

  @operator_roles [:operator_admin, :operator_support, :operator_readonly, :operator_break_glass]

  @doc """
  T146 + J3 — the PER-PRODUCT operator-ROLE authority seam (`Samen.Web.Operator.Authz` /
  `Samen.Web.AuthGate`), scoped by `app_scope` (ADR-044 §6.2 / §6.3a #4).

  Returns the operator role `principal_id` holds ON `app_scope`, or `nil` (NOT an operator on
  that product — fail CLOSED). Wired on every operator mount + the conn-level app-env twin as
  `operator_authority: {Driftwood.Auth, :operator_role, [:driftwood]}` — the `[:driftwood]` args
  list is the PRODUCT-SCOPE carrier `Samen.Web.Operator.Authz.resolve_role/2` appends the principal
  id to. Resolution:

    0. **Per-product isolation (RP-J-5).** This host owns exactly the `:driftwood` product. A role
       granted here confers scope ONLY on `:driftwood`; `operator_role(:other, _)` is `nil` — a
       role in A grants NOTHING in B, including the dev grant below. Without this guard a co-resident
       fleet would grant a cross-product role BY OMISSION (the §6.3a #4 landmine).
    1. the configured operator ROSTER (`config :driftwood, :operator_roster, %{user_id => role}`)
       — a production deploy provisions this (or swaps this for real operator `Membership` rows),
       exactly as `authorized_org_ids/1` maps to tenant membership;
    2. else, ONLY while `:auth_required?` is false (dev/test) AND `app_scope == :driftwood`, a dev
       convenience grant of `:operator_admin` so the local dogfood operator console works without a
       login. The instant the app is armed for prod (`config :driftwood, auth_required?: true`) this
       dev grant is gone and a principal absent from the roster is refused — the T146 exploit stays
       CLOSED.
  """
  @spec operator_role(atom(), String.t() | nil) :: atom() | nil
  def operator_role(app_scope, principal_id) when is_atom(app_scope) do
    # (0) Per-product isolation: driftwood is the authority for :driftwood ONLY.
    if app_scope != :driftwood do
      nil
    else
      roster = Application.get_env(:driftwood, :operator_roster, %{})

      case is_binary(principal_id) && Map.get(roster, principal_id) do
        role when role in @operator_roles ->
          role

        _ ->
          # Dev/test convenience ONLY (unmistakably gated on the prod-arming flag being off).
          if Application.get_env(:driftwood, :auth_required?, false), do: nil, else: :operator_admin
      end
    end
  end

  def operator_role(_app_scope, _principal_id), do: nil

  @doc """
  J3 — the FLEET-WIDE role read (`Samen.Fleet.Authz` `:fleet_authority` seam, ADR-044 §6.2).

  Returns `%{scope => operator_role}` — the products (and the reserved `:fleet` cockpit scope)
  `principal_id` reaches. Wired as `config :driftwood, :fleet_authority, {Driftwood.Auth,
  :fleet_roles, []}` (principal id appended). Reference co-resident host: an operator with a
  `:driftwood` role sees the driftwood scope; the `:fleet` cockpit scope is granted from a
  dedicated `:fleet_operators` roster (default empty ⇒ fail-CLOSED, no cockpit). Fail-closed
  `%{}` for a non-operator. T84 refines cockpit tile logic; T83 ships the seam.
  """
  @spec fleet_roles(String.t() | nil) :: %{atom() => atom()}
  def fleet_roles(principal_id) do
    drift =
      case operator_role(:driftwood, principal_id) do
        role when role in @operator_roles -> %{driftwood: role}
        _ -> %{}
      end

    fleet =
      case is_binary(principal_id) &&
             Map.get(Application.get_env(:driftwood, :fleet_operators, %{}), principal_id) do
        role when role in @operator_roles -> %{fleet: role}
        _ -> %{}
      end

    Map.merge(drift, fleet)
  end

  defp org_ids(rec) do
    case Map.get(rec, :org_ids, []) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end
end
