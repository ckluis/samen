defmodule Samen.Scopes.Docs do
  @moduledoc """
  The **Docs** universal scope (F3; spec §F3/§F8). Ships as a **library-authored
  blueprint** (ADR-004), same shape as `Samen.Scopes.Work`/`Samen.Scopes.Calendar`:
  `use`-ing this module inside a host's Ash domain expands into two host-owned
  resources in the host's namespace, each a normal `use Samen.Resource` with the
  host's `otp_app`, `repo`, and `domain`.

  ## Resources — `doc · note`

  - **`Doc`** — a titled rich-text document, attachable to any object via the generic
    `(subject_key, subject_id)` object-ref anchor.
  - **`Note`** — an untitled short annotation, same attachment discipline.

  Both distinct from CMS `Page`/`Post` (no shared table, no publish workflow — see
  `Samen.Scopes.Docs.Blueprint` moduledoc).

  ## PII map (INV-1)

  `body` is plain, write-guarded by `Samen.Pii.FreeTextScan` (refuses a bare
  email/SSN/phone-shaped value). `secure_body` is the vaulted alternative for content the
  caller has classified as carrying subject PII. See
  `Samen.Scopes.Docs.Blueprint` moduledoc for the full posture table.

  ## Object-ref attachment

  `subject_key`/`subject_id` are plain scalars (never a CRM/host FK), mirroring
  `Samen.Scopes.Work.Task` exactly (ADR-041 §4.1). Org-scope enforcement rides the
  samen_web `Samen.Web.ObjectRef.resolve/3` write boundary (`Samen.Web.Docs.attach/5`),
  not a substrate-level FK check — there is no CRM/host contact in this scope.

  ## Soft-delete (ADR-040 §5.9)

  Both `Doc` and `Note` are `archivable: true`.

  ## Mounting the Docs scope (the host side)

      defmodule Demo.DocsScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Docs,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.DocsScope
      end

  This defines, in the host's namespace:

    * `Demo.DocsScope.Doc`
    * `Demo.DocsScope.Note`

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs). Unlike
  Work (which claimed demo-owned defaults `wpj`/`wtk`), Docs has no scope-default —
  every host takes a fresh allocator-proposed abbrev (mirrors Calendar's `event`
  precedent), passed via `abbrevs:`:

    * `Demo.DocsScope.Doc`         → `ddd`
    * `Demo.DocsScope.Note`        → `ddn`
    * `Driftwood.Docs.Doc`         → `ddd` (distinct host namespace, no collision)
    * `Driftwood.Docs.Note`        → `ddn`
    * `PawChart.Docs.Doc`          → `pdd`
    * `PawChart.Docs.Note`         → `pdn`
    * `SamenCore.Support.DocsFixture.Doc`  → `sdd`
    * `SamenCore.Support.DocsFixture.Note` → `sdn`
    * `Samen.WebTest.Docs.Doc`     → `wdd`
    * `Samen.WebTest.Docs.Note`    → `wdn`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    doc_mod = Module.concat(namespace, Doc)
    note_mod = Module.concat(namespace, Note)

    quote do
      require Samen.Scopes.Docs.Blueprint

      resources do
        resource(unquote(doc_mod))
        resource(unquote(note_mod))
      end

      Samen.Scopes.Docs.Blueprint.define_doc(
        unquote(doc_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.doc)
      )

      Samen.Scopes.Docs.Blueprint.define_note(
        unquote(note_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.note)
      )
    end
  end

  # No scope-default: `abbrevs:` is REQUIRED (mirrors Calendar's "no pre-claimed
  # scope-default" precedent — every host takes a fresh allocator-proposed abbrev).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Docs, abbrevs: must be a compile-time map literal " <>
            "(%{doc: \"ddd\", note: \"ddn\"}). Got: #{Macro.to_string(other)}"
  end
end
