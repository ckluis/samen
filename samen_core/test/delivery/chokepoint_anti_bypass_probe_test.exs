defmodule Samen.Delivery.ChokepointAntiBypassProbeTest do
  @moduledoc """
  T30 hardening (scope addendum #2, routed from the T28 adversarial verifier):
  the anti-bypass probe that used to live in `lifecycle_send_test.exs` scanned
  a HARDCODED 8-file allowlist of "known C2 consumer" paths
  (`@consumer_scope_rel`). The T28 verifier defeated it trivially: it added a
  rogue module in a BRAND NEW file — outside the 8 named paths — that called
  `adapter.deliver(message, config)` directly, and the probe stayed green,
  because it never looked anywhere else.

  A hardcoded allowlist of "files that are allowed to be clean" is exactly the
  wrong shape for an anti-bypass probe: it protects only the files someone
  remembered to enumerate, and is invisible to every future file. This
  replacement is a FULL-TREE scan — every `lib/**/*.ex` (and generator
  `.eex` template) file across EVERY app in the repo — with a SHORT,
  individually-justified list of exclusions, not a long list of "trusted"
  files:

    1. `samen_core/lib/samen/delivery/chokepoint.ex` — THE single legitimate
       caller (ADR-038 §4.3/§4.1; this is the module the probe exists to
       protect, not route around).
    2. `samen_core/lib/samen/delivery/provider_conformance_case.ex` — the
       §4.5(f) capture-transport test HARNESS (ships in `lib`, house
       precedent per `Samen.RedPath`/`Samen.MaskingCase`): it legitimately
       exercises `provider.deliver/2` directly to test an ADAPTER in
       isolation (fixture transport, never a real send), not to dispatch a
       real lifecycle send. Named explicitly in the Chokepoint moduledoc as
       the one sanctioned harness exception.
    3. Two calls named `Lifecycle.deliver(` / `Samen.Delivery.Lifecycle.deliver(`
       — a DIFFERENT function entirely (`Samen.Delivery.Lifecycle.deliver/2`,
       arity 2 over an EVENT ATOM + opts, not a `Message` + adapter config). It
       is the enqueue-only Lifecycle API: it mints an Oban job and NEVER calls
       an adapter itself (see its own moduledoc: "mints an Oban job — never
       calls a provider"). Its only production caller is
       `samen_core/lib/samen/billing/dunning.ex`.
    4. Two calls named `Webhook.deliver(` / `Samen.Webhook.deliver(` — a
       COMPLETELY UNRELATED subsystem (`samen_core/lib/samen/webhook.ex`,
       outbound org-configured webhook delivery over the `webhooks_out`
       queue) that shares the English word "deliver" but has nothing to do
       with `Samen.Delivery.Provider`.

  Every other `X.deliver(...)` call ANYWHERE under any app's `lib/` (or the
  generator template set) is a violation — proven anti-tautological below by
  folding a rogue file (isolated in a temp directory, so a concurrent `async:
  true` test never races a real `lib/` mutation) into the scan via
  `scan_paths/1`'s `extra_roots`, asserting the probe trips, then removing it
  and asserting green again (the exact rogue-file shape that defeated the OLD
  probe).

  Test directories are intentionally OUT of this probe's scope: adapter
  packages' own unit/conformance tests legitimately call their OWN
  `Provider.deliver/2` directly to test the isolated unit (e.g.
  `samen_postmark/test/provider_test.exs`, `samen_core/test/
  delivery_provider_test.exs` testing `LocalSink`/`Smtp`/`Api` directly) — that
  is unit-testing an adapter's implementation, not a production consumer
  bypassing the chokepoint. The bypass risk this probe defends against is
  PRODUCTION code (`lib/`) reaching an adapter without going through
  `Samen.Delivery.Chokepoint.send/2`.
  """
  use ExUnit.Case, async: true

  # samen_core/test/delivery/<this file> -> ../../.. = repo root.
  @repo_root Path.expand("../../..", __DIR__)

  # Every app's `lib/` tree gets scanned — including the four first-party-but-
  # separate adapter packages (ADR-038 §8.1; may be ABSENT when the T31 INV-4
  # probe has moved them out, hence `File.dir?` gating below), the verticals,
  # and the spikes. `Path.wildcard` on a missing directory returns `[]`, so
  # this is safe whether or not every app is present.
  @app_lib_globs ~w(
    samen_core/lib
    samen_web/lib
    samen_stripe/lib
    samen_postmark/lib
    samen_ses/lib
    samen_resend/lib
    demo/lib
    driftwood/lib
    pawchart/lib
    spikes/*/lib
  )

  # Generator templates (ADR-023 codegen) — a template could theoretically
  # emit code that bypasses the chokepoint in every generated app. Scanned as
  # plain text (the same regex works fine over `.eex`).
  @generator_template_globs ~w(
    samen_core/priv/templates
  )

  @excluded_files ~w(
    samen_core/lib/samen/delivery/chokepoint.ex
    samen_core/lib/samen/delivery/provider_conformance_case.ex
  )
  |> Enum.map(&Path.join(Path.expand("../../..", __DIR__), &1))

  # Matches an actual CALL (`something.deliver(`) — not a definition (`def
  # deliver(`, no leading dot) and not a callback/typespec (`deliver(message ::`).
  @deliver_call_re ~r/([A-Za-z_][A-Za-z0-9_.]*)\.deliver\(/

  # The two DIFFERENT, non-adapter "deliver"-named functions documented above
  # — matched by their EXACT qualified receiver name, not a wildcard.
  @known_non_adapter_receivers ~w(Lifecycle Samen.Delivery.Lifecycle Webhook Samen.Webhook)

  # `extra_roots` — additional absolute directories to fold into the scan
  # (used ONLY by the rogue-file proof below, which plants a synthetic file in
  # an ISOLATED temp directory rather than mutating the real, committed
  # `samen_core/lib` tree — writing a real file into `lib/` while `async: true`
  # tests run concurrently races other suites that snapshot/copy the lib
  # directory, e.g. `chokepoint_test.exs`'s sabotage harness).
  defp scan_paths(extra_roots \\ []) do
    (@app_lib_globs ++ @generator_template_globs)
    |> Enum.flat_map(fn rel_glob ->
      Path.wildcard(Path.join(@repo_root, rel_glob))
    end)
    |> Kernel.++(extra_roots)
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join(dir, "**/*.{ex,eex}"))
    end)
    |> Enum.reject(&(&1 in @excluded_files))
  end

  defp offending_deliver_calls(paths) do
    for path <- paths,
        File.regular?(path),
        {line, idx} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        [_, receiver] <- [Regex.run(@deliver_call_re, line) || [nil, nil]],
        not is_nil(receiver),
        receiver not in @known_non_adapter_receivers do
      {Path.relative_to(path, @repo_root), idx, String.trim(line)}
    end
  end

  describe "full-tree probe: the provider is called ONLY from Samen.Delivery.Chokepoint" do
    test "zero direct adapter.deliver(...) calls anywhere under any app's lib/ (or generator templates)" do
      offenders = offending_deliver_calls(scan_paths())

      assert offenders == [],
             "a send path bypassed the chokepoint — direct deliver/2 call(s) found OUTSIDE " <>
               "Chokepoint/the conformance harness: #{inspect(offenders)}"
    end

    test "sanity: the scan genuinely walks the real tree (finds files in multiple apps)" do
      paths = scan_paths()
      assert Enum.any?(paths, &String.contains?(&1, "/samen_core/lib/"))
      assert Enum.any?(paths, &String.contains?(&1, "/samen_web/lib/"))
    end

    test "the chokepoint file itself IS the (sole) legitimate caller" do
      chokepoint_path = Path.join(@repo_root, "samen_core/lib/samen/delivery/chokepoint.ex")

      # Scanned WITHOUT the exclusion list (bypassing @excluded_files on purpose)
      # to prove the real adapter.deliver(...) call is genuinely there.
      offenders =
        for {line, idx} <-
              chokepoint_path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            [_, receiver] <- [Regex.run(@deliver_call_re, line) || [nil, nil]],
            not is_nil(receiver) do
          {idx, receiver}
        end

      assert offenders != [], "sanity: Chokepoint must contain the real adapter.deliver(...) call"
    end

    test "known non-adapter 'deliver' functions (Lifecycle/Webhook) are real, distinct functions" do
      # Guards the exclusion list itself against silent drift: if either
      # function were ever renamed/removed, or grew a real adapter dispatch,
      # this fails loudly rather than the exclusion quietly widening.
      lifecycle_src =
        File.read!(Path.join(@repo_root, "samen_core/lib/samen/delivery/lifecycle.ex"))

      webhook_src = File.read!(Path.join(@repo_root, "samen_core/lib/samen/webhook.ex"))

      assert lifecycle_src =~ ~r/def deliver\(event, opts/,
             "Lifecycle.deliver/2 must remain the enqueue-only event API this exclusion documents"

      # Any `X.deliver(` occurrence in this file (including its own moduledoc
      # usage example, which legitimately reads `Samen.Delivery.Lifecycle.deliver(`)
      # must have a receiver in the known-safe set — never a NEW, unexcluded
      # adapter-shaped receiver sneaking in under cover of this file's name.
      unexpected =
        for [_, receiver] <- Regex.scan(@deliver_call_re, lifecycle_src),
            receiver not in @known_non_adapter_receivers do
          receiver
        end

      assert unexpected == [],
             "lifecycle.ex must never itself call an adapter's deliver/2 (it mints an Oban job " <>
               "only) — found unexpected receiver(s): #{inspect(unexpected)}"

      assert webhook_src =~ ~r/def deliver\(event_type, resource, record/,
             "Webhook.deliver/4 must remain the unrelated outbound-webhook API this exclusion documents"
    end

    test "ROGUE-FILE RED PROOF: a throwaway module calling adapter.deliver in a NEW file trips the probe" do
      # Planted in an ISOLATED temp directory (an `extra_roots` fold-in, see
      # scan_paths/1) rather than the real committed `samen_core/lib` tree:
      # this test runs `async: true` alongside every other suite, and writing
      # a real file into `lib/` while OTHER tests snapshot/copy that directory
      # concurrently (e.g. `chokepoint_test.exs`'s sabotage harness) is a real
      # filesystem race, not merely a style preference. The T28 defeat this
      # hardens against was "a rogue module in a file the hardcoded allowlist
      # never named" — this proves the SAME mechanism (glob a directory tree +
      # regex + exclusion list) catches a brand-new file in ANY scanned root,
      # which is the property that matters; `scan_paths/0`'s OWN "sanity"
      # test above independently proves the real app dirs are among the
      # roots actually scanned by default.
      tmp_root = Path.join(System.tmp_dir!(), "t30_rogue_lib_#{System.unique_integer([:positive])}")
      rogue_path = Path.join(tmp_root, "rogue_bypass_probe_tmp.ex")
      File.mkdir_p!(tmp_root)

      File.write!(rogue_path, """
      defmodule Samen.Delivery.RogueBypassProbeTmp do
        @moduledoc "T30 anti-bypass rogue-file red proof — an isolated temp file, never in the real tree."
        def sneak_around_chokepoint(adapter, message, config) do
          adapter.deliver(message, config)
        end
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_root) end)

      offenders_with_rogue = offending_deliver_calls(scan_paths([tmp_root]))

      assert Enum.any?(offenders_with_rogue, fn {path, _line, _src} ->
               String.ends_with?(path, "rogue_bypass_probe_tmp.ex")
             end),
             "the rogue file MUST be detected by the full-tree scan — got: #{inspect(offenders_with_rogue)}"

      File.rm_rf!(tmp_root)

      offenders_after_removal = offending_deliver_calls(scan_paths([tmp_root]))

      refute Enum.any?(offenders_after_removal, fn {path, _line, _src} ->
               String.ends_with?(path, "rogue_bypass_probe_tmp.ex")
             end),
             "removing the rogue file must restore a green scan"
    end

    test "ANTI-TAUTOLOGY: the matcher genuinely flags a synthetic violation outside the tree" do
      tmp =
        Path.join(System.tmp_dir!(), "chokepoint_probe_sabotage_#{System.unique_integer([:positive])}.ex")

      File.write!(tmp, """
      defmodule SabotageConsumer do
        def perform(adapter, message, config) do
          adapter.deliver(message, config)
        end
      end
      """)

      on_exit(fn -> File.rm(tmp) end)

      assert offending_deliver_calls([tmp]) != [],
             "the anti-tautology twin: a bypassing call MUST be detectable, or this probe is vacuous"
    end
  end
end
