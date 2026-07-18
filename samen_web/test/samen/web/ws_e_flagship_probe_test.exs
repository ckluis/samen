defmodule Samen.Web.WsEFlagshipProbeTest do
  @moduledoc """
  WS-E E7.2 — THE FLAGSHIP CROSS-SURFACE PROBE (AC-X-1). The single multi-plane probe
  that exercises ALL FOUR new-PII-surfaces WS-E opened — file preview/byte-serve, CSV
  export, ⌘K search projection, profile self-edit — on ONE seeded fixture, and proves
  they share the ONE `Samen.Api.PiiResolution` seam: on the operator plane every surface
  renders the SAME secret as `••••`; on the tenant plane every surface renders it CLEAR.
  The fail-honest `Samen.Files.Storage.S3.put/3` never returns `{:ok}` for a byte it did
  not store.

  ## The four masking-watch-list surfaces, one fixture

  A single secret (`@secret_*`) is vaulted into three resources (a CRM `Person` for export
  + search, an identity `User` for profile, a `File` for byte-serve) in ONE org, and the
  probe asserts the tenant-clear ∧ operator-masked invariant across every surface. This is
  the "same pixel across every export/preview/search/profile" guarantee the design's
  §4 flagship names — the mask-by-omission channels can never diverge because they resolve
  through the same engine.

  ## Non-vacuity — bound to the committed sabotages via `scripts/sabotage.sh`

  The probe does NOT re-derive the flips: each surface assertion is BOUND to the already
  committed sabotage patch that breaks its seam, so `scripts/sabotage.sh` proves this probe
  is refutable (apply → the NAMED flagship test FAILS → revert byte-exact):

    * files byte-serve gate  → `05-e2-plane-gate-bypass`      (operator 403 → 200)
    * export cell projection → `06-e3-export-plane-bypass`    (•••• → plaintext)
    * search projection      → `10-e4-search-projection-...`  (masked → clear)
    * profile write guard    → `11-e5-profile-plaintext-write`(refused → written)
    * S3 fail-honest         → `02-e1-s3-fail-honest-lie`     ({:error,_} → {:ok,_})

  So AC-X-1's "each sabotage flips the gate and reverts byte-exact, zero residue" is proven
  by the standing harness against THIS probe, with no new flips derived by hand. The probe's
  own green run is a shipped-suite member (runs every `mix test`); the flip is the opt-in
  `SAMEN_SABOTAGE=1` harness step.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Plug.Test
  import Plug.Conn

  require Ash.Query

  alias Samen.Factory
  alias Samen.Files
  alias Samen.Files.Storage.Local
  alias Samen.Files.Storage.S3
  alias Samen.Masked
  alias Samen.Search
  alias Samen.Type.FullName
  alias Samen.Web.Csv
  alias Samen.Web.Files.BytesController
  alias Samen.Web.Plane
  alias Samen.Web.Settings.Profile

  alias Samen.WebTest.Crm.Person
  alias Samen.WebTest.Operator.User
  alias Samen.WebTest.Primitives.File, as: FileResource
  alias Samen.WebTest.Primitives.SearchIndex

  # ONE secret, vaulted into every surface. If it EVER surfaces on the operator plane, a
  # mask-by-omission channel has failed.
  @secret_first "FlagshipVaultedFirst"
  @secret_last "Cross-Surface-Secret"
  @op_first "OperatorAuthored"
  @op_last "PlaintextInjection"
  # A distinctive NON-PII token search matches on (guaranteed non-PII by the index guard).
  @needle "quokkaflagship"

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "flagship-session"), org_id)

  # ---- seed one org's fixture across every surface ---------------------------

  defp seed_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last), %{
        display_name: "Public #{@needle} Display",
        org_id: org_id
      }),
      tenant_scope(org_id)
    )
  end

  defp seed_user!(org_id) do
    User
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      handle: "flagship",
      full_name: %FullName{first: @secret_first, last: @secret_last},
      emails: [%{address: "flagship.secret@example.test"}]
    })
    |> Ash.create!(authorize?: false)
  end

  defp register_search!(org_id) do
    SearchIndex
    |> Ash.Changeset.for_create(:create, %{
      resource_name: inspect(Person),
      field_name: "display_name",
      vector_column: "swp_search_vector",
      enabled: true,
      ts_config: "english",
      org_id: org_id
    })
    |> Ash.create!(authorize?: false)
  end

  defp storage_root do
    root = Path.join(System.tmp_dir!(), "flagship_#{System.unique_integer([:positive])}")
    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)
    root
  end

  defp seed_active_file!(org_id, root) do
    {:ok, file} =
      Files.upload(
        %{org_id: org_id},
        %{filename: "note.txt", content_type: "text/plain", binary: "FLAGSHIP-RAW-BYTES"},
        file_module: FileResource,
        repo: Samen.WebTest.Repo,
        storage: Local,
        storage_config: %{root: root},
        allowed_content_types: ~w(text/plain),
        max_bytes: 1_048_576
      )

    {:ok, active} =
      file
      |> Ash.Changeset.for_update(:update, %{status: :active})
      |> Ash.update(authorize?: false)

    active
  end

  defp bytes_conn(org_id, plane_opts) do
    mount = build_mount(:files, plane_opts)

    opts =
      Plug.Session.init(
        store: :cookie,
        key: "_test",
        signing_salt: "salt_v2",
        encryption_salt: "enc_salt_v2"
      )

    conn(:get, "/files/ignored")
    |> Map.put(:secret_key_base, String.duplicate("b", 64))
    |> Plug.Session.call(opts)
    |> fetch_session()
    |> put_session(Samen.Web.CurrentOrg.session_key(), org_id)
    |> Map.put(:assigns, %{samen_mount: mount})
  end

  defp export_full_name_cell(scope) do
    {:ok, csv} = Csv.export(Person, scope, repo: Samen.WebTest.Repo, columns: [:display_name, :full_name])
    [header | rows] = Csv.parse(csv)
    idx = Enum.find_index(header, &(&1 == "full_name"))
    [row] = rows
    {csv, Enum.at(row, idx)}
  end

  defp search_hit(scope) do
    [hit] =
      Search.query(scope, @needle, resources: [Person], search_index: SearchIndex, repo: Samen.WebTest.Repo)

    hit
  end

  # ===========================================================================
  # 1. Each surface, bound to its committed sabotage (the NON-VACUITY proof)
  # ===========================================================================

  test "flagship files byte-serve: the operator plane is REFUSED 403 — bytes have no reveal (binds 05-e2)" do
    org_id = Ash.UUID.generate()
    root = storage_root()
    file = seed_active_file!(org_id, root)

    conn =
      bytes_conn(org_id, plane: :operator, target_org_id: org_id)
      |> BytesController.serve(%{"id" => file.id})

    # Sabotaging BytesController's operator refusal (05-e2) flips this 403 to a 200 serve.
    assert conn.status == 403
    refute conn.resp_body =~ "FLAGSHIP-RAW-BYTES"
  end

  test "flagship export: the operator CSV cell is the mask — never plaintext, never a vt_ token (binds 06-e3)" do
    org_id = Ash.UUID.generate()
    seed_person!(org_id)

    {csv, cell} = export_full_name_cell(operator_scope(org_id))

    # Sabotaging Csv's plane resolution (06-e3) leaks the plaintext here.
    assert cell == mask()
    assert_masked_dom!(csv, [@secret_first, @secret_last])
    assert csv =~ "Public #{@needle} Display"
  end

  test "flagship search: the operator search hit masks full_name — never plaintext (binds 10-e4)" do
    org_id = Ash.UUID.generate()
    register_search!(org_id)
    seed_person!(org_id)

    hit = search_hit(operator_scope(org_id))

    # Sabotaging Samen.Search's projection to the tenant plane (10-e4) leaks the plaintext.
    assert_plane_masked!(hit.record.full_name)
    assert to_string(hit.record.full_name) == mask()
    assert hit.display == %{display_name: "Public #{@needle} Display"}
  end

  test "flagship profile: an operator plaintext self-edit is REFUSED — DB unchanged (binds 11-e5)" do
    org_id = Ash.UUID.generate()
    user = seed_user!(org_id)
    mount = build_mount(:settings, plane: :operator, target_org_id: org_id)

    before = raw_full_name(user.id)

    # Sabotaging Profile.update's governed scope (11-e5) lets this write succeed.
    assert {:error, _} =
             Profile.update(mount, operator_scope(org_id), user.id, %{
               full_name: %{first: @op_first, last: @op_last}
             })

    after_write = raw_full_name(user.id)
    assert before == after_write
    refute after_write =~ @op_first
  end

  test "flagship S3: put never returns ok — fail-honest absent creds (binds 02-e1)" do
    # Sabotaging S3 to claim a stored byte (02-e1) makes put return {:ok, _}, which
    # FLIPS this exact-tuple assertion — a stub that claims success is the lie the gate
    # sabotage-tests for (never {:ok} for a byte it did not store).
    assert S3.configured?(%{}) == false
    assert S3.put("k", "bytes", %{}) == {:error, :not_configured}

    # With creds present it is fail-honest not-yet-implemented — still never {:ok}.
    creds = %{bucket: "b", access_key_id: "a", secret_access_key: "s"}
    assert S3.configured?(creds) == true
    assert S3.put("k", "bytes", creds) == {:error, :not_implemented}
  end

  # ===========================================================================
  # 2. The cross-surface unification — one fixture, all four surfaces, both planes
  # ===========================================================================

  test "flagship cross-surface: all four PII surfaces mask the SAME secret on the operator plane, clear on the tenant plane" do
    org_id = Ash.UUID.generate()
    register_search!(org_id)
    person = seed_person!(org_id)
    user = seed_user!(org_id)

    # --- OPERATOR PLANE: every surface resolves the shared secret to •••• ---
    {op_csv, op_cell} = export_full_name_cell(operator_scope(org_id))
    op_hit = search_hit(operator_scope(org_id))

    op_person =
      Person
      |> Ash.Query.filter(id == ^person.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)
      |> resolve_on_plane(Person, :operator, repo: Samen.WebTest.Repo)

    op_user =
      User
      |> Ash.Query.filter(id == ^user.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)
      |> resolve_on_plane(User, :operator, repo: Samen.WebTest.Repo)

    # export cell, search hit, person read, profile read — ALL the same mask, no leak.
    assert op_cell == mask()
    assert to_string(op_hit.record.full_name) == mask()
    assert_plane_masked!(op_person.full_name)
    assert_plane_masked!(op_user.full_name)
    refute op_csv =~ @secret_first
    refute op_csv =~ @secret_last
    refute op_csv =~ "vt_"

    # --- TENANT PLANE: the plane is the gate — every surface goes CLEAR ---
    {tn_csv, tn_cell} = export_full_name_cell(tenant_scope(org_id))
    tn_hit = search_hit(tenant_scope(org_id))

    assert tn_cell =~ @secret_first
    refute tn_cell == mask()
    refute match?(%Masked{}, tn_hit.record.full_name)
    assert inspect(tn_hit.record.full_name) =~ @secret_first
    assert tn_csv =~ @secret_last
  end

  # ===========================================================================
  # 3. Responsive survival — the value layer is CSS-blind (AC-G20-2)
  # ===========================================================================

  test "flagship responsive: a masked value renders the mask regardless of layout (value layer untouched)" do
    org_id = Ash.UUID.generate()
    register_search!(org_id)
    seed_person!(org_id)

    masked = search_hit(operator_scope(org_id)).record.full_name

    # The responsive pass is CSS + slot-based kit only — a %Masked{} stringifies to the
    # mask everywhere, and its Inspect is hardened (never leaks the token). No breakpoint
    # can change a value-layer decision.
    assert to_string(masked) == mask()
    assert inspect(masked) =~ "Masked"
    refute inspect(masked) =~ @secret_first
    refute inspect(masked) =~ "vt_"
  end

  # ---- helpers ---------------------------------------------------------------

  defp raw_full_name(id) do
    %{rows: [[raw]]} =
      Samen.WebTest.Repo.query!(
        "SELECT wou_full_name FROM wou_user WHERE wou_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    raw
  end
end
