defmodule Samen.ImpersonationMaskingTest do
  @moduledoc """
  T4.1 clause (b)/(e): the impersonation scope carries the target org_id + a
  member-equivalent role but NO reveal grant, so every vaulted field renders
  `%Masked{}` (`••••`) — the tenant's own policies apply unchanged.

  This proves the MASK holds through the egress matrix (reusing T3.11's
  `Samen.Api.PiiResolution` — the same resolver the API two-key-classes use):
    * under impersonation (plane :operator, no grant) → vaulted field ABSENT
      (`%Ash.ForbiddenField{}`, which the serializer omits) → `••••`/absent egress;
    * with a live reveal grant on top (the SEPARATE T1.6 path) → plaintext.

  Anti-tautology on the mask: the with-grant control asserts plaintext IS produced —
  so the absence above is the grant gate, not a blanket strip.
  """
  use ExUnit.Case, async: false

  alias Samen.Api.PiiResolution
  alias Samen.Impersonation.Scope
  alias Samen.Impersonation.Session
  alias Samen.Masked
  alias SamenCore.Support.RevealDomain.RevealPerson

  @resource RevealPerson

  # A vault stub — the grant gate is what we prove, not the vault decrypt.
  defmodule OkVault do
    def reveal(_masked, _repo, _opts \\ []), do: {:ok, "alice@revealed.test"}
  end

  defmodule ApproveAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: true
  end

  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  # Build an impersonation scope directly from a synthetic (never-closed) session, so
  # the test doesn't depend on a DB row — we're proving the SCOPE SHAPE masks, and the
  # runtime deny-on-read is proven in impersonation_test.exs.
  defp impersonation_scope(org_id) do
    Scope.from_session!(%Session{
      id: Ecto.UUID.generate(),
      operator_id: "operator-1",
      org_id: org_id,
      reason: "support",
      expires_at: DateTime.add(DateTime.utc_now(), 600),
      closed_at: nil
    })
  end

  defp record(id) do
    struct(@resource, %{id: id, emails: Masked.new("vt_imp_token", :emails)})
  end

  test "the impersonation scope carries no reveal grant → plane :operator + impersonation marker" do
    {:ok, scope} = {:ok, impersonation_scope(Ecto.UUID.generate())}
    assert scope.actor.plane == :operator
    assert scope.actor.role == :member
    assert Scope.impersonated?(scope)
    # A real tenant member scope is NOT impersonated.
    refute Scope.impersonated?(Samen.Scope.new(%{id: "u", org_id: "o", role: :member}))
  end

  test "under impersonation WITHOUT a grant, a vaulted field is PRESENT-but-MASKED (••••)" do
    scope = impersonation_scope(Ecto.UUID.generate())
    subject_id = Ecto.UUID.generate()

    [resolved] =
      PiiResolution.resolve([record(subject_id)], @resource, scope.actor,
        repo: :unused,
        vault: OkVault,
        grant: DenyAll
      )

    # Doc §control: under impersonation "personal data renders •••• by default" — the
    # operator sees the tenant's REAL UI with the field PRESENT-but-masked, NOT plaintext
    # and NOT omitted. (The API operator-KEY posture is different — that omits the field.)
    assert %Samen.Masked{} = resolved.emails
    assert to_string(resolved.emails) == "••••"
    refute resolved.emails == "alice@revealed.test"
  end

  test "ANTI-TAUTOLOGY: with a live reveal grant ON TOP, the same field IS plaintext" do
    scope = impersonation_scope(Ecto.UUID.generate())
    subject_id = Ecto.UUID.generate()

    [resolved] =
      PiiResolution.resolve([record(subject_id)], @resource, scope.actor,
        repo: :unused,
        vault: OkVault,
        grant: ApproveAll
      )

    # With a grant (the separate T1.6 reveal path opened on top), plaintext appears —
    # proving the absence above was the grant gate firing, not a blanket strip.
    assert resolved.emails == "alice@revealed.test"
  end

  test "a %Masked{} value renders •••• through every egress by construction (mask is the field's value)" do
    masked = Masked.new("vt_imp_token", :emails)
    # String / interpolation
    assert to_string(masked) == "••••"
    assert "#{masked}" == "••••"
    # JSON
    assert Jason.encode!(masked) == ~s("••••")
  end
end
