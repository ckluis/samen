defmodule Samen.Scopes.Tags do
  @moduledoc """
  The **Tags** universal scope (F4; spec §F4, spec-questions c7). Ships as a
  **library-authored blueprint** (ADR-004), same shape as
  `Samen.Scopes.Work`/`Samen.Scopes.Docs`: `use`-ing this module inside a host's Ash
  domain expands into two host-owned resources in the host's namespace, each a normal
  `use Samen.Resource` with the host's `otp_app`, `repo`, and `domain`.

  ## Resources — `tag · tagging`

  - **`Tag`** — an org-scoped, colored label (bounded palette enum, c7 — never free
    hex). Unique `name` per org among LIVE rows. Archivable (ADR-040 §5.9).
  - **`Tagging`** — the polymorphic JOIN attaching a `Tag` to ANY catalogued object via
    the generic `(subject_key, subject_id)` object-ref anchor. `tag_id` is a real
    same-scope `belongs_to` (SameOrgFk-guarded). NOT archivable (a pure join row).

  ## PII map (INV-1)

  Neither resource carries subject PII. `Tag.name`/`.color` are operator-authored
  labels. `Tagging` carries only `tag_id` + the opaque anchor — structurally incapable
  of leaking the tagged object's vault fields (see `Samen.Scopes.Tags.Blueprint`
  moduledoc for the full posture).

  ## Object-ref attachment

  `Tagging.subject_key`/`subject_id` are plain scalars (never a CRM/host FK), mirroring
  `Samen.Scopes.Work.Task`/`Samen.Scopes.Docs.{Doc,Note}` exactly (ADR-041 §4.1).
  Org-scope enforcement rides the samen_web `Samen.Web.ObjectRef.resolve/3` write
  boundary (`Samen.Web.Tags.attach/5`), not a substrate-level FK check — there is no
  CRM/host contact in this scope.

  ## Ticket migration (F4 "migrate the Ticket `tags` array")

  The Support scope's `Ticket.tags` (`{:array, :string}`) is migrated to this generic
  mechanism by a per-host, contract-phase migration
  (`MigrateTicketTagsToTagScope`) — see that migration's moduledoc for the zero-drop
  set-based copy. The Support blueprint no longer declares a `:tags` attribute.

  ## Mounting the Tags scope (the host side)

      defmodule Demo.Tags do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Tags,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.Tags
      end

  This defines, in the host's namespace:

    * `Demo.Tags.Tag`
    * `Demo.Tags.Tagging`

  ## Deliberate naming: `Demo.Tags`, not `Demo.TagsScope`

  Demo's OTHER scope modules use a `Scope` suffix (`Demo.SupportScope`,
  `Demo.DocsScope`, `Demo.CrmScope`, …) as a LOCAL Demo convention. This scope
  deliberately does NOT follow that suffix, so that
  `Samen.Web.ObjectRef.Catalog.key_for/1`'s derive-from-namespace rule (last two
  module segments, lowercased) produces the UNIFORM object-ref key `tags.tag` /
  `tags.tagging` on demo, exactly as it does on driftwood/pawchart/samen_web
  (`Driftwood.Tags.Tag`, `PawChart.Tags.Tag`, `Samen.WebTest.Tags.Tag` — none of those
  hosts suffix their scope modules). This is what lets a HOST-AGNOSTIC framework read
  helper (`Samen.Web.Support.Reads`/`Samen.Web.Operator.Reads`'s ticket-tag join) derive
  the Tagging module via `ObjectRef.Catalog.resource_for(mount, "tags.tagging")`
  identically on every host, including demo, without a per-host branch.

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs). No
  scope-default (mirrors Docs/Calendar's "no pre-claimed default" precedent) — every
  host takes a fresh allocator-proposed abbrev, passed via `abbrevs:`:

    * `Demo.Tags.Tag`                      → `dtt`
    * `Demo.Tags.Tagging`                  → `tdt`
    * `Driftwood.Tags.Tag`                 → `ftt` (demo's proposer-default `dtt`
      collided cross-host — the same "host-name-blind proposer" class T44/T45
      already hit for Calendar/Docs — so driftwood took `ftt`/`tft` instead)
    * `Driftwood.Tags.Tagging`             → `tft`
    * `PawChart.Tags.Tag`                  → `ptt`
    * `PawChart.Tags.Tagging`              → `tpt`
    * `SamenCore.Support.TagsFixture.Tag`      → `stt`
    * `SamenCore.Support.TagsFixture.Tagging`  → `tst`
    * `Samen.WebTest.Tags.Tag`             → `wtt`
    * `Samen.WebTest.Tags.Tagging`         → `twt`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    tag_mod = Module.concat(namespace, Tag)
    tagging_mod = Module.concat(namespace, Tagging)

    quote do
      require Samen.Scopes.Tags.Blueprint

      resources do
        resource(unquote(tag_mod))
        resource(unquote(tagging_mod))
      end

      Samen.Scopes.Tags.Blueprint.define_tag(
        unquote(tag_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.tag)
      )

      Samen.Scopes.Tags.Blueprint.define_tagging(
        unquote(tagging_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.tagging),
        unquote(tag_mod)
      )
    end
  end

  # No scope-default: `abbrevs:` is REQUIRED (mirrors Docs/Calendar — every host
  # takes a fresh allocator-proposed abbrev).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Tags, abbrevs: must be a compile-time map literal " <>
            "(%{tag: \"dtt\", tagging: \"tdt\"}). Got: #{Macro.to_string(other)}"
  end
end
