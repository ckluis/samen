defmodule AllowGrantForEgress do
  @moduledoc "Test grant checker: approves every reveal context (the operator-WITH-grant case)."
  @behaviour Samen.Reveal.Grant
  @impl true
  def granted?(_context), do: true
end

defmodule DenyGrantForEgress do
  @moduledoc "Test grant checker: denies every reveal context (the operator-WITHOUT-grant case)."
  @behaviour Samen.Reveal.Grant
  @impl true
  def granted?(_context), do: false
end

defmodule RaisingGrantForEgress do
  @moduledoc """
  Test grant checker that RAISES (a host-injected checker is adversarial input too: a
  misconfigured/broken checker must never become an egress — it is NOT a grant).
  """
  @behaviour Samen.Reveal.Grant
  @impl true
  def granted?(_context), do: raise("grant backend down")
end

defmodule VaultStubForEgress do
  @moduledoc """
  Test vault double: on the grant path, `reveal/3` returns the canary plaintext (keyless — no
  real decrypt, the grant-plaintext-egress path is proven at the value layer).
  """
  # MUST match @canary in the test module below.
  def reveal(%Samen.Masked{}, _repo, _opts), do: {:ok, "canary-egress-9z8y7x@leak.example"}
end

defmodule Samen.AI.AiPromptMaskingRedTeamTest do
  @moduledoc """
  RP-AI-9 / RP-AI-10 (ADR-043 §3.4 / §10.2) — the PERMANENT mask-leak red-team, the runtime
  half of the `ai_prompt_masking` verifier tier (the structural half is
  `mix samen.verify.ai_prompt_masking`). T65 ESTABLISHES this standing CI gate; T72 EXTENDS it
  (more adversarial cases + full-DB canary seeding).

  It fires a known PII **canary** (a vault-routed 🔒 field on a real resource) through EVERY
  egress class the chokepoint governs and asserts the canary — plaintext AND its `vt_*` token
  — NEVER appears at any egress:

    * **EG1 completion prompt** — `:complete` seal → provider recording
      (`Provider.Fake.sent_payloads/0`, the honest-capture double);
    * **EG2 tool args + tool-result re-entry** — the STRUCTURED egress: tool args resolved
      from a vault-routed binding must arrive `••••` at the provider (asserted on the
      **:tenant** plane, whose own-org-clear read genuinely resolves the canary through the
      wired vault double — so only §6.1 egress mode masks it and the leg REFUTES), and
      hand-assembled tool args (arg tuple / keyword arg list / JSON-ish map / a tuple wrapping
      an un-rendered `%Masked{}`) are REFUSED fail-closed by the §3.2 step-3 scrub allowlist —
      the shape class a blocklist scrub silently egressed (sabotage 45);
    * **EG3 embedding input** — `:embed` seal REFUSES a vault-routed binding fail-closed
      (grants never unlock embedding, §7.2);
    * **EG4 MCP payload** — `:mcp` seal masks vault fields; grants never apply;
    * **EG5 committed fixtures** — this suite's own fixtures carry no raw token (asserted);
    * **EG6 logs / telemetry / errors** — a naive log line, a normalized adapter error, and a
      telemetry event carry no canary/`vt_` (the `%MaskedPayload{}` Inspect redaction + the
      payload-free refusal + the error normalization).

  Plus the load-bearing gates: the `grant_plaintext_egress` on/off behavior (§6.1), the
  multi-turn expired-grant re-scrub (§3.2a, RP-AI-10), fail-closed refusal of un-maskable
  content (RP-AI-2), and masked-on-every-plane (§6.1, stricter than the UI).

  **Sabotage-refutable** (the anti-tautology counterweight, `scripts/sabotages/`): neutralize
  the masker — e.g. drop the §3.2a history re-mask, or expose the vault token instead of
  `••••` — and a NAMED test here flips (the canary reaches an egress). The positive controls
  (`grant ON` egresses the canary; `assert_leak_detected!`) prove the refutations are not
  vacuous: the canary CAN reach the provider when the value layer permits it.
  """
  use ExUnit.Case, async: true
  use Samen.MaskingCase

  require Logger
  import ExUnit.CaptureLog

  alias Samen.AI.{Chokepoint, Completion, Provider}
  alias Samen.Api.PiiResolution
  alias Samen.Masked

  @res SamenCore.Support.RevealDomain.RevealPerson

  # The seeded PII canary. The %Masked{} carries only the vt_ token; the plaintext exists ONLY
  # behind the grant path (VaultStubForEgress) — so a masked-path canary appearance is a real
  # leak, and a grant-path appearance is the one permitted egress.
  @canary "canary-egress-9z8y7x@leak.example"
  @vt_token "vt_" <> String.duplicate("a", 32)

  setup do
    Provider.Fake.reset()

    field = @res |> Samen.Pii.Info.pii_attributes() |> Enum.at(0) |> Map.get(:name)
    reveal_action = @res |> Samen.Pii.Info.reveal_actions() |> Enum.at(0)
    id = "11111111-1111-1111-1111-111111111111"

    rec =
      @res
      |> struct(id: id, display_name: "Canary Corp")
      |> Map.put(field, Masked.new(@vt_token, field))

    ctx = %Samen.Reveal.Context{
      actor: %{plane: :operator},
      subject_id: id,
      resource: @res,
      action: reveal_action,
      label: field
    }

    # The grant-ON opts: host opt-in flag + live grant + a keyless vault double.
    grant_on = [grant_egress?: true, grant: AllowGrantForEgress, vault: VaultStubForEgress, repo: :fake_repo]

    %{rec: rec, field: field, ctx: ctx, op: %{plane: :operator}, grant_on: grant_on}
  end

  # --------------------------------------------------------------------------------------
  # EG1 + EG2 — completion prompt + tool args, observed at the provider recording (RP-AI-9)

  describe "EG1/EG2 — the canary never reaches the provider recording" do
    test "a masked completion (prompt + tool args + grounding + vault binding) leaks nothing",
         %{rec: rec, op: op} do
      assert {:ok, %Completion{}} =
               Chokepoint.complete(Provider.Fake, %{}, :complete,
                 ["System: you are a support agent.", ~s(tool_args: {"account":"lookup"})],
                 actor: op,
                 bindings: [{[rec], @res}],
                 grounding: %{table: :accounts}
               )

      recorded = recorded_text()

      refute recorded =~ @canary, "EG1/EG2 canary PLAINTEXT reached the provider"
      refute recorded =~ "vt_", "EG1/EG2 vt_ token reached the provider"
      assert recorded =~ mask(), "the vault field must be present-but-masked (••••)"

      # Anti-tautology: the same refute WOULD catch a real leak (the scan is refutable).
      assert_leak_detected!("modeled leak: #{@canary}", @canary)
    end

    test "grant ON (flag + live grant) egresses the canary plaintext — the ONE permitted egress",
         %{rec: rec, op: op, grant_on: grant_on} do
      # §6.1 positive control: with the host opt-in AND a live grant, plaintext enters the
      # ephemeral :complete payload and is transmitted to the provider (audited; the provider
      # is the destination). This also proves the masked-path assertions above are non-vacuous.
      assert {:ok, %Completion{}} =
               Chokepoint.complete(Provider.Fake, %{}, :complete, ["ctx"],
                 [actor: op, bindings: [{[rec], @res}]] ++ grant_on
               )

      assert recorded_text() =~ @canary
    end
  end

  # --------------------------------------------------------------------------------------
  # EG1 grounding/meta — T65-F8 close (ADR-043 §3.1 EG1 "grounding" / §3.2 step 3). T65's
  # fix-round verifier LIVE-REPRODUCED that `seal/3` scrubbed `segments` but copied
  # `:grounding`/`:meta` into the sealed payload UNSCRUBBED: a `vt_*`-carrying grounding value
  # egressed verbatim to the provider recording. This was inert only because nothing populated
  # grounding until T66 (the D9 runtime catalog) made it LIVE — so this closes the hole before
  # a real caller can hit it.

  describe "EG1 grounding/meta — a vt_*-carrying value is REFUSED fail-closed (T65-F8 close)" do
    test "a vt_* token embedded in :grounding is refused, never reaches the provider recording" do
      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"],
               grounding: %{table: "vt_aaa…", sample: @canary}
             ) == {:error, :pii_egress_refused}

      assert Provider.Fake.sent_payloads() == [],
             "T65-F8: an unscrubbed :grounding value must NEVER reach the provider"
    end

    test "a vt_* token embedded in :meta is refused, never reaches the provider recording" do
      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], meta: %{note: @vt_token}) ==
               {:error, :pii_egress_refused}

      assert Provider.Fake.sent_payloads() == [],
             "T65-F8: an unscrubbed :meta value must NEVER reach the provider"
    end

    test "a vt_* token nested under a grounding LIST/MAP (the catalog-dict shape) is refused" do
      # The D9 catalog's real shape: nested lists of maps (tables -> fields). A sentinel
      # buried two levels down must still refuse — proves the scrub recurses, not just scans
      # the top level.
      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"],
               grounding: %{
                 schema: %{"tables" => [%{"table_name" => "acc", "fields" => [%{"column_name" => @vt_token}]}]}
               }
             ) == {:error, :pii_egress_refused}

      assert Provider.Fake.sent_payloads() == []
    end

    test "a vt_* CHARLIST leaf in :grounding/:meta is refused (T66-F1 fix-round close)" do
      # `~c"vt_..."` is a LIST of safe integers — a naive list scrub (Enum.all? over elements
      # only) sees nothing but numbers and calls it safe; the sentinel lives in the RENDERING,
      # not any single element (`charlist_sentinel?/1`'s exact reason for existing on the
      # `segments` side, ADR-043 §3.2 step 3). Fires the canary as: a bare charlist grounding
      # value, a charlist NESTED under a grounding key, and a charlist under :meta.
      vt_charlist = String.to_charlist(@vt_token)

      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], grounding: vt_charlist) ==
               {:error, :pii_egress_refused}

      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"],
               grounding: %{sample: vt_charlist}
             ) == {:error, :pii_egress_refused}

      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], meta: %{raw: vt_charlist}) ==
               {:error, :pii_egress_refused}

      assert Provider.Fake.sent_payloads() == [],
             "T66-F1: a vt_*-rendering charlist leaf must NEVER reach the provider"
    end

    test "positive control: a benign CHARLIST grounding value seals (the charlist scrub is refutable)" do
      # Non-vacuous counterpart to the charlist canary above: an ordinary, sentinel-FREE
      # charlist must still be admitted — proves `charlist_sentinel?/1` scans for the
      # sentinel specifically, not "refuse every charlist".
      assert {:ok, %Completion{}} =
               Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], grounding: %{sample: ~c"accounts"})

      assert [{:complete, payload}] = Provider.Fake.sent_payloads()
      assert payload.grounding == %{sample: ~c"accounts"}
    end

    test "T147(b): a BENIGN non-map :grounding/:meta is a SHAPE error, not the security refusal" do
      # `%Samen.AI.MaskedPayload{}` docs `:grounding`/`:meta` as "a map keyed by bounded label
      # atoms". A wrong-TYPE (but leak-free) value is a SHAPE problem, not a PII egress — it must
      # NOT masquerade as `:pii_egress_refused` (which implies a leak the operator must chase).
      # It returns the DISTINCT `:invalid_grounding_shape` and still reaches no provider.
      for bogus <- ["a bare string", 42, ~c"accounts", :an_atom, ["a", "list"]] do
        assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], grounding: bogus) ==
                 {:error, :invalid_grounding_shape},
               "a benign non-map :grounding value must be a shape error, not a leak error: #{inspect(bogus)}"

        assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], meta: bogus) ==
                 {:error, :invalid_grounding_shape},
               "a benign non-map :meta value must be a shape error, not a leak error: #{inspect(bogus)}"
      end

      assert Provider.Fake.sent_payloads() == []
    end

    test "T147(b): nil / [] :grounding/:meta is accepted as 'no grounding' (not refused)" do
      # The natural "no grounding" default. It must SEAL and reach the provider — a `grounding: []`
      # is not a leak, not a shape error; it is simply empty. (Non-vacuous: asserts the {:ok}.)
      for empty <- [nil, []] do
        assert {:ok, %Completion{}} =
                 Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], grounding: empty),
               "an empty :grounding (#{inspect(empty)}) must seal, not refuse"

        assert {:ok, %Completion{}} =
                 Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], meta: empty),
               "an empty :meta (#{inspect(empty)}) must seal, not refuse"
      end
    end

    test "T147(b): the SHAPE relaxation does NOT weaken the scrub — a vt_* bare/map term still refuses" do
      # Security wins over the shape error: a `vt_*` sentinel smuggled in as a BARE top-level
      # charlist, or anywhere inside a MAP, STILL refuses `:pii_egress_refused` and reaches no
      # provider. (Guards the T147(b) change from silently downgrading a real leak to a shape error.)
      vt_charlist = ~c"vt_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"

      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"], grounding: vt_charlist) ==
               {:error, :pii_egress_refused},
             "a bare vt_* charlist grounding is a LEAK, not a mere shape error"

      assert Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"],
               grounding: %{table: "vt_aaa…", sample: @canary}
             ) == {:error, :pii_egress_refused},
             "a vt_* inside a MAP grounding still refuses as a leak"

      assert Provider.Fake.sent_payloads() == []
    end

    test "positive control: a benign grounding/meta map seals and reaches the provider (non-vacuous)" do
      assert {:ok, %Completion{}} =
               Chokepoint.complete(Provider.Fake, %{}, :complete, ["ok"],
                 grounding: %{table: :accounts, schema: %{"tables" => []}},
                 meta: %{payload_id: 1}
               )

      assert [{:complete, payload}] = Provider.Fake.sent_payloads()
      assert payload.grounding == %{table: :accounts, schema: %{"tables" => []}}
      assert payload.meta == %{payload_id: 1}
    end
  end

  # --------------------------------------------------------------------------------------
  # EG2 — tool args + tool-result re-entry (ADR-043 §3.1 EG2), the SHAPE-blind leak class.
  # EG2 is where an assembler hands the chokepoint STRUCTURED values (arg tuples, keyword
  # arg lists, JSON-ish maps) rather than rendered strings — the shapes a blocklist scrub
  # falls through as "safe". These legs are the non-vacuous EG2 proof: each fires a real
  # vault-routed canary/token through the tool-args egress path.

  describe "EG2 — tool args and tool-result re-entry" do
    test "tool args resolved from a vault-routed binding reach the provider MASKED (refutable)",
         %{rec: rec, field: field} do
      # The :tenant plane is the REFUTABLE plane: own-org PII is own-org-CLEAR in the UI, and
      # the vault double + repo are wired here — so this control shows the fixture genuinely
      # CAN produce the canary...
      assert [clear] = PiiResolution.resolve([rec], @res, %{plane: :tenant}, vault_wired())
      assert Map.get(clear, field) == @canary

      # ...which means the ONLY thing keeping the canary out of these tool args is ADR-043 §6.1
      # egress mode. Bypass/delete egress mode and the canary lands in the tool args at the
      # provider — this assertion flips.
      assert {:ok, %Completion{}} =
               Chokepoint.complete(
                 Provider.Fake,
                 %{},
                 :complete,
                 [~s(tool_call: account_lookup), "tool_args.contact_email="],
                 [actor: %{plane: :tenant}, bindings: [{[rec], @res}]] ++ vault_wired()
               )

      recorded = recorded_text()

      assert recorded =~ "tool_call: account_lookup", "the tool call itself must transmit"
      assert recorded =~ mask(), "the tool-arg vault value must be present-but-masked (••••)"
      refute recorded =~ @canary, "EG2 tool-args canary PLAINTEXT reached the provider"
      refute recorded =~ "vt_", "EG2 tool-args vt_ token reached the provider"
    end

    test "hand-assembled tool args (tuple / keyword / map) are REFUSED fail-closed" do
      # The fail-CLOSED scrub allowlist: an un-rendered STRUCTURED segment is never provably
      # safe, so it refuses — with or without a sentinel inside. Before the allowlist, every
      # shape here fell through to "safe" and a RAW vault token egressed to the provider.
      shapes = [
        # the live repro: a raw vault FK token in a tool-arg tuple
        {:account_token, @vt_token},
        # the same as a keyword arg list
        [account_token: @vt_token],
        # a tuple wrapping an UN-RENDERED %Masked{} (what a lazy assembler produces)
        {:contact_email, Masked.new(@vt_token, :emails)},
        # a JSON-ish tool-arg map
        %{"account_token" => @vt_token},
        # nested one level deeper
        ["prefix", {:account_token, @vt_token}],
        # and a sentinel-FREE structured arg: un-rendered is still not provably safe
        {:account_token, "acct-42"}
      ]

      for shape <- shapes do
        assert Chokepoint.complete(Provider.Fake, %{}, :complete, [shape], []) ==
                 {:error, :pii_egress_refused},
               "EG2: an un-rendered tool-args segment must REFUSE: #{inspect(shape)}"
      end

      assert Provider.Fake.sent_payloads() == [],
             "EG2: a refused tool-args payload must NEVER reach the provider"
    end

    test "a RAW structured tool RESULT re-entering a later prompt is refused, never passed through" do
      # §3.1 EG2: "results re-scrubbed on re-entry". A tool returns structured data; re-entering
      # it un-rendered means the assembler skipped §3.2 step 1 — refuse rather than transmit.
      assert Chokepoint.seal(:complete, ["turn N+1: use the tool result"],
               history: [%{"contact_email" => @vt_token}, {:tool_result, @vt_token}]
             ) == {:error, :pii_egress_refused}
    end

    test "a granted tool RESULT re-enters MASKED once the grant is gone (§3.1 EG2 + §3.2a)",
         %{rec: rec, op: op, ctx: ctx, grant_on: grant_on} do
      # Turn N: the tool ran under a live grant + host opt-in, so its result legitimately
      # carried plaintext into the ephemeral completion (positive control).
      assert {:ok, turn_n} =
               Chokepoint.seal(
                 :complete,
                 ["tool_result: account_lookup ->"],
                 [actor: op, bindings: [{[rec], @res}]] ++ grant_on
               )

      assert @canary in turn_n.segments

      # Turn N+1: that tool result re-enters as history with the grant gone ⇒ re-scrubbed.
      assert {:ok, turn_n1} =
               Chokepoint.seal(:complete, ["summarize the tool result"],
                 actor: op,
                 history: [{:grant_span, @canary, ctx}],
                 grant_egress?: false
               )

      refute Enum.any?(turn_n1.segments, &(to_string(&1) =~ @canary)),
             "EG2: a tool result re-entered with its prior-turn plaintext"

      assert mask() in turn_n1.segments
    end
  end

  # --------------------------------------------------------------------------------------
  # §6.1 — masked-by-default on EVERY plane; grant OFF masks even a grant-holder

  describe "§6.1 — egress is masked-by-default on every plane" do
    test "even the :tenant plane (own-org-clear in the UI) is masked at AI egress",
         %{rec: rec, field: field} do
      # Refutability first (this test used to pass even with egress mode DELETED, because no
      # vault/repo was wired so the tenant plane could not decrypt anyway): wire the vault
      # double + repo, and prove the tenant plane's own-org-clear read really does resolve the
      # canary. The masked assertions below therefore refute — bypass §6.1 egress mode and the
      # :tenant leg transmits the canary.
      assert [clear] = PiiResolution.resolve([rec], @res, %{plane: :tenant}, vault_wired())
      assert Map.get(clear, field) == @canary, "the :tenant own-org-clear control is vacuous"

      for plane <- [:tenant, :operator, nil] do
        assert {:ok, payload} =
                 Chokepoint.seal(
                   :complete,
                   [],
                   [actor: %{plane: plane}, bindings: [{[rec], @res}]] ++ vault_wired()
                 )

        assert mask() in payload.segments
        refute Enum.any?(payload.segments, &(to_string(&1) =~ @canary))
        refute Enum.any?(payload.segments, &(to_string(&1) =~ "vt_"))
      end
    end

    test "grant OFF (default): even a grant-holding actor's PII is masked (no plaintext egress)",
         %{rec: rec, op: op} do
      # Flag OFF but an approving grant + a working vault double present: the flag is the gate,
      # so the field STILL masks (the grant governs UI reveals, not egress — §6.1).
      assert {:ok, payload} =
               Chokepoint.seal(:complete, [], actor: op,
                 bindings: [{[rec], @res}],
                 grant_egress?: false,
                 grant: AllowGrantForEgress,
                 vault: VaultStubForEgress,
                 repo: :fake_repo
               )

      refute Enum.any?(payload.segments, &(&1 == @canary))
      assert mask() in payload.segments
    end
  end

  # --------------------------------------------------------------------------------------
  # EG3 — embeddings deny-by-default (grants never unlock embedding, §7.2 / RP-AI-4)

  test "EG3 — embedding a vault-routed field is REFUSED fail-closed, even with a grant",
       %{rec: rec, grant_on: grant_on} do
    assert {:error, :pii_egress_refused} =
             Chokepoint.embed(Provider.Fake, %{}, [], [bindings: [{[rec], @res}]] ++ grant_on)

    assert Provider.Fake.sent_payloads() == [], "a refused embed must NEVER reach the provider"
  end

  # --------------------------------------------------------------------------------------
  # EG4 — MCP payloads mask vault fields; grants never apply (persisted/external egress)

  test "EG4 — an :mcp payload masks vault fields and never egresses the canary, even with a grant",
       %{rec: rec, op: op, grant_on: grant_on} do
    assert {:ok, payload} =
             Chokepoint.seal(:mcp, ["browse: account overview"],
               [actor: op, bindings: [{[rec], @res}]] ++ grant_on
             )

    refute Enum.any?(payload.segments, &(to_string(&1) =~ @canary))
    refute Enum.any?(payload.segments, &(to_string(&1) =~ "vt_"))
    assert mask() in payload.segments
  end

  # --------------------------------------------------------------------------------------
  # RP-AI-2 — fail-closed on un-maskable content (refuse, never pass-what-you-don't-recognize)

  describe "RP-AI-2 — fail-closed refusal of un-maskable content" do
    test "a raw %Masked{}, a vt_ token, and a malformed binding are all refused" do
      assert {:error, :pii_egress_refused} =
               Chokepoint.seal(:complete, [Masked.new(@vt_token, :emails)], [])

      assert {:error, :pii_egress_refused} = Chokepoint.seal(:complete, [@vt_token], [])
      assert {:error, :pii_egress_refused} = Chokepoint.seal(:complete, ["leak: #{@vt_token}"], [])

      # A binding that is not an explicit {records, resource} pair is an assembler bug — refuse
      # rather than guess (fail-closed, not pass-what-you-don't-recognize).
      assert {:error, :pii_egress_refused} =
               Chokepoint.seal(:complete, ["ok"], bindings: [:not_a_pair])
    end

    test "an adversarial/malformed binding RETURNS the payload-free refusal — it never RAISES" do
      # These used to raise ArgumentError out of Samen.Pii.Info (`{[], nil}`, `{[], Enum}`):
      # fail-safe for the wire, but not the contract — and an exception message/stack trace is
      # itself an EG6 egress (§3.2b). Every shape must degrade to {:error, :pii_egress_refused}.
      malformed = [
        {[], nil},
        {[], Enum},
        {[], "SamenCore.Support.RevealDomain.RevealPerson"},
        {[], %{}},
        # right resource, WRONG records: bare maps / strings are not structs of the resource
        {[%{emails: @vt_token}], @res},
        {["not a record"], @res},
        {[nil], @res},
        :not_a_pair,
        {[]},
        {[], @res, :extra},
        %{records: [], resource: @res},
        nil,
        "bindings"
      ]

      for binding <- malformed do
        assert Chokepoint.seal(:complete, ["ok"], bindings: [binding]) ==
                 {:error, :pii_egress_refused},
               "a malformed binding must refuse (never raise): #{inspect(binding)}"
      end

      # Positive control: the WELL-formed binding of the same resource still seals.
      assert {:ok, _} =
               Chokepoint.seal(:complete, ["ok"],
                 bindings: [{[struct(@res, id: "22222222-2222-2222-2222-222222222222")], @res}]
               )
    end

    test "free text (user keystrokes) passes — INV-7 governs vault values, not consent (§3.2)" do
      # The honest boundary (§3.2 step 2): a user typing their own question is the same consent
      # class as typing it into a support reply. It is still scanned for vt_/%Masked{} (above).
      prompt = "What is the balance for John Smith, ssn 000-11-2222?"
      assert {:ok, payload} = Chokepoint.seal(:complete, [prompt], [])
      assert prompt in payload.segments
    end
  end

  # --------------------------------------------------------------------------------------
  # RP-AI-10 — multi-turn accumulation: a grant-tagged span re-masks in an ungranted turn

  describe "RP-AI-10 — the §3.2a multi-turn re-scrub" do
    test "a canary revealed under grant in turn N is RE-MASKED in the ungranted turn N+1",
         %{rec: rec, op: op, ctx: ctx, grant_on: grant_on} do
      # Turn N: grant ON → the canary plaintext is admitted (positive control).
      assert {:ok, turn_n} =
               Chokepoint.seal(:complete, ["turn N: reveal the account contact"],
                 [actor: op, bindings: [{[rec], @res}]] ++ grant_on
               )

      assert @canary in turn_n.segments

      # Turn N+1: the accumulated history (incl. the prior assistant echo of the canary) is a
      # grant-tagged span; the current turn LACKS the grant (flag now off) → the span re-masks.
      history = [{:grant_span, @canary, ctx}]

      assert {:ok, turn_n1} =
               Chokepoint.seal(:complete, ["turn N+1: summarize"],
                 actor: op,
                 history: history,
                 grant_egress?: false
               )

      refute Enum.any?(turn_n1.segments, &(to_string(&1) =~ @canary)),
             "RP-AI-10: an expired-grant turn leaked the accumulated canary"

      assert mask() in turn_n1.segments
    end

    test "a grant-tagged span also re-masks when the flag is on but the grant is now DENIED",
         %{ctx: ctx, op: op} do
      history = [{:grant_span, @canary, ctx}]

      assert {:ok, payload} =
               Chokepoint.seal(:complete, ["next turn"],
                 actor: op,
                 history: history,
                 grant_egress?: true,
                 grant: DenyGrantForEgress
               )

      refute Enum.any?(payload.segments, &(to_string(&1) =~ @canary))
      assert mask() in payload.segments
    end

    test "a grant-span whose context is NOT a %Reveal.Context{} RE-MASKS (never retained)",
         %{op: op} do
      # Fail-CLOSED §3.2a: the tag claims grant-resolved plaintext, but THIS turn cannot
      # re-check the grant that admitted it (the context is unparseable), so the span cannot be
      # validated ⇒ re-mask. Retaining the prior turn's plaintext because the tag was malformed
      # is fail-OPEN. Run under the MOST permissive config (flag ON + an approving checker) so
      # only the context validation can be doing the work.
      for bogus_ctx <- [nil, :expired, %{subject_id: "x", label: :emails}, {:ctx, "raw"}, "ctx"] do
        assert {:ok, payload} =
                 Chokepoint.seal(:complete, ["turn N+1: summarize"],
                   actor: op,
                   history: [{:grant_span, @canary, bogus_ctx}],
                   grant_egress?: true,
                   grant: AllowGrantForEgress
                 )

        refute Enum.any?(payload.segments, &(to_string(&1) =~ @canary)),
               "a malformed grant-span retained prior-turn plaintext: #{inspect(bogus_ctx)}"

        assert mask() in payload.segments
      end
    end

    test "a grant checker that RAISES is not a grant — the span re-masks, seal never raises",
         %{ctx: ctx, op: op} do
      assert {:ok, payload} =
               Chokepoint.seal(:complete, ["next turn"],
                 actor: op,
                 history: [{:grant_span, @canary, ctx}],
                 grant_egress?: true,
                 grant: RaisingGrantForEgress
               )

      refute Enum.any?(payload.segments, &(to_string(&1) =~ @canary))
      assert mask() in payload.segments
    end
  end

  # --------------------------------------------------------------------------------------
  # EG6 — logs / telemetry / errors carry no content (RP-AI-9, §3.2b)

  describe "EG6 — the observability shadow carries no canary or vt_" do
    test "a refusal is payload-free and a naive log line of the payload/error cannot spill",
         %{rec: rec, op: op} do
      # Payload-free refusal: the error term names no content.
      assert {:error, :pii_egress_refused} = Chokepoint.seal(:complete, [@vt_token], [])

      # A rich adapter error that tries to echo the canary is normalized to a content-free term.
      assert {:error, {:provider_error, Provider.Fake}} =
               Chokepoint.complete(Provider.Fake, %{error: {:boom, @canary}}, :complete, ["p"], [])

      {:ok, payload} =
        Chokepoint.seal(:complete, ["ctx"], actor: op, bindings: [{[rec], @res}])

      log =
        capture_log(fn ->
          Logger.error("ai egress: payload=#{inspect(payload)} refusal=#{inspect({:error, :pii_egress_refused})}")
        end)

      refute log =~ @canary
      refute log =~ "vt_"
    end

    test "a telemetry event carrying the sealed payload as metadata cannot spill it",
         %{rec: rec, op: op} do
      {:ok, payload} =
        Chokepoint.seal(:complete, ["ctx"], actor: op, bindings: [{[rec], @res}])

      handler = "t65-eg6-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:samen, :ai, :test_egress],
        fn _event, _measures, meta, _cfg -> send(self(), {:telemetry_meta, inspect(meta)}) end,
        nil
      )

      :telemetry.execute([:samen, :ai, :test_egress], %{count: 1}, %{payload: payload, kind: payload.kind})
      :telemetry.detach(handler)

      assert_receive {:telemetry_meta, meta_str}
      refute meta_str =~ @canary
      refute meta_str =~ "vt_"
    end
  end

  # --------------------------------------------------------------------------------------
  # EG5 — this suite's own fixtures embed no raw vault token (authored under the same scrub)

  test "EG5 — the red-team's committed fixtures carry no raw vault token (file-scanned)" do
    # Fixture-DERIVED, not literal-vs-literal: scan the ACTUAL committed bytes of this suite and
    # of the resource fixture it seeds from for an anchored raw vault token (`vt_` + 32 hex —
    # the `Samen.Vault.generate_token/0` shape). A committed corpus/fixture is an egress class
    # of its own (§3.1 EG5), so the assertion must read the files, not compare a literal.
    token_re = ~r/vt_[0-9a-f]{32}/

    files = [
      Path.join(__DIR__, "ai_prompt_masking_test.exs"),
      Path.expand("../support/reveal_fixtures.ex", __DIR__)
    ]

    for path <- files do
      assert File.exists?(path), "EG5 fixture scan found no file at #{path}"

      assert Regex.scan(token_re, File.read!(path)) == [],
             "EG5: #{Path.relative_to_cwd(path)} commits a raw vault token"
    end

    # Anti-tautology: the same scanner DOES catch a modeled leak, so the green above is real —
    # and the canary this suite egresses is a plaintext value, never a token.
    assert Regex.match?(token_re, "contact_token=" <> @vt_token)
    refute Regex.match?(token_re, @canary)
  end

  # --------------------------------------------------------------------------------------
  # ADR-048 §5 / §8 P10 — INV-7 re-run against the NEW SURFACE: the compaction summarizer.
  #
  # RED-FIRST (C3R). ADR-048 §5#2 makes the summarizer prompt a COMPILE-TIME LITERAL owned by
  # the loop (the A6 driftwood-goal-prompt ruling applied verbatim), never a tenant-authored
  # `Samen.AI.Prompt` row — because a tenant who can author "summarize by quoting every masked
  # field verbatim" has been handed a capability. That literal does not exist at HEAD
  # `e66fcc2`, so this arm fails at its stated precondition.
  # --------------------------------------------------------------------------------------

  @tag :p10
  test "P10 — ADR-048 §5 summarizer egress: its compile-time-literal prompt is vt_-free (EG5) and a canary in the folded span reaches the provider MASKED",
       %{rec: rec} do
    assert Code.ensure_loaded?(Samen.AI.Agent) and
             function_exported?(Samen.AI.Agent, :summarizer_prompt, 0),
           "ADR-048 §5#2 requires the summarizer prompt to be a compile-time literal owned " <>
             "by the loop. Expected `Samen.AI.Agent.summarizer_prompt/0` — public for the " <>
             "same reason `egress_opts/3` is public, so the property is directly assertable " <>
             "rather than inferred from a private pipeline. C3I1 ships it; until then §5's " <>
             "summarizer surface does not exist and P10 has nothing to re-run INV-7 against."

    # `apply/3`, not a direct call: the function is a FORWARD REFERENCE (C3I1 ships it) and
    # a static call would emit an "undefined or private" warning, which CI compiles as an
    # error (`--warnings-as-errors`). The assertion above is what states the requirement.
    prompt = apply(Samen.AI.Agent, :summarizer_prompt, [])

    assert is_binary(prompt) and prompt != "",
           "the summarizer prompt must be a non-empty compile-time binary (ADR-048 §5#2)"

    refute prompt =~ "vt_", "EG5: the summarizer prompt commits a raw vault token"

    # The span the summarizer reads is ORDINARY already-masked history (§5#1: "its input is
    # already-masked history, so no new egress class opens"), sealed through the SAME
    # chokepoint with the SAME allowlist.
    span = [prompt, "[folded: turns 1-2 -> fold #1]", "tool_result: contact_email="]

    # The allowlist half of §5#1, asserted directly: a caller cannot re-enable grant
    # plaintext on the summarize path, because `grant_egress?: false` is appended LAST.
    opts = Samen.AI.Agent.egress_opts([grant_egress?: true], span, [])

    assert List.last(opts) == {:grant_egress?, false},
           "`grant_egress?: false` is not pinned LAST on the loop's egress opts — a " <>
             "caller-supplied override could re-open grant plaintext on the summarize path"

    assert {:ok, %Completion{}} =
             Chokepoint.complete(
               Provider.Fake,
               %{},
               :complete,
               span,
               [actor: %{plane: :tenant}, bindings: [{[rec], @res}]] ++ vault_wired()
             )

    recorded = recorded_text()

    # Non-vacuous, three ways: the summarizer prompt DID transmit, the vault-routed field
    # DID egress (as `••••`, so this is masking and not omission), and — per the sibling
    # EG2 arm above — the same fixture on the same plane genuinely resolves the canary.
    assert recorded =~ prompt, "the summarizer prompt itself never reached the provider"
    assert recorded =~ mask(), "the vault-routed field was omitted, not masked"

    refute recorded =~ @canary,
           "the canary PLAINTEXT reached the provider on ADR-048 §5's summarizer surface"

    refute recorded =~ "vt_",
           "a vault token reached the provider on ADR-048 §5's summarizer surface"
  end

  # --------------------------------------------------------------------------------------

  # All %MaskedPayload{} segments the Fake was sent this process, flattened to a scannable
  # string (the honest provider-side recording — a leak that reaches the provider is here).
  defp recorded_text do
    Provider.Fake.sent_payloads()
    |> Enum.flat_map(fn {_callback, payload} -> Enum.map(payload.segments, &seg_to_string/1) end)
    |> Enum.join("\n")
  end

  defp seg_to_string(seg) when is_binary(seg), do: seg
  defp seg_to_string(seg), do: inspect(seg)

  # The decrypt path WIRED (keyless vault double + a repo), with NO grant opt-in. This is what
  # makes the masked assertions refutable: the tenant plane's own-org-clear read genuinely
  # resolves the canary through these opts, so only §6.1 egress mode keeps it out of a payload.
  defp vault_wired, do: [vault: VaultStubForEgress, repo: :fake_repo]
end
