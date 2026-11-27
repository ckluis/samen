defmodule Samen.HonestKernelReadsETest do
  @moduledoc """
  Honest reads, kernel phase E. The masking core (`Samen.Api.PiiResolution`) fails CLOSED when a read under it fails:
  the value stays masked / the bag stays masked, and that is unchanged. What was wrong is that it did so silently, so an
  outage that masked a whole page was indistinguishable from a deliberate mask. Each failure is now reported ONCE per
  call, by name, value-free (no plaintext, no `vt_` token). Each RED case injects a real failure and pairs with a
  positive control through the same seam.
  """
  import Samen.VaultTokenAssert
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.Api.PiiResolution
  alias Samen.CustomFields
  alias Samen.Masked
  alias Samen.Tracer
  alias Samen.Vault
  alias SamenCore.Support.CrmScopeFixture.Person
  alias Samen.FeatureFlags
  alias Samen.FeatureFlags.{Cache, Decision}
  alias SamenCore.Support.CustomFields.Widget
  alias SamenCore.Support.{UnreadableFlag, UnreadableSearchIndex}
  alias SamenCore.Support.NotificationFixture.SearchIndex
  alias SamenCore.TestRepo, as: Repo

  setup do
    Samen.TestSandbox.shared!(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)

    test_pid = self()
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:samen, :core, :read, :error], fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  defmodule AllowAll do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, fn _ -> true end)
    def granted?(_), do: true
  end

  defmodule DenyAll do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, fn _ -> false end)
    def granted?(_), do: false
  end

  # What a real driver / Ash error looks like to a reporter: its message interpolates the very values it was
  # processing (a plaintext, a vault token). A report that logged `Exception.message/1` or `inspect/1` of it would leak.
  @leak "Secret-7731"
  @leak_token "vt_leak7731abcdef"

  defmodule LeakyError do
    @moduledoc false
    defexception [:message]
  end

  # A vault whose reveal FAILS with an error that carries a plaintext marker and a token.
  defmodule LeakyVault do
    @moduledoc false
    def reveal(_masked, _repo, _opts),
      do: {:error, %Samen.HonestKernelReadsETest.LeakyError{message: "reveal refused for #{"Secret-7731"} token=#{"vt_leak7731abcdef"}"}}
  end

  # The vault-row prefetch (`repo.all`) fails with a database error whose message carries the bound tokens and a
  # value (as a Postgrex error with its parameters does); a single-row read still works.
  defmodule PrefetchDownRepo do
    @moduledoc false
    def message(tokens), do: "connection not available params=#{Enum.join(tokens, ",")} tier=#{"Secret-7731"}"
    def all(_query), do: raise(DBConnection.ConnectionError, message(Process.get(:leak_tokens, [])))
    def get(schema, id), do: SamenCore.TestRepo.get(schema, id)
  end

  # The custom-field catalog read (`repo.all`) fails with a database error.
  # Stand-ins for :otel_tracer whose plumbing fails: before the body starts, and after it finished.
  defmodule SetupFailingOtel do
    @moduledoc false
    def with_span(_tracer, _name, _attrs, _fun), do: raise(RuntimeError, "span setup refused for cohort tier=Secret-7731")
  end

  defmodule FinishFailingOtel do
    @moduledoc false
    def with_span(_tracer, _name, _attrs, fun) do
      fun.(:ctx)
      raise RuntimeError, "span export refused"
    end
  end

  # Tracing plumbing whose span cleanup raises as well as the body.
  defmodule CleanupFailingOtel do
    @moduledoc false
    def with_span(_tracer, _name, _attrs, fun) do
      fun.(:ctx)
    after
      raise RuntimeError, "span cleanup refused"
    end
  end

  # The catalog read fails with a database error whose message carries an org-shaped value, a key and a token.
  defmodule CatalogDownRepo do
    @moduledoc false
    def message, do: "connection not available org=#{"alice@example.com"} key=care_note token=#{"vt_leak7731abcdef"} tier=gold"
    def all(_query), do: raise(DBConnection.ConnectionError, message())
  end

  # --- fixtures ------------------------------------------------------------------------------------------

  defp owner!(tag) do
    id = Ash.UUID.generate()

    vals =
      for {name, vault} <- [full_name: :pii_name, emails: :pii_email, phones: :pii_phone], into: %{} do
        plain = "#{tag}-#{name}-SECRET"
        {:ok, token} = Vault.store_field(id, vault, name, plain, Repo)
        {name, {token, plain}}
      end

    %{id: id, vals: vals}
  end

  defp record(owner),
    do: struct(Person, Map.merge(%{id: owner.id}, Map.new(owner.vals, fn {n, {t, _}} -> {n, Masked.new(t, n)} end)))

  defp page, do: Enum.map(1..3, fn i -> owner!("row#{i}") end)

  defp count(log, name), do: length(Regex.scan(~r/(read|write) failed (read|write)=#{name} /, log))

  defp drain_failures(name, acc \\ []) do
    receive do
      {:failure, %{read: ^name} = meta} -> drain_failures(name, [meta | acc])
      {:failure, _other} -> drain_failures(name, acc)
    after
      50 -> Enum.reverse(acc)
    end
  end

  # --- PiiResolution: a failed reveal ----------------------------------------------------------------------

  describe "PiiResolution.resolve — a reveal that FAILED is reported once per call, and stays masked" do
    test "RED: a KMS outage masks the whole page on the tenant plane; ONE report by name, no value, no token" do
      owners = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      Samen.Kms.FileBacked.simulate_outage(true)

      log =
        capture_log(fn ->
          out = PiiResolution.resolve(Enum.map(owners, &record/1), Person, actor, repo: Repo)
          # fail closed, exactly as before: every value of every row is masked
          assert Enum.all?(out, fn r -> Enum.all?([:full_name, :emails, :phones], &match?(%Masked{}, Map.get(r, &1))) end)
        end)

      # 3 rows x 3 fields fail; ONE log line and ONE event
      assert count(log, "pii_resolution_reveal") == 1
      assert log =~ "cause=unavailable"
      # the org is named (the actor is known at the reveal site)
      assert log =~ "org=#{actor.org_id}"
      assert [%{cause: "unavailable"}] = drain_failures(:pii_resolution_reveal)

      refute log =~ "SECRET"
      refute_vault_token(log)
    end

    test "RED: a reveal that fails with an error CARRYING a value and a token is reported by module name only (never message, value or token)" do
      [o | _] = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      msg = Exception.message(elem(LeakyVault.reveal(nil, nil, []), 1))
      # the injected failure really carries what a leak would show
      assert msg =~ @leak and msg =~ @leak_token

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([record(o)], Person, actor, repo: Repo, vault: LeakyVault)
          assert %Masked{} = out.full_name
        end)

      assert count(log, "pii_resolution_reveal") == 1
      assert log =~ "cause=Samen.HonestKernelReadsETest.LeakyError"
      assert log =~ "org=#{actor.org_id}"
      refute log =~ @leak
      refute log =~ @leak_token
      refute log =~ msg
      assert [%{cause: "Samen.HonestKernelReadsETest.LeakyError"} = meta] = drain_failures(:pii_resolution_reveal)
      refute inspect(meta) =~ @leak
    end

    test "RED: the same outage on an operator WITH a grant still omits the field (fail closed unchanged), reported once" do
      [o | _] = page()
      Samen.Kms.FileBacked.simulate_outage(true)

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([record(o)], Person, %{plane: :operator, org_id: Ash.UUID.generate()}, repo: Repo, grant: AllowAll)
          assert %Ash.ForbiddenField{} = out.full_name
        end)

      assert count(log, "pii_resolution_reveal") == 1
      refute log =~ "SECRET"
    end

    test "POSITIVE CONTROL: with the KMS up the same page is clear and nothing is reported" do
      owners = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}

      log =
        capture_log(fn ->
          out = PiiResolution.resolve(Enum.map(owners, &record/1), Person, actor, repo: Repo)
          assert Enum.zip(owners, out) |> Enum.all?(fn {o, r} -> r.full_name == elem(o.vals.full_name, 1) end)
        end)

      refute log =~ "pii_resolution_reveal"
      assert drain_failures(:pii_resolution_reveal) == []
    end

    test "a SHREDDED subject is a fact about the data, not a failure: masked and not reported (control for the denial arm)" do
      [o | _] = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      assert {:ok, _} = Vault.shred(o.id)

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([record(o)], Person, actor, repo: Repo)
          assert %Masked{} = out.full_name
        end)

      refute log =~ "pii_resolution_reveal"
      assert drain_failures(:pii_resolution_reveal) == []
    end
  end

  describe "PiiResolution.resolve — every denial that is a FACT ABOUT THE DATA stays masked and SILENT" do
    defp resolve_quiet(rec) do
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      log = capture_log(fn -> send(self(), {:out, PiiResolution.resolve([rec], Person, actor, repo: Repo)}) end)
      assert_received {:out, [out]}
      {out, log}
    end

    defp assert_silent(log) do
      refute log =~ "pii_resolution_reveal"
      assert drain_failures(:pii_resolution_reveal) == []
    end

    test "a token with NO vault row (:not_found) is masked and not reported" do
      [o | _] = page()
      rec = struct(Person, %{id: o.id, full_name: Masked.new("vt_no_such_row_7731", :full_name)})
      assert {:error, :not_found} = Vault.reveal(rec.full_name, Repo, subject_id: o.id, field: {:pii_name, :full_name})

      {out, log} = resolve_quiet(rec)
      assert %Masked{} = out.full_name
      assert_silent(log)
    end

    test "another SUBJECT's token (:subject_mismatch) is masked and not reported" do
      [o | _] = page()
      rec = struct(Person, %{id: Ash.UUID.generate(), full_name: Masked.new(elem(o.vals.full_name, 0), :full_name)})
      assert {:error, :subject_mismatch} = Vault.reveal(rec.full_name, Repo, subject_id: rec.id, field: {:pii_name, :full_name})

      {out, log} = resolve_quiet(rec)
      assert %Masked{} = out.full_name
      assert_silent(log)
    end

    test "another FIELD's token (:field_mismatch) is masked and not reported" do
      [o | _] = page()
      rec = struct(Person, %{id: o.id, full_name: Masked.new(elem(o.vals.emails, 0), :full_name)})
      assert {:error, :field_mismatch} = Vault.reveal(rec.full_name, Repo, subject_id: o.id, field: {:pii_name, :full_name})

      {out, log} = resolve_quiet(rec)
      assert %Masked{} = out.full_name
      assert_silent(log)
    end

    test "POSITIVE CONTROL: the same tenant resolution with the KMS down DOES report (the silence above is the denial, not a dead reporter)" do
      [o | _] = page()
      Samen.Kms.FileBacked.simulate_outage(true)

      {out, log} = resolve_quiet(record(o))
      assert %Masked{} = out.full_name
      assert count(log, "pii_resolution_reveal") == 1
      assert [%{cause: "unavailable"}] = drain_failures(:pii_resolution_reveal)
    end
  end

  # --- PiiResolution: a failed vault-row prefetch -----------------------------------------------------------

  describe "PiiResolution.prefetch — a failed vault-row prefetch is reported once" do
    test "RED: the prefetch read fails -> ONE report by name; the value is still the correct one (per-value read)" do
      owners = page()
      actor = %{plane: :tenant, org_id: Ash.UUID.generate()}
      tokens = for o <- owners, {_name, {token, _plain}} <- o.vals, do: token
      Process.put(:leak_tokens, tokens)
      msg = PrefetchDownRepo.message(tokens)
      # the injected failure really carries what a leak would show: the bound tokens and a value
      assert_raise DBConnection.ConnectionError, msg, fn -> PrefetchDownRepo.all(nil) end
      assert msg =~ "vt_" and msg =~ @leak # bare-vt_-ok: the message names the vt_ marker; it is not a token in a page

      log =
        capture_log(fn ->
          out = PiiResolution.resolve(Enum.map(owners, &record/1), Person, actor, repo: PrefetchDownRepo)
          # the prefetch only saves reads: the per-value read answers, so nothing is wrongly masked or revealed
          assert Enum.zip(owners, out) |> Enum.all?(fn {o, r} -> r.full_name == elem(o.vals.full_name, 1) end)
        end)

      assert count(log, "pii_resolution_vault_rows") == 1
      assert log =~ "cause=DBConnection.ConnectionError"
      assert [%{cause: "DBConnection.ConnectionError"}] = drain_failures(:pii_resolution_vault_rows)
      refute log =~ "SECRET"
      refute_vault_token(log)
      refute log =~ @leak
      refute log =~ "connection not available"
      for token <- tokens, do: refute(log =~ token)
      refute log =~ msg
      assert log =~ "org=#{actor.org_id}"
    end

    test "POSITIVE CONTROL: the healthy repo prefetches without a report" do
      owners = page()

      log =
        capture_log(fn ->
          PiiResolution.resolve(Enum.map(owners, &record/1), Person, %{plane: :tenant, org_id: Ash.UUID.generate()}, repo: Repo)
        end)

      refute log =~ "pii_resolution_vault_rows"
      assert drain_failures(:pii_resolution_vault_rows) == []
    end
  end

  # --- PiiResolution: an unreadable custom-field catalog ----------------------------------------------------

  describe "PiiResolution bag — an unreadable pii_declared catalog masks the whole bag AND says so" do
    @table "tcf_widget"
    @key "care_note"
    @secret "alice@example.com"

    defp define!(org_id) do
      {:ok, _} =
        CustomFields.define_field(
          %{
            org_id: org_id,
            table_name: @table,
            field_name: @key,
            type: :string,
            pii_declared: true,
            erasure_specs: [%{table_name: @table, bag_column: "tcf_custom", subject_column: "tcf_id", org_column: "tcf_org_id"}]
          },
          Repo
        )
    end

    defp widget(org_id),
      do: struct(Widget, %{id: Ecto.UUID.generate(), name: "w", org_id: org_id, custom: %{@key => @secret, "tier" => "gold"}})

    defp op(org), do: %{plane: :operator, org_id: org, impersonation: %{session_id: "s"}}

    test "RED: the catalog read fails -> the WHOLE bag is masked (unchanged), ONE report by name, no value" do
      org = Ash.UUID.generate()
      define!(org)

      log =
        capture_log(fn ->
          out = PiiResolution.resolve([widget(org), widget(org), widget(org)], Widget, op(org), repo: CatalogDownRepo, grant: DenyAll)
          assert Enum.all?(out, fn r -> match?(%Masked{}, r.custom[@key]) and match?(%Masked{}, r.custom["tier"]) end)
        end)

      assert count(log, "pii_resolution_declared_keys") == 1
      assert log =~ "cause=DBConnection.ConnectionError"
      assert [%{cause: "DBConnection.ConnectionError"}] = drain_failures(:pii_resolution_declared_keys)
      msg = CatalogDownRepo.message()
      # the injected failure really carries what a leak would show
      assert msg =~ @secret and msg =~ "vt_" and msg =~ "gold" # bare-vt_-ok: the message names the vt_ marker; it is not a token in a page
      refute log =~ @secret
      refute log =~ "gold"
      refute_vault_token(log)
      refute log =~ "connection not available"
      refute log =~ msg
      assert log =~ "org=#{org}"
    end

    test "POSITIVE CONTROL: a readable catalog masks only the declared key and reports nothing" do
      org = Ash.UUID.generate()
      define!(org)

      log =
        capture_log(fn ->
          [out] = PiiResolution.resolve([widget(org)], Widget, op(org), repo: Repo, grant: DenyAll)
          assert %Masked{} = out.custom[@key]
          assert out.custom["tier"] == "gold"
        end)

      refute log =~ "pii_resolution_declared_keys"
      assert drain_failures(:pii_resolution_declared_keys) == []
    end
  end

  # --- FeatureFlags: a flag that could not be LOADED is OFF (closed) and says so --------------------------------

  describe "FeatureFlags — a failed flag load fails OFF (never on) AND is reported by name" do
    defp flag_name, do: "e.flag.#{System.unique_integer([:positive])}"

    test "RED: an unreadable flag table -> OFF (kill_switch, unchanged), ONE report by name, no query or value" do
      name = flag_name()
      owner = Ash.UUID.generate()

      log =
        capture_log(fn ->
          assert %Decision{on: false, reason: :kill_switch} =
                   FeatureFlags.evaluate(name, Ash.UUID.generate(), flag_module: UnreadableFlag, owner_org_id: owner)
        end)

      assert count(log, "feature_flag_load") == 1
      assert log =~ "cause=Ash.Error.Unknown"
      refute log =~ name
      assert [%{cause: "Ash.Error.Unknown"} | _] = drain_failures(:feature_flag_load)
    end

    test "RED: a loader that RAISES -> OFF, reported by exception module, the exception message (which holds a value) never logged" do
      name = flag_name()
      loader = fn _ -> raise RuntimeError, "loader refused for cohort tier=Secret-7731" end

      log = capture_log(fn -> assert %Decision{on: false} = FeatureFlags.evaluate(name, "org", loader: loader) end)

      assert count(log, "feature_flag_load") == 1
      assert log =~ "cause=RuntimeError"
      refute log =~ "Secret-7731"
    end

    test "POSITIVE CONTROL: a readable flag is ON and an unconfigured owner is a documented OFF; neither is reported" do
      name = flag_name()
      on = %{name: name, enabled: true, rollout_pct: 100, stage: nil, target_rules: [], variants: %{}}

      log =
        capture_log(fn ->
          assert %Decision{on: true} = FeatureFlags.evaluate(name, "org", loader: fn _ -> {:ok, on} end)

          Cache.invalidate_all()
          assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate(flag_name(), "org", flag_module: UnreadableFlag, owner_org_id: nil)
          assert %Decision{on: false, reason: :kill_switch} = FeatureFlags.evaluate(flag_name(), "org", loader: fn _ -> {:ok, nil} end)
        end)

      refute log =~ "feature_flag_load"
      assert drain_failures(:feature_flag_load) == []
    end

    test "RED: an assignment emitter that raises costs only the event: the decision stays ON and the lost write is reported" do
      name = flag_name()
      on = %{name: name, enabled: true, rollout_pct: 100, stage: nil, target_rules: [], variants: %{"a" => 1}}
      emit = fn _payload -> raise RuntimeError, "emit refused for cohort tier=Secret-7731" end

      log =
        capture_log(fn ->
          assert %Decision{on: true, variant: :a} = FeatureFlags.evaluate(name, "org", loader: fn _ -> {:ok, on} end, emit: emit)
        end)

      assert log =~ "write failed write=feature_flag_assignment_emit"
      assert log =~ "cause=RuntimeError"
      refute log =~ "Secret-7731"

      # POSITIVE CONTROL: a working emitter on the same flag reports nothing
      control =
        capture_log(fn ->
          assert %Decision{on: true, variant: :a} = FeatureFlags.evaluate(flag_name(), "org", loader: fn _ -> {:ok, on} end, emit: fn _ -> :ok end)
        end)

      refute control =~ "feature_flag_assignment_emit"
    end
  end

  # --- Tracer: tracing plumbing never runs a job twice, and its failures are reported ---------------------------

  describe "Tracer.with_job_span — the job body runs exactly once" do
    defp counter, do: :counters.new(1, [])
    defp bump(c), do: :counters.add(c, 1, 1)

    test "RED: a job body that RAISES is run once and its exception propagates (it was run a second time before)" do
      c = counter()

      assert_raise RuntimeError, "job failed", fn ->
        Tracer.__with_job_span__("job", %{}, fn ->
          bump(c)
          raise RuntimeError, "job failed"
        end)
      end

      assert :counters.get(c, 1) == 1

      # the meta-carrying clause is the same
      c2 = counter()

      assert_raise RuntimeError, fn ->
        Tracer.__with_job_span__("job", %{"trace_context" => []}, fn ->
          bump(c2)
          raise RuntimeError, "job failed"
        end)
      end

      assert :counters.get(c2, 1) == 1
    end

    test "RED: a body that raises while the span's CLEANUP also raises: the BODY's exception wins, the job ran once" do
      for meta <- [%{}, %{"trace_context" => []}] do
        c = counter()

        assert_raise RuntimeError, "job failed", fn ->
          Tracer.__with_job_span__("job", meta, fn -> bump(c) && raise(RuntimeError, "job failed") end, CleanupFailingOtel)
        end

        assert :counters.get(c, 1) == 1
      end
    end

    test "RED: tracing that fails BEFORE the body runs the body once, untraced, and reports by name (no message)" do
      c = counter()

      log =
        capture_log(fn ->
          assert :done == Tracer.__with_job_span__("job", %{}, fn -> bump(c) && :done end, SetupFailingOtel)
        end)

      assert :counters.get(c, 1) == 1
      assert log =~ "write failed write=job_span_setup"
      assert log =~ "cause=RuntimeError"
      refute log =~ "Secret-7731"
    end

    test "RED: tracing that fails AFTER the body finished returns the body's result, once, and reports" do
      c = counter()

      log =
        capture_log(fn ->
          assert :done == Tracer.__with_job_span__("job", %{"trace_context" => []}, fn -> bump(c) && :done end, FinishFailingOtel)
        end)

      assert :counters.get(c, 1) == 1
      assert log =~ "write failed write=job_span_finish"
    end

    test "POSITIVE CONTROL: healthy tracing returns the body's result once and reports nothing" do
      c = counter()
      log = capture_log(fn -> assert :done == Tracer.__with_job_span__("job", %{}, fn -> bump(c) && :done end) end)
      assert :counters.get(c, 1) == 1
      refute log =~ "job_span"
    end
  end

  describe "Tracer.inject_trace_context — a lost trace link is reported, the job is still enqueued" do
    test "RED: a changeset whose meta cannot take the context comes back unchanged and the lost link is reported; a normal one is stamped" do
      broken = Ecto.Changeset.change(%Oban.Job{}, meta: "not a map")
      healthy = Oban.Job.new(%{a: 1}, worker: "W", queue: :default)

      log =
        capture_log(fn ->
          :otel_tracer.with_span(:opentelemetry.get_application_tracer(__MODULE__), "e.enqueue", %{}, fn _ ->
            assert ^broken = Tracer.inject_trace_context(broken)

            # POSITIVE CONTROL inside the same span: a changeset that can take it is stamped
            assert %{"trace_context" => [_ | _]} = Ecto.Changeset.get_field(Tracer.inject_trace_context(healthy), :meta)
          end)
        end)

      assert count(log, "trace_context_inject") == 1
      refute log =~ "not a map"
    end
  end

  # --- Search: an unreadable registry is not "nothing is searchable" ------------------------------------------

  describe "Search.query — a registry that cannot be read raises instead of answering []" do
    defp search_scope(org),
      do: %Samen.Scope{actor: %{id: "u:#{org}", org_id: org, role: :member, plane: :tenant}}

    defp search_opts(index),
      do: [resources: [SamenCore.Support.Archivable.Widget], search_index: index, repo: Repo]

    test "RED: an unreadable registry raises (the callers report it) — it used to read as [], 'no results'" do
      org = Ash.UUID.generate()
      assert_raise Ash.Error.Unknown, fn -> Samen.Search.query(search_scope(org), "invoice", search_opts(UnreadableSearchIndex)) end
    end

    test "POSITIVE CONTROL: a readable registry with nothing registered is an honest []" do
      assert [] == Samen.Search.query(search_scope(Ash.UUID.generate()), "invoice", search_opts(SearchIndex))
    end

    test "RED at the caller: the search_records tool says its text arm is in ERROR (reported), not that it found nothing" do
      org = Ash.UUID.generate()
      key = Samen.Automation.Actions.SearchRecords
      previous = Application.get_env(:samen_core, key)
      Application.put_env(:samen_core, key, search: search_opts(UnreadableSearchIndex))

      on_exit(fn ->
        if previous, do: Application.put_env(:samen_core, key, previous), else: Application.delete_env(:samen_core, key)
      end)

      ctx = %Samen.Automation.Context{
        org_id: org,
        workflow_id: nil,
        subject_ref: "samen:test",
        actor: search_scope(org),
        origin: {:agent, "r"}
      }

      log =
        capture_log(fn ->
          assert {:ok, %{text_search: "error", hits: hits}} = key.run(%{"query" => "invoice", "limit" => 5}, ctx)
          assert Enum.all?(hits, &(&1["via"] != "text"))
        end)

      assert count(log, "search_records_text") == 1
    end
  end

  # --- CDC projection: an unreadable non_pii! registry shrinks the mirror, and says so -----------------------------

  describe "Cdc.Projection — an unreadable non_pii! registry fails closed AND is reported" do
    @patient SamenCore.Support.Clinical.Patient
    @column "pat_job_title"

    defp projected(opts), do: @patient |> Samen.Cdc.Projection.project(opts) |> Enum.map(&elem(&1, 0))

    test "RED: the registry read fails -> the cleared column is NOT mirrored (closed, unchanged), ONE report by name" do
      table = Samen.Cdc.Projection.table_name(@patient)

      assert {:ok, _} =
               Samen.NonPii.register(%{
                 table_name: table,
                 column_name: @column,
                 cleared_by: "alice@example.com",
                 reviewed_by: "bob@example.com",
                 reason: "reviewed as non-PII operational text",
                 subject_column: "id",
                 repo: Repo
               })

      # POSITIVE CONTROL: with the registry readable the cleared column IS mirrored, and nothing is reported
      control = capture_log(fn -> assert @column in projected(repo: Repo) end)
      refute control =~ "cdc_projection_non_pii_entries"

      log = capture_log(fn -> refute @column in projected(repo: CatalogDownRepo) end)

      assert count(log, "cdc_projection_non_pii_entries") == 1
      assert log =~ "cause=DBConnection.ConnectionError"
    end
  end
end
