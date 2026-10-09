defmodule Samen.Replay.ResolverBatchTest do
  @moduledoc """
  ADR-052 §2.4.1 (P3 gate note 9) — the player's N+1. Resolving one frame batch read each
  referenced resource ONCE, then resolved every record ALONE through
  `Samen.Api.PiiResolution`: one vault-row read per vault field per record (tenant), plus a
  suspension check and a grant read per field per record (operator). The query count grew with
  the rows on screen.

  Now the vault rows and the grant/suspension decisions are read ONCE per resolve call (per
  frame batch) — `Samen.Api.PiiResolution.prefetch/4`, `Samen.Vault.prefetch_rows/2`,
  `Samen.Reveal.Grants.granted_many/1` — and still read AGAIN on the next batch
  (deny-on-read: nothing is cached across calls). The query count is a constant, whatever the
  row count; the outcomes are unchanged.
  """
  use ExUnit.Case, async: false

  alias Samen.Replay.{Placeholder, Ref, Resolver}
  alias SamenCore.Support.AutomationFixture.Subject

  @repo SamenCore.TestRepo
  @resource "SamenCore.Support.AutomationFixture.Subject"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    %{org: Ash.UUID.generate()}
  end

  defp subjects!(org, n, from \\ 1) do
    for i <- from..(from + n - 1) do
      Subject
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        title: "batch #{i}",
        email: "batch.#{i}.secret@example.com"
      })
      |> Ash.create!(authorize?: false)
    end
  end

  # What a stored frame decodes to: one reference per row on screen.
  defp tree(subjects),
    do: %{
      rows:
        Enum.map(
          subjects,
          &%Ref{resource: @resource, pk: &1.id, attribute: "email", label: "email"}
        )
    }

  defp tenant(org), do: %Samen.Scope{actor: %{org_id: org, plane: :tenant, role: :admin}}

  defp operator(org, id \\ Ash.UUID.generate()) do
    %Samen.Scope{
      actor: %{
        id: id,
        org_id: org,
        role: :member,
        plane: :operator,
        impersonation: %{session_id: Ash.UUID.generate()}
      }
    }
  end

  # The number of repo queries `fun` issues (and its result).
  defp count_queries(fun) do
    test_pid = self()
    id = "resolver-batch-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:samen_core, :test_repo, :query],
        fn _, _, _, _ -> send(test_pid, :q) end,
        nil
      )

    {us, result} = :timer.tc(fun)
    :telemetry.detach(id)
    {drain(0), div(us, 1000), result}
  end

  defp drain(n) do
    receive do
      :q -> drain(n + 1)
    after
      0 -> n
    end
  end

  test "a 50-row frame costs a CONSTANT number of queries on both planes (no N+1)", ctx do
    few = subjects!(ctx.org, 2)
    many = few ++ subjects!(ctx.org, 48, 3)

    # Warm-up (first-use lookups are not part of a frame batch's cost).
    _ = Resolver.resolve(tree(few), tenant(ctx.org))
    _ = Resolver.resolve(tree(few), operator(ctx.org), grant: Samen.Reveal.Grants)

    {tenant_few, _, _} = count_queries(fn -> Resolver.resolve(tree(few), tenant(ctx.org)) end)

    {tenant_many, tenant_ms, %{value: v}} =
      count_queries(fn -> Resolver.resolve(tree(many), tenant(ctx.org)) end)

    # Outcomes unchanged: the tenant sees every row CLEAR.
    assert Enum.map(v.rows, &to_string/1) == Enum.map(1..50, &"batch.#{&1}.secret@example.com")

    op = operator(ctx.org)

    {op_few, _, _} =
      count_queries(fn -> Resolver.resolve(tree(few), op, grant: Samen.Reveal.Grants) end)

    {op_many, op_ms, %{value: ov}} =
      count_queries(fn -> Resolver.resolve(tree(many), op, grant: Samen.Reveal.Grants) end)

    # Outcomes unchanged: an operator with no grant sees every row masked.
    assert Enum.all?(ov.rows, &(&1 == Placeholder.new(:masked)))

    IO.puts(
      "\n[resolver N+1] 50 rows: tenant #{tenant_many} queries (#{tenant_ms} ms), " <>
        "operator #{op_many} queries (#{op_ms} ms); 2 rows: tenant #{tenant_few}, operator #{op_few}"
    )

    # The cost does not grow with the rows on screen.
    assert tenant_many == tenant_few
    assert op_many == op_few
    # One resource read + one vault-row read; operator: one read + one suspension check + one
    # grant read (no grant → nothing to decrypt).
    assert tenant_many == 2
    assert op_many == 3
  end

  test "deny-on-read survives batching: a grant issued between two batches takes effect on the next",
       ctx do
    [s1, s2] = subjects!(ctx.org, 2)
    op_id = Ash.UUID.generate()
    op = operator(ctx.org, op_id)

    %{value: v} = Resolver.resolve(tree([s1, s2]), op, grant: Samen.Reveal.Grants)
    assert v.rows == [Placeholder.new(:masked), Placeholder.new(:masked)]

    grant!(op_id, s2.id)

    # The NEXT batch reads again: s2 now clear, s1 still masked — per subject, not per batch.
    %{value: v} = Resolver.resolve(tree([s1, s2]), op, grant: Samen.Reveal.Grants)
    assert v.rows == [Placeholder.new(:masked), "batch.2.secret@example.com"]

    # And a suspension issued between batches denies every subject on the next one.
    suspend!(op_id)
    %{value: v} = Resolver.resolve(tree([s1, s2]), op, grant: Samen.Reveal.Grants)
    assert v.rows == [Placeholder.new(:masked), Placeholder.new(:masked)]
  end

  # A live, distinct-party grant row for `requestor` on `subject` (the shape
  # `Samen.Reveal.Grants.active?/3` reads).
  defp grant!(requestor, subject) do
    now = DateTime.utc_now()

    @repo.insert!(%Samen.Reveal.RevealGrant{
      id: Ecto.UUID.generate(),
      request_id: Ecto.UUID.generate(),
      subject_id: subject,
      requestor_id: requestor,
      granted_by: Ecto.UUID.generate(),
      reason: "r",
      expires_at: DateTime.add(now, 600, :second),
      revoked_at: nil,
      inserted_at: now,
      updated_at: now
    })
  end

  defp suspend!(operator_id) do
    {:ok, _} =
      Samen.OperatorPlane.Suspension.suspend(%{
        operator_id: operator_id,
        reason: "breadth budget"
      })
  end
end
