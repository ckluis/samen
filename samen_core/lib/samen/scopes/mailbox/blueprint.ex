defmodule Samen.Scopes.Mailbox.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Mailbox** scope (spec §I1, T74; ADR-004
  blueprint) — the persistence half of the CRM two-way email sync seam.

  Objects: `connection🔒 · mail_message🔒`.

  ## PII map (🔒)

  | Resource      | Field                 | Vault       | Column                          |
  |---------------|-----------------------|-------------|---------------------------------|
  | connection    | address               | `:pii_email`| scalar: `pii_<abbrev>_address`  |
  | mail_message  | counterparty_address  | `:pii_email`| scalar: `pii_<abbrev>_counterparty_address` |
  | mail_message  | subject               | `:pii_body` | scalar: `pii_<abbrev>_subject`  |
  | mail_message  | body                  | `:pii_body` | scalar: `pii_<abbrev>_body`     |

  Every free-text or address-bearing column on this scope is vault-routed — there
  is deliberately NO plaintext address, subject, or body column anywhere (INV-1).
  A subject line is treated as PII for the same reason `Support.Message.body` is:
  real mail subjects carry names, order numbers, and medical/financial context.

  ## The CRM anchor (CRM-agnostic, no FK)

  `mail_message` carries the SAME generic `(subject_key, subject_id)` object-ref
  anchor `Samen.Scopes.Work.Task` uses (ADR-041 §6.1) — `"crm.person"` or
  `"crm.company"` — plus a secondary `company_id`, so a message matched to a person
  ALSO appears on that person's company timeline (zero timeline loss). No FK into
  the CRM scope: the Mailbox scope mounts independently of it, and a host that has
  not mounted CRM still gets a working mailbox.

  ## Not archivable

  Neither resource declares `archivable: true`. A synced mailbox record is a
  reflection of an external system, not tenant-authored content with a trash
  affordance; the erasure story for it is crypto-shred of the subject's vault rows
  (ADR-001), not soft delete.
  """

  # ---------------------------------------------------------------------------
  # Connection — 🔒 PII: address (vault :pii_email). Per-user, org-scoped.
  # ---------------------------------------------------------------------------
  defmacro define_connection(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Mailbox.Connection — ONE user's connected mailbox 🔒 (spec §I1).

        `address` is vault-routed PII (`:pii_email`): the mailbox owner's own email
        address, masked by default, plaintext only via the declared reveal action
        under a grant. `external_account_id` and `cursor` are the PROVIDER's opaque
        handles — bounded identifiers, not PII, and never interpreted by core.

        `status` is the honest connection state. It is set from what the provider
        actually did: a row is `:connected` only after a real handshake returned an
        account. There is no "assume connected" path.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_connection")
          repo(unquote(repo))
        end

        attributes do
          # The owning user (per-user mailbox connect). Opaque uuid, not PII.
          attribute(:user_id, :uuid, public?: true, allow_nil?: false)

          # Which adapter minted this connection (an underscored module label, e.g.
          # "fake_provider" / "imap"). Bounded label, host-authored, never user input.
          attribute(:provider, :string, public?: true, allow_nil?: false)

          # The provider's opaque handle for the connected mailbox.
          attribute(:external_account_id, :string, public?: true)

          # The provider's opaque sync position (IMAP UIDNEXT, Gmail historyId,
          # Graph deltaLink). Bounded, opaque, never interpreted here.
          attribute(:cursor, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :disconnected,
            constraints: [one_of: [:connected, :disconnected, :error]]
          )

          attribute(:connected_at, :utc_datetime, public?: true)
          attribute(:last_synced_at, :utc_datetime, public?: true)

          # Bounded diagnostic for the :error state (adapter-authored reason atom as
          # a label). Never a vendor payload, never PII.
          attribute(:last_error, :atom,
            public?: true,
            constraints: [one_of: [:not_configured, :not_implemented, :auth_failed, :unreachable]]
          )
        end

        pii do
          vault(:pii_email)
          # Scalar PII: the mailbox owner's address. Column: pii_<abbrev>_address.
          pii_attribute(:address, :string, vault: :pii_email)
          reveal(:reveal_connection)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_connection, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_connection,
                label: :address
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:reveal_connection) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # MailMessage — 🔒 PII: subject/body (:pii_body) + counterparty_address
  # (:pii_email). Org-scoped, anchored to the CRM via the generic object-ref.
  # ---------------------------------------------------------------------------
  defmacro define_mail_message(module, otp_app, domain, repo, abbrev, connection_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Mailbox.MailMessage — ONE synced or sent email 🔒 (spec §I1).

        `subject`, `body` (vault `:pii_body`) and `counterparty_address` (vault
        `:pii_email`) are vault-routed: masked by default, plaintext only through
        `Samen.Api.PiiResolution` on a plane that may read them. There is NO
        plaintext content column on this table.

        `direction` records BOTH legs of the two-way sync: `:inbound` (mail that
        arrived in the connected mailbox) and `:outbound` (mail sent AS the mailbox,
        whether composed here or picked up from the provider's Sent folder).

        The CRM anchor is the generic `(subject_key, subject_id)` object-ref
        (`"crm.person"` / `"crm.company"`) plus a secondary `company_id` — no FK
        into the CRM scope.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_mail_message")
          repo(unquote(repo))
        end

        attributes do
          attribute(:direction, :atom,
            public?: true,
            allow_nil?: false,
            default: :inbound,
            constraints: [one_of: [:inbound, :outbound]]
          )

          # The provider's own immutable message id — the idempotency/dedupe key.
          # Bounded identifier, not PII.
          attribute(:external_id, :string, public?: true)

          # SHA-256 of the provider thread id / RFC-5322 reference — non-reversible,
          # so a Message-ID embedding an address cannot land in a plain column.
          attribute(:thread_key, :string, public?: true)

          attribute(:occurred_at, :utc_datetime, public?: true)

          # The generic CRM-agnostic object-ref anchor (ADR-041 §6.1 shape).
          attribute(:subject_key, :string, public?: true)
          attribute(:subject_id, :uuid, public?: true)

          # Secondary anchor: a person-anchored message also shows on the company
          # timeline. Plain uuid, no FK (the Mailbox scope mounts independently).
          attribute(:company_id, :uuid, public?: true)
        end

        pii do
          vault(:pii_body)
          vault(:pii_email)
          # Scalar PII, pii_ column prefix: pii_<abbrev>_subject / _body / _counterparty_address.
          pii_attribute(:subject, :string, vault: :pii_body)
          pii_attribute(:body, :string, vault: :pii_body)
          pii_attribute(:counterparty_address, :string, vault: :pii_email)
          reveal(:reveal_mail_message)
        end

        relationships do
          belongs_to :connection, unquote(connection_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_mail_message, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_mail_message,
                label: :body
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:reveal_mail_message) do
            authorize_if(always())
          end
        end
      end
    end
  end
end
