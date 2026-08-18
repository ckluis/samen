defmodule SamenCore.Support.Versioning do
  @moduledoc """
  Kernel test-fixture domain for the E7 audit-on-write substrate (ADR-040 §6, T119).

  Two pilots prove the `versioned` convention and its two modes, both folding
  `Core.Person` so they carry vault-routed (🔒) fields — the INV-1 risk surface:

    * `Contact` — `versioned: true` (**`:changes_only`**, the default mode). Proves the
      change-log basics (a create/update writes a `Contact.Version` row; a non-opted
      resource writes none — control), and the §6.3(1) INV-1 red-path: a `:changes_only`
      diff of a vault attribute stores the `vt_*` token, never the plaintext sentinel,
      while a plain (non-PII) attribute stores its cleartext value.

    * `Snapshot` — `versioned: :snapshot`, mirroring the CMS content tracking mode (§6.5).
      Proves the DECISIVE INV-1 red-path: a **`:snapshot`** version row reconstructs the
      FULL prior row (every attribute, not just changed ones), so it is the mode most able
      to leak — yet the vault attribute still snapshots as the `vt_*` token only, on the
      same `Ash.Type.dump_to_embedded/2` construction guarantee §6.3(1) gives
      `:changes_only`. (Archive-as-version, §6.4, is proven on the CMS demo host, whose
      content resources are archivable+versioned+non-vault — no vault×archive load path.)

  The domain is deliberately NOT in `:ash_domains` (config/test.exs) — like every other
  kernel fixture — so the CI catalog/vault-parity sweeps do not discover it. The version
  resource's catalog registration + `no_plaintext_pii` governance (§6.2) is proven on the
  real CMS demo host (which IS swept); here we prove the mechanism, the row shapes, and
  INV-1 by direct DB read.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.Versioning.Contact)
    # The generated <Resource>.Version resources are real domain members and must be
    # registered (ash_paper_trail's `:paper_trail_versions` relationship references them).
    resource(SamenCore.Support.Versioning.Contact.Version)
    resource(SamenCore.Support.Versioning.Snapshot)
    resource(SamenCore.Support.Versioning.Snapshot.Version)
  end
end

defmodule SamenCore.Support.Versioning.Contact do
  @moduledoc """
  `:changes_only` versioned pilot (folds `Core.Person`). A create/update records a
  `Contact.Version` row whose `changes` map holds the token for the vault field and the
  cleartext for the plain `label` field (INV-1 §6.3(1)).
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Versioning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "svc",
    base: Core.Person,
    versioned: true

  postgres do
    table("svc_contact")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end

defmodule SamenCore.Support.Versioning.Snapshot do
  @moduledoc """
  `:snapshot` + `archivable` versioned pilot (folds `Core.Person`), mirroring the CMS
  content shape (§6.5). Every version row is a full prior-row reconstruction — the mode
  most able to leak — proving the vault attribute still snapshots as a `vt_*` token only.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: SamenCore.Support.Versioning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "svs",
    base: Core.Person,
    versioned: :snapshot

  postgres do
    table("svs_snapshot")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:label, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
