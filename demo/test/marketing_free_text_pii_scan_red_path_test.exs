defmodule Demo.MarketingFreeTextPiiScanRedPathTest do
  @moduledoc """
  F3 Unit 6 (carry): the TENANT free-text write chokepoint. `Samen.Pii.FreeTextScan` is
  wired on the Marketing `Suppression.notes` column (framework-first — every marketing
  mount inherits it). A note that is ITSELF a bare email/SSN/phone shape is REFUSED at the
  write path (fail-closed, DB unchanged) — the same value-shape belt that guards operator
  reasons, extended to a tenant freeform column outside the vault's crypto-shred guarantee
  (docs/free-text-pii-residue.md).

  Anti-tautology: the green control proves the guard does NOT reject ordinary notes; the
  red path proves a bare-PII note IS refused. (Sabotage 22 no-ops the scan → red flips.)
  """
  use Demo.DataCase, async: false

  alias Demo.MarketingScope.{Subscriber, Suppression}
  alias Demo.Identity.Org

  import Ecto.Query

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_subscriber(org) do
    {:ok, sub} =
      Subscriber
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        email: "sub@marketing.example",
        status: :active
      })
      |> Ash.create(authorize?: false)

    sub
  end

  defp suppress(org, sub, notes) do
    Suppression
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org.id, subscriber_id: sub.id, reason: :admin_added, notes: notes},
      authorize?: false
    )
    |> Ash.create(authorize?: false)
  end

  test "GREEN: an ordinary tenant note is accepted" do
    org = mk_org("ftpii-green")
    sub = mk_subscriber(org)

    assert {:ok, row} = suppress(org, sub, "left a voicemail about the renewal, no answer")
    assert row.notes == "left a voicemail about the renewal, no answer"
  end

  test "RED: a bare email-shaped note is refused at the write path, DB unchanged" do
    org = mk_org("ftpii-red-email")
    sub = mk_subscriber(org)

    before = Repo.one(from(s in "msp_suppression", where: s.msp_org_id == type(^org.id, :binary_id), select: count()))

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             suppress(org, sub, "attacker@evil.example")

    assert Enum.any?(errors, fn e -> Map.get(e, :message) =~ "pii-shaped free-text" end),
           "expected a pii-shaped free-text refusal, got: #{inspect(errors)}"

    after_ = Repo.one(from(s in "msp_suppression", where: s.msp_org_id == type(^org.id, :binary_id), select: count()))
    assert after_ == before, "a refused write must leave the DB unchanged (no row landed)"
  end

  test "RED: a bare phone-shaped note is refused" do
    org = mk_org("ftpii-red-phone")
    sub = mk_subscriber(org)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             suppress(org, sub, "+1 (555) 867-5309")

    assert Enum.any?(errors, fn e -> Map.get(e, :message) =~ "pii-shaped free-text" end)
  end
end
