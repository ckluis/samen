defmodule PawChart.BlindIndexErasureGuardTest do
  @moduledoc """
  Guard: every blind-index (`*_bidx`) column of every pawchart resource is covered by the erasure arm
  (`Samen.Auth.BlindIndexErasure`), and the identity mount's Credential/Invitation/AuthToken
  indexes plus the LoginFailure counters are derived from the live schema, with no host config.
  Fail-closed: a host that mounts identity but derives no spec fails.
  """
  use ExUnit.Case, async: true

  test "no blind-index column goes uncovered, and the identity mount's are all derived" do
    # The PRODUCTION lookup (what `Samen.Erasure.shred/2` runs): no options, so the host app resolves exactly as
    # it does at runtime. Passing `otp_app: :pawchart` here would prove a lookup the runtime does not make.
    resources = Samen.Erasure.Completeness.resources()
    assert resources != []

    # A release has no Mix: the same lookup then reads `:samen_core`'s `:host_domains` registry, which the host config
    # must populate with the same domains, or erasure would derive a different (smaller) schema there.
    assert MapSet.new(Samen.Erasure.Completeness.resources(otp_app: :samen_core)) == MapSet.new(resources)

    assert Samen.Auth.BlindIndexErasure.uncovered(resources) == []

    columns = for s <- Samen.Auth.BlindIndexErasure.derived_specs(resources), do: String.replace(s.bidx_column, ~r/\A[a-z]{3}_/, "")
    assert Enum.sort(Enum.uniq(columns)) == ["email_bidx", "sent_to_bidx"]
    assert length(columns) >= 3, "Credential.email_bidx, Invitation.email_bidx and AuthToken.sent_to_bidx"
    assert [_ | _] = Samen.Auth.BlindIndexErasure.login_failure_tables(resources)
  end
end
