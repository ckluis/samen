defmodule Samen.Replay.ReplayTierTest do
  @moduledoc """
  ADR-052 §2.4 (P4) — the replay tables under the `no_plaintext_pii` oracle.

    * `:replay` (CI mode): every stored frame passes the frame schema, every session row is what
      the kernel writes, and no referenced subject's vault plaintext — nor a seeded probe —
      appears in any replay row. Fails closed.
    * `:post_shred_replay` (the destruction oracle's `--subject --tiers all` roster): after a
      crypto-shred, every stored frame referencing the subject passes the schema and every
      reference resolves to `[erased]` on the plane that reads CLEAR; no seeded plaintext is in
      any replay row.

  Rows are written the two ways a database can get them: through the kernel
  (`Samen.Replay.Store`, the sanitizer's own output — the positive controls) and with raw SQL
  past the store and `RowGuard` (the red paths).
  """
  use ExUnit.Case, async: false

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.NoPlaintextPii.Tiers.PostShred
  alias Samen.NoPlaintextPii.Tiers.Replay, as: ReplayTier
  alias Samen.Replay.{Sanitizer, Store}
  alias SamenCore.Support.Clinical.Patient

  @repo SamenCore.TestRepo
  @first "Grace"
  @last "Hopperton"
  @mrn "MRN-TIER-4242"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)

    org = Ash.UUID.generate()
    patient = patient!(org)
    session = record!(org, patient)
    %{org: org, patient: patient, session: session}
  end

  # -- fixtures -------------------------------------------------------------------

  defp patient!(org) do
    p =
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        full_name: %{first: @first, last: @last},
        mrn: @mrn,
        dob: ~D[1906-12-09],
        consent_on_file: true
      })
      |> Ash.create!()

    # What a tenant LiveView holds: the record resolved CLEAR on the tenant plane.
    [read] =
      Patient
      |> Ash.Query.filter_input(%{id: p.id})
      |> Ash.Query.select(Patient |> Ash.Resource.Info.attribute_names() |> Enum.to_list())
      |> Ash.read!(authorize?: false)
      |> Samen.Api.PiiResolution.resolve(Patient, %{plane: :tenant, org_id: org}, repo: @repo)

    read
  end

  # A session persisted by the KERNEL: the sanitizer's own output for a view holding the
  # (clear) patient, through the store (frame schema + RowGuard).
  defp record!(org, patient) do
    assigns = Sanitizer.assigns(%{patient: patient, count: 2}, keep: [])

    {:ok, session} =
      Store.persist(
        %{
          org_id: org,
          actor_ref: nil,
          view: "SamenCore.Support.ReplayView",
          view_md5: nil,
          started_at: DateTime.utc_now()
        },
        [{1, 0, :mount, %{view: "SamenCore.Support.ReplayView", assigns: assigns}}],
        %{bytes: 0, interactions: 1, truncated: false, exit_reason: :normal}
      )

    session.id
  end

  # A frame written past the store and RowGuard.
  defp raw_frame!(org, session, seq, payload) do
    @repo.query!(
      "INSERT INTO replay_frame (rpf_session_id, rpf_org_id, rpf_seq, rpf_kind, rpf_at_ms, " <>
        "rpf_payload, rpf_inserted_at, rpf_updated_at) VALUES ($1, $2, $3, 'render', 9, $4, now(), now())",
      [Ecto.UUID.dump!(session), Ecto.UUID.dump!(org), seq, payload]
    )
  end

  defp ci(opts \\ []),
    do: ReplayTier.check(Context.build(Keyword.merge([repo: @repo, resources: []], opts)))

  defp post(subject, opts \\ []),
    do:
      PostShred.Replay.check(
        Context.build(Keyword.merge([repo: @repo, resources: [], subject_id: subject], opts))
      )

  defp violations(findings), do: NoPlaintextPii.violations(findings)

  # -- :replay (CI mode) ------------------------------------------------------------

  describe ":replay — CI mode" do
    test "POSITIVE CONTROL: kernel-written rows referencing a vault-routed record are clean",
         ctx do
      # The vault plaintext IS recoverable (the tier really has something to search for) …
      raw =
        @repo.query!("SELECT rpf_payload::text FROM replay_frame").rows
        |> List.flatten()
        |> Enum.join()

      assert raw =~ ctx.patient.id
      refute raw =~ @last

      # … and no row holds it.
      assert ci() == []
      assert ReplayTier in NoPlaintextPii.default_tiers()
      assert ReplayTier.tier_name() == :replay
    end

    test "RED: a frame holding a referenced subject's vault plaintext — even schema-valid — is a violation",
         ctx do
      # A `$kept` string passes the frame schema (label-shaped, not PII-shaped) — only the
      # vault-plaintext search can see it is the patient's surname.
      payload = %{
        "assigns" => %{
          "p" => %{
            "$ref" => %{
              "resource" => "SamenCore.Support.Clinical.Patient",
              "pk" => ctx.patient.id,
              "attribute" => "mrn"
            }
          },
          "title" => %{"$kept" => %{"value" => @last}}
        }
      }

      raw_frame!(ctx.org, ctx.session, 20, payload)

      assert :ok =
               Samen.Replay.FrameSchema.validate(%{
                 seq: 20,
                 at_ms: 9,
                 kind: "render",
                 payload: payload
               })

      assert [%Finding{severity: :violation, subject: "replay_frame[" <> _} = f] =
               violations(ci())

      assert f.detail =~ "plaintext of a subject"
      refute Finding.format(f) =~ @last
    end

    test "RED: a frame with a bare free string is a violation (its content never printed)", ctx do
      raw_frame!(ctx.org, ctx.session, 20, %{"assigns" => %{"name" => "Ada Lovelace"}})

      assert [f] = violations(ci())
      assert f.subject =~ "replay_frame["
      assert f.detail =~ "frame schema"
      refute Finding.format(f) =~ "Lovelace"
    end

    test "RED: a frame whose payload is not an object, or whose kind is outside the set, is a violation",
         ctx do
      raw_frame!(ctx.org, ctx.session, 20, ["x"])

      @repo.query!(
        "INSERT INTO replay_frame (rpf_session_id, rpf_org_id, rpf_seq, rpf_kind, rpf_at_ms, rpf_payload, " <>
          "rpf_inserted_at, rpf_updated_at) VALUES ($1, $2, 30, 'zz_kind', 1, '{}'::jsonb, now(), now())",
        [Ecto.UUID.dump!(ctx.session), Ecto.UUID.dump!(ctx.org)]
      )

      assert length(violations(ci())) == 2
    end

    test "RED: a session row carrying a name where the kernel writes identifiers is a violation",
         ctx do
      @repo.query!(
        "INSERT INTO replay_session (rps_org_id, rps_view, rps_actor_ref, rps_started_at, rps_inserted_at, " <>
          "rps_updated_at) VALUES ($1, 'Grace Hopperton', 'grace@example.com', now(), now(), now())",
        [Ecto.UUID.dump!(ctx.org)]
      )

      # Structural (not what the kernel writes) AND content (the patient's name is in the row).
      assert [f, content] = violations(ci())
      assert f.subject =~ "replay_session["
      assert f.detail =~ "view is not a module name"
      assert f.detail =~ "actor_ref"
      assert content.subject == f.subject
      assert content.detail =~ "plaintext of a subject"
      refute Finding.format(f) <> Finding.format(content) =~ "Hopperton"
    end

    test "a SEEDED probe is found wherever it sits, never printed", ctx do
      raw_frame!(ctx.org, ctx.session, 20, %{
        "assigns" => %{"t" => %{"$kept" => %{"value" => "Quillfeather"}}}
      })

      assert violations(ci()) == []
      assert [f] = violations(ci(plaintext_probes: ["Quillfeather"]))
      refute Finding.format(f) =~ "Quillfeather"
    end

    test "fail closed: no repo, and a KMS that cannot decrypt a referenced subject's rows" do
      assert [%Finding{severity: :violation}] =
               ReplayTier.check(%Context{
                 repo: nil,
                 resources: [],
                 vault_routed: MapSet.new(),
                 non_pii_exempt: MapSet.new(),
                 deps: []
               })

      Samen.Kms.FileBacked.simulate_outage(true)
      on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
      assert [f] = violations(ci())
      assert f.subject == "pii_vault"
      assert f.detail =~ "could not be decrypted"
    end

    test "probe matching: dates match exactly, ids are never a hit, otherwise case-insensitive substring" do
      probes =
        ReplayTier.probes_of([~s({"first":"Grace","last":"Hopperton"}), "1906-12-09", "ab"])

      assert Enum.sort(probes) == ["1906-12-09", "grace", "hopperton"]
      assert ReplayTier.hit?("Dr. HOPPERTON", probes)
      assert ReplayTier.hit?("1906-12-09", probes)
      refute ReplayTier.hit?("1906-12-09T10:00:00Z", probes)
      refute ReplayTier.hit?(Ash.UUID.generate(), ["grace"])
      refute ReplayTier.hit?("count", probes)
    end
  end

  # -- :post_shred_replay ---------------------------------------------------------------

  describe ":post_shred_replay — the destruction oracle" do
    test "after a crypto-shred every reference to the subject resolves to [erased] (a :pass)",
         ctx do
      {:ok, _} = Samen.Vault.shred(ctx.patient.id)

      findings = post(ctx.patient.id)
      assert violations(findings) == []
      assert [%Finding{severity: :pass, detail: detail}] = findings
      assert detail =~ "resolve to [erased]"
      assert PostShred.Replay in NoPlaintextPii.post_shred_tiers()
    end

    test "ANTI-TAUTOLOGY: the same check on a subject whose key was NOT destroyed is a violation",
         ctx do
      # The tenant plane reads CLEAR: a shred that did not take is plaintext, not a mask.
      assert [f] = violations(post(ctx.patient.id))
      assert f.detail =~ "do NOT resolve to [erased]"
      assert f.detail =~ "clear:"
      refute Finding.format(f) =~ @last
    end

    test "RED: a stored frame referencing the erased subject that fails the frame schema", ctx do
      {:ok, _} = Samen.Vault.shred(ctx.patient.id)

      raw_frame!(ctx.org, ctx.session, 20, %{
        "assigns" => %{"who" => "#{ctx.patient.id} #{@first} #{@last}"}
      })

      assert [f] = violations(post(ctx.patient.id))
      assert f.subject =~ "replay_frame["
      assert f.detail =~ "fails the replay frame schema"
    end

    test "RED: a seeded plaintext of the erased subject anywhere in a replay row", ctx do
      {:ok, _} = Samen.Vault.shred(ctx.patient.id)

      raw_frame!(ctx.org, ctx.session, 20, %{
        "assigns" => %{"t" => %{"$kept" => %{"value" => @last}}}
      })

      assert violations(post(ctx.patient.id)) == []
      assert [f] = violations(post(ctx.patient.id, plaintext_probes: [@mrn, @last]))
      assert f.detail =~ "seeded plaintext"
      refute Finding.format(f) =~ @last
    end

    test "speaks either way: no frame references the subject → a :pass, never silence" do
      assert [%Finding{severity: :pass, detail: detail}] = post(Ash.UUID.generate())
      assert detail =~ "no stored replay frame references"
    end
  end
end
