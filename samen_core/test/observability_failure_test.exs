defmodule Samen.Observability.FailureTest do
  @moduledoc """
  The kernel's value-free failure report (`Samen.Observability.Failure`): one log line and one telemetry event
  carrying the operation NAME, a canonical-UUID org and the exception MODULE names — never a message, a struct,
  a value or a raw parameter. `Samen.Web.Reads.Guard.report/3` delegates to it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Samen.Observability.Failure

  @org "0b0d6c1e-2f5a-4c3e-9a41-7d1c2f3e4a5b"
  @secret "jane.doe@example.com"

  defp boom, do: %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{error: @secret}]}

  test "reports the name, the org and the exception module names — and nothing else" do
    log = capture_log(fn -> assert :ok = Failure.report(:probe, %{actor: %{org_id: @org}}, boom()) end)

    assert log =~ "read failed read=probe org=#{@org} cause=Ash.Error.Unknown"
    assert log =~ "Ash.Error.Unknown.UnknownError"
    refute log =~ @secret
  end

  test "a failed write is reported as a write, with its own telemetry event" do
    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      [:samen, :core, :write, :error],
      fn _e, m, meta, _ -> send(parent, {:event, m, meta}) end,
      nil
    )

    log = capture_log(fn -> Failure.report(:write, :put_thing, @org, ArgumentError.exception(@secret), []) end)
    :telemetry.detach(id)

    assert log =~ "write failed write=put_thing org=#{@org} cause=ArgumentError"
    refute log =~ @secret
    assert_receive {:event, %{count: 1}, %{write: :put_thing, cause: "ArgumentError"}}
  end

  test "a forged org id cannot inject a log line; an atom reason is named; an unknown shape is 'unknown'" do
    forged = "x\n[error] cause=forged org=" <> String.duplicate("a", 40)

    log =
      capture_log(fn ->
        Failure.report(:forge, forged, :exit)
        Failure.report(:odd, nil, {:weird, @secret})
      end)

    assert log =~ "read=forge org=invalid cause=exit"
    assert log =~ "read=odd org=unknown cause=unknown"
    refute log =~ "cause=forged"
    refute log =~ @secret
  end

  test "custom tag and event prefix are honoured (the web layer's compatibility seam)" do
    log = capture_log(fn -> Failure.report(:read, :tagged, @org, ArgumentError.exception("x"), tag: "[Samen.Web.Reads]", event_prefix: [:samen, :web]) end)
    assert log =~ "[Samen.Web.Reads] read failed read=tagged"
  end

  # `Failure.report/3` hard-codes kind `:read`, so a FAILED WRITE reported through it is counted as a read failure.
  # A name heuristic (a suffix list) missed real write failures (`agent_expire_parked`, `agent_on_proposal_expired`,
  # `break_glass_unanchored_signal`), so the guard is structural: it enumerates EVERY 3-arity `Failure.report(` call in
  # samen_core/lib and samen_web/lib and requires its op name to be in the reviewed READ list below. A new 3-arity call
  # with an unlisted name fails, telling its author to decide: a write goes through `report_write/3`; only a failed
  # READ (a lookup, a probe, a scan, a resolve) is listed here.
  @read_ops ~w(
    run_worker_owner_membership live_events_compute live_telemetry_pseudonym live_telemetry_trace cdc_projection_non_pii_entries feature_flag_cache_get feature_flag_cache_start feature_flag_evaluate feature_flag_evaluate_config feature_flag_load param_filter pii_classify_registry pii_resolution_declared_keys pii_resolution_reveal pii_resolution_vault_rows replay_allowed_beam replay_buffer replay_decode_frame replay_flag_on replay_keep replay_player_list replay_player_load replay_pseudonym replay_resolver_prefetch replay_resolver_read replay_resolver_records replay_resolver_resolve replay_resolver_shredded replay_sanitize
    webhook_delivery_load_endpoint webhook_delivery_repo webhook_ingest_repo webhook_deliver_lookup
    subject_in_org_resource subject_in_org_lookup search_index_pii_read
    action_effect action_tool_schema agent_cancel_load agent_fetch_turn agent_health_probe agent_health_repo_running
    agent_load_approval agent_pending_turn agent_refuse_vt_args agent_run_tool agent_transcript_reveal agent_transcript_views agent_validate_args
    catalog_meaning_introspect ai_catalog_custom_objects ai_catalog_grounding ai_catalog_object_fields ai_catalog_schema ai_catalog_table_entry
    ai_native_tools approval_existing_pending approval_fetch approval_res_repo approval_subject_refs approver_castable_key approver_read_membership approver_resolve_wired assign_owner_attribute
    assign_owner_fetch audit_chain_probe audit_chain_reveal_events audit_default_landing_probe audit_partition_runway
    audit_partitions_list authz_roles_for automation_breaker_count automation_res_repo break_glass_already_anchored break_glass_anchored_count
    breaker_definition_killed breaker_kills_status breaker_rate_count chokepoint_assemble_and_scrub chokepoint_granted
    chokepoint_resolve_binding chokepoint_safe_metadata chokepoint_scrub_metadata chokepoint_scrub_system
    chokepoint_scrub_tools chokepoint_scrub_turns chokepoint_simulated_provider chokepoint_static_tool_def
    chokepoint_turns_without_grants chokepoint_unsafe_metadata chokepoint_unsafe_segment column_nullability
    consent_change_maybe_append consent_change_org_unresolved csat_survey_preview csat_survey_respond
    deliverability_consented deliverability_flag_on dunning_org_resolver embeddings_knn embeddings_resolve_resource
    embeddings_simulated_provider embeddings_stale_rows embeddings_vault_routed erasure_define_guard_probe
    erasure_define_object_guard_probe erasure_pending_read escalate_existing_active event_capture_active_match
    event_capture_reload_org fetch_record_read fleet_enrollment_consume fleet_heartbeat_credential_lookup hooks_safe_call invite_reveal_invitation_email
    log_telemetry_list_handlers marketing_send_subscriber_lookup mailbox_match mailbox_unqueryable_address mailbox_unqueryable_external_id marketing_consent_state marketing_receipt_lookup mcp_domain_resources mcp_table_name non_pii_count_unredacted nullability_sweep
    no_plaintext_pii_registry non_pii_eligible_names oban_jobs_recent_scan oban_jobs_subject_scan oban_jobs_table_probe operator_plane_safe_get
    operator_plane_safe_read_by_org org_actor_resolve post_shred_replay_attest post_shred_replay_resolve
    public_status_read query_budget_check resolution_resolve resolution_resolve_org_id resolution_resolve_org_id_via_scan
    resolution_resolve_via_org_scan resolution_scope_from_assignments resolution_scope_of reveal_orphan_scan reveal_pending_decided reveal_pending_enrich reveal_pending_for_org run_record_find_by_key
    run_worker_load_eligible run_worker_load_workflow run_worker_reread_subject schedule_advance_reload_org search_records_semantic sequence_receipt_lookup
    search_records_text single_node_state suspension_active_row suspension_status tool_result_pii_names
    tool_result_render_records tool_result_repo_of tool_surface_surfaces_for vault_key_column_probe
    vault_reveal_probe write_proposal_fetch_turn
  )a

  # 3-arity calls whose op name is a variable, each a thin wrapper whose own call sites pass a literal READ name.
  @dynamic_read_sites [
    {"samen_core/lib/samen/ai/agent/health.ex", "name"},
    {"samen_core/lib/samen/automation/health.ex", "name"}
  ]

  # Every `Failure.report(` call in `files` as `{relative_file, arity, first_argument_source}`, the arity counted over
  # the top-level commas of the (possibly multi-line) argument list.
  defp failure_report_calls(files, root) do
    for file <- files,
        src = File.read!(file),
        {pos, len} <- Regex.scan(~r/Failure\.report\(/, src, return: :index) |> Enum.map(&hd/1) do
      # a trailing bare keyword list (`tag: ..., event_prefix: ...`) is ONE argument (the opts)
      args =
        src
        |> binary_part(pos + len, byte_size(src) - pos - len)
        |> call_args()
        |> Enum.reduce([], fn arg, acc ->
          kw? = fn a -> String.match?(String.trim(a), ~r/^\w+:\s/) end
          if acc != [] and kw?.(arg) and kw?.(List.last(acc)), do: acc, else: acc ++ [arg]
        end)

      {Path.relative_to(file, root), length(args), args |> hd() |> String.trim()}
    end
  end

  # The top-level argument sources of a call whose `(` was just consumed (parens, brackets, braces and string
  # literals are skipped over). Raises if the call never closes: an unparsable site must fail loudly, not vanish.
  defp call_args(rest), do: call_args(rest, 0, "", [], nil)
  defp call_args(<<>>, _depth, _cur, _acc, _str), do: raise("unterminated Failure.report( call")
  defp call_args(<<"\\", c::utf8, t::binary>>, d, cur, acc, str) when str != nil, do: call_args(t, d, cur <> "\\" <> <<c::utf8>>, acc, str)
  defp call_args(<<c::utf8, t::binary>>, d, cur, acc, nil) when c in [?", ?'], do: call_args(t, d, cur <> <<c::utf8>>, acc, c)
  defp call_args(<<c::utf8, t::binary>>, d, cur, acc, c), do: call_args(t, d, cur <> <<c::utf8>>, acc, nil)
  defp call_args(<<c::utf8, t::binary>>, d, cur, acc, str) when str != nil, do: call_args(t, d, cur <> <<c::utf8>>, acc, str)
  defp call_args(<<")", _::binary>>, 0, cur, acc, nil), do: Enum.reverse([cur | acc])
  defp call_args(<<c::utf8, t::binary>>, d, cur, acc, nil) when c in [?(, ?[, ?{], do: call_args(t, d + 1, cur <> <<c::utf8>>, acc, nil)
  defp call_args(<<c::utf8, t::binary>>, d, cur, acc, nil) when c in [?), ?], ?}], do: call_args(t, d - 1, cur <> <<c::utf8>>, acc, nil)
  defp call_args(<<",", t::binary>>, 0, cur, acc, nil), do: call_args(t, 0, "", [cur | acc], nil)
  defp call_args(<<c::utf8, t::binary>>, d, cur, acc, nil), do: call_args(t, d, cur <> <<c::utf8>>, acc, nil)

  test "RED: no 3-arity Failure.report names a WRITE op: every 3-arity call names a CLASSIFIED READ op, an unlisted name fails until its author decides (control)" do
    root = Path.expand("../..", __DIR__)
    files = Path.wildcard(Path.join(root, "samen_core/lib/**/*.ex")) ++ Path.wildcard(Path.join(root, "samen_web/lib/**/*.ex"))
    calls = failure_report_calls(files, root)

    three = for {file, 3, first} <- calls, do: {file, first}
    five = for {file, 5, first} <- calls, do: {file, first}

    # POSITIVE CONTROL: the scan sees real 3-arity sites AND the 5-arity form (`report(:write, ...)`), across both apps
    assert length(three) > 100
    assert Enum.any?(five, fn {_f, first} -> first == ":write" end)
    assert Enum.any?(three, fn {f, _} -> String.starts_with?(f, "samen_core/") end)
    assert Enum.reject(calls, fn {_f, arity, _} -> arity in [3, 5] end) == [], "an unexpected Failure.report arity (a call_args parse slip?)"
    assert Enum.any?(three, fn {_f, first} -> first == ":agent_pending_turn" end)

    literal = for {_f, ":" <> name} <- three, do: String.to_atom(name)
    dynamic = for {f, first} <- three, not String.starts_with?(first, ":"), do: {f, first}

    assert dynamic -- @dynamic_read_sites == [],
           "a 3-arity Failure.report whose op name is a variable is invisible to this guard: use a literal name"

    unclassified = literal |> Enum.uniq() |> Kernel.--(@read_ops) |> Enum.sort()

    assert unclassified == [],
           "3-arity Failure.report reports a READ failure. Classify each op below: if what failed is a WRITE (an audit row, an " <>
             "insert, an update, an emit, a side effect that did not happen) call Failure.report_write/3; if it is a failed " <>
             "READ (a lookup, a probe, a scan, a resolve) add the name to @read_ops. Unclassified: #{inspect(unclassified)}"

    # the list is not a stale pile: every listed read op still has a 3-arity site
    assert @read_ops -- literal == [], "@read_ops names an op with no 3-arity Failure.report site: remove it"

    # ANTI-TAUTOLOGY: a write op reported through the 3-arity form IS caught, and the real write sites are not listed
    assert :archival_audit not in @read_ops
    assert Enum.all?(~w(agent_expire_parked agent_on_proposal_expired break_glass_unanchored_signal suspension_audit)a, &(&1 not in @read_ops))
    assert :sla_breach_escalation not in @read_ops
  end
end
