defmodule Samen.Scopes.Work do
  @moduledoc """
  The **Work** universal scope (F1; ADR-041 §3 — the canonical Work-scope Task,
  BINDING design). Ships as a **library-authored blueprint** (ADR-004), same shape
  as `Samen.Scopes.Support` (the closest structural template): `use`-ing this module
  inside a host's Ash domain expands into two host-owned resources in the host's
  namespace, each a normal `use Samen.Resource` with the host's `otp_app`, `repo`,
  and `domain`.

  ## Resources — `project · task` (self-referential Subtask tree)

  - **`Project`** — a container noun (name, status, owner). No PII.
  - **`Task`** — the canonical Work item (ADR-041 §3.2, field-for-field): `kind`,
    `title`, `body`, `status` (plain enum, NOT a state machine — §4.3), `priority`
    (`Samen.Type.Priority`), `due_at`, `completed_at`, the generic `(subject_key,
    subject_id)` object-ref anchor (CRM-agnostic — never a CRM FK, §4.1), `custom`,
    `owner_id`, `parent_id` (self-referential — the Subtask tree, cycle-refused),
    `project_id`. No PII.

  **This scope is CRM-agnostic by construction and touches NO CRM code** — it is the
  destination T97 migrates the CRM `Activity` resource onto in a separate,
  file-partitioned task (ADR-041 §7). Building/testing/mounting the Work scope never
  requires the CRM to exist.

  ## PII map — EMPTY (INV-1)

  Neither resource carries a vault-routed field. See
  `Samen.Scopes.Work.Blueprint` moduledoc for the full posture and
  `docs/adr/ADR-041-canonical-task-activity-migration.md` §10 for the table.

  | Attribute | Classification | Vault? |
  |---|---|---|
  | `kind`, `status`, `subject_key` | non-PII (bounded atom/key) | no |
  | `priority` | non-PII (`Samen.Type.Priority` `:non_pii` + `TypeClearance`) | no |
  | `due_at`, `completed_at`, timestamps, `id`, `org_id`, `subject_id`, `owner_id`, `parent_id`, `project_id` | non-PII (id/timestamp) | no |
  | `title`, `body`, `custom` | freeform user content — default-deny-CDC-excluded, not vaulted (Activity parity) | no |

  ## Soft-delete (ADR-040 §5.9)

  Both `Project` and `Task` are `archivable: true`. Project archival does NOT cascade
  to its Tasks; Task archival DOES cascade to its Subtask subtree
  (`archive_related([:subtasks])`, ADR-041 §3.5).

  ## Subtask tree — cycle refusal (ADR-041 §3.4)

  `Task.parent_id` is self-referential. Every create/update that changes `parent_id`
  is refused if it would make the task its own (transitive) ancestor
  (`Samen.Scopes.Work.CycleGuard`), depth-bounded.

  ## Mounting the Work scope (the host side)

      defmodule Demo.WorkScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Work,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.WorkScope
      end

  This defines, in the host's namespace:

    * `Demo.WorkScope.Project`
    * `Demo.WorkScope.Task`

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs):

    * `Demo.WorkScope.Project` → `wpj`
    * `Demo.WorkScope.Task`    → `wtk`

  Defaults are provided for the demo mount; other hosts pass `abbrevs:` overrides
  (mirroring `Samen.Scopes.Support`'s `abbrevs:` plumbing) when the defaults are
  already claimed.
  """

  @default_abbrevs %{
    project: "wpj",
    task: "wtk"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string (mirrors Samen.Scopes.Support —
    # the base macro validates abbrevs caller-side and requires a compile-time literal).
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    project_mod = Module.concat(namespace, Project)
    task_mod = Module.concat(namespace, Task)

    quote do
      require Samen.Scopes.Work.Blueprint

      resources do
        resource(unquote(project_mod))
        resource(unquote(task_mod))
      end

      Samen.Scopes.Work.Blueprint.define_project(
        unquote(project_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.project)
      )

      Samen.Scopes.Work.Blueprint.define_task(
        unquote(task_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.task),
        unquote(project_mod)
      )
    end
  end

  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Work, abbrevs: must be a compile-time map literal " <>
            "(%{project: \"wpj\", task: \"wtk\"}). Got: #{Macro.to_string(other)}"
  end
end
