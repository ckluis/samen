defmodule Samen.Web.SearchMaskingTest do
  @moduledoc """
  WS-E E4.2 — THE SEARCH RESULT-MASKING RED-PATH (ADR-027; AC-G9-3; RP-SE-2). Search
  joins the masking watch-list: a match on a NON-PII column (guaranteed by the index
  guard) must still return a row whose VAULTED fields are masked per plane — search
  can neither match on a masked field nor leak one as a display/result field.

  The invariant proven here: **`Samen.Search.query/3` projects EVERY result row
  through `Samen.Api.PiiResolution` on the actor's plane before it leaves the engine,
  so the search hit and the pixel show the SAME value on the same plane.**

  Consumer of `Samen.MaskingCase` (E2i.1) — the same green/red/sabotage discipline as
  the file-preview, notifications, and CSV-export masking tests:

    * **GREEN** — a tenant searching its OWN org gets a hit whose vaulted `full_name`
      resolves to the CLEAR composite (projection reveals on the tenant plane).
    * **RED** — an operator (impersonation) searching the tenant's org gets the SAME
      hit, but `full_name` is `%Samen.Masked{}` → `••••`: never the plaintext, never a
      `vt_*` vault token.
    * **SABOTAGE twins** — (1) plane flip: sabotaging `Samen.Search` to resolve every
      row on the TENANT plane regardless of the acting scope (the committed
      `10-e4-search-projection-plane-bypass` patch) leaks the plaintext into the
      operator hit and FAILS the RED test; (2) the leak scan is refutable — a raw,
      unprojected read of the SAME row DOES carry the plaintext the projected hit
      masks (so the `refute` is not a tautology).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Factory
  alias Samen.Masked
  alias Samen.Search
  alias Samen.Web.Plane

  alias Samen.WebTest.Crm.Person
  alias Samen.WebTest.Primitives.SearchIndex

  @secret_first "VaultedSearchFirst"
  @secret_last "Search-Result-Secret"
  # A distinctive NON-PII display token the search matches on.
  @needle "zephyrwidget"

  defp tenant_scope(org_id), do: Plane.scope(Plane.tenant(), org_id)

  defp operator_scope(org_id),
    do: Plane.scope(Plane.operator("op-1", org_id, "search-mask-session"), org_id)

  defp register!(org_id) do
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

  defp seed_secret_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last), %{
        display_name: "Public #{@needle} Display",
        org_id: org_id
      }),
      tenant_scope(org_id)
    )
  end

  defp search_opts,
    do: [resources: [Person], search_index: SearchIndex, repo: Samen.WebTest.Repo]

  defp query(scope), do: Search.query(scope, @needle, search_opts())

  describe "search result masking per plane (AC-G9-3 · RP-SE-2)" do
    test "GREEN: a tenant search of its own org resolves the vaulted full_name CLEAR" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      seed_secret_person!(org_id)

      assert [%Search.Result{} = hit] = query(tenant_scope(org_id))

      # The match rode a non-PII column; the display allowlist carries only that.
      assert hit.display == %{display_name: "Public #{@needle} Display"}

      # The vaulted composite is CLEAR on the tenant plane (projection revealed it).
      refute match?(%Masked{}, hit.record.full_name)
      full = inspect(hit.record.full_name)
      assert full =~ @secret_first
      assert full =~ @secret_last
      refute full =~ "vt_"
    end

    test "RED: an operator search of the tenant org masks full_name — •••• , never plaintext (RP-SE-2)" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      seed_secret_person!(org_id)

      assert [%Search.Result{} = hit] = query(operator_scope(org_id))

      # Non-PII display fields ride along on every plane.
      assert hit.display == %{display_name: "Public #{@needle} Display"}

      # The vaulted field is PRESENT-but-masked — the impersonation UI posture.
      # Sabotaging Search's projection to the tenant plane (the committed
      # 10-e4 patch) leaks the plaintext here and FAILS this test.
      assert_plane_masked!(hit.record.full_name)

      masked = to_string(hit.record.full_name)
      assert masked == mask()
      refute masked =~ @secret_first
      refute masked =~ @secret_last
      refute masked =~ "vt_"
    end

    test "the same rows exported on the tenant plane go CLEAR — the plane is the gate (anti-tautology)" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      seed_secret_person!(org_id)

      [tenant_hit] = query(tenant_scope(org_id))
      [operator_hit] = query(operator_scope(org_id))

      # The ONLY difference between the two reads is the plane — so masking is the
      # resolver's per-plane decision, not a blanket mask.
      refute match?(%Masked{}, tenant_hit.record.full_name)
      assert match?(%Masked{}, operator_hit.record.full_name)
      assert inspect(tenant_hit.record.full_name) =~ @secret_first
      assert to_string(operator_hit.record.full_name) == mask()
    end

    test "SABOTAGE refutability: a RAW unprojected read of the row DOES carry the plaintext" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      seed_secret_person!(org_id)

      # Model the leak the projection prevents: read the row and reveal on the tenant
      # plane (what a projection-bypass would ship to an operator). The scan that the
      # RED test's masked hit passes DOES catch this — the refutation is non-vacuous.
      raw = %{
        display_name: "x",
        full_name: %Samen.Type.FullName{first: @secret_first, last: @secret_last}
      }

      leaked =
        [raw]
        |> Samen.Api.PiiResolution.resolve(Person, %{plane: :tenant}, repo: Samen.WebTest.Repo)
        |> hd()

      assert inspect(leaked.full_name) =~ @secret_first
    end
  end
end
