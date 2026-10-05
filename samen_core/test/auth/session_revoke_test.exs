defmodule Samen.Auth.SessionRevokeTest do
  @moduledoc """
  `Samen.Auth.SessionRevoke.revoke_one/3` answers from the ROW, never from the bulk
  update's result (found by dialyzer, issue #73).

  It used to match `{:ok, %Ash.BulkResult{}}`, but `Ash.bulk_update/4` returns a bare
  `%Ash.BulkResult{}`, so every call fell to a fallback that answered `{:ok, :revoked}`
  whenever the session merely EXISTED for the credential — so a revoke that FAILED
  reported success while the session stayed live (fail-open). A successful bulk update
  that matched no row is no better a signal: it cannot tell "revoked yours" from "matched
  nothing". So the answer is read back from the row itself.

  In-memory (ETS) resources, so the failing revoke is deterministic: one resource's
  `:revoke` action is refused by Ash's own `absent(:revoked_at)` validation.
  """
  use ExUnit.Case, async: false

  alias Samen.Auth.SessionRevoke

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Samen.Auth.SessionRevokeTest.Sessions)
      resource(Samen.Auth.SessionRevokeTest.StuckSessions)
    end
  end

  defmodule Sessions do
    @moduledoc false
    use Ash.Resource, domain: Samen.Auth.SessionRevokeTest.Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:credential_id, :string, public?: true, allow_nil?: false)
      attribute(:revoked_at, :utc_datetime_usec, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :revoke do
        accept([:revoked_at])
      end
    end
  end

  # The same shape, but its `:revoke` can never succeed: the update always sets
  # `revoked_at`, which `absent(:revoked_at)` refuses.
  defmodule StuckSessions do
    @moduledoc false
    use Ash.Resource, domain: Samen.Auth.SessionRevokeTest.Domain, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
      attribute(:credential_id, :string, public?: true, allow_nil?: false)
      attribute(:revoked_at, :utc_datetime_usec, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :revoke do
        accept([:revoked_at])
        validate(absent(:revoked_at))
      end
    end
  end

  defp session!(resource, credential_id) do
    resource
    |> Ash.Changeset.for_create(:create, %{credential_id: credential_id})
    |> Ash.create!(authorize?: false)
  end

  defp revoked_at(resource, id), do: Ash.get!(resource, id, authorize?: false).revoked_at

  test "RED: a revoke that FAILS is reported as a failure — never {:ok, :revoked} for a session that is still live" do
    s = session!(StuckSessions, "cred-a")

    assert SessionRevoke.revoke_one(StuckSessions, s.id, "cred-a") == {:error, :revoke_failed}
    # The session really is still live, which is what makes the answer above the honest one.
    assert revoked_at(StuckSessions, s.id) == nil
  end

  test "positive control: a revoke that works is {:ok, :revoked} and the row is revoked" do
    s = session!(Sessions, "cred-a")

    assert SessionRevoke.revoke_one(Sessions, s.id, "cred-a") == {:ok, :revoked}
    assert %DateTime{} = revoked_at(Sessions, s.id)
  end

  test "revoking an already-revoked session of yours is still a success (idempotent)" do
    s = session!(Sessions, "cred-a")
    assert {:ok, :revoked} = SessionRevoke.revoke_one(Sessions, s.id, "cred-a")
    assert {:ok, :revoked} = SessionRevoke.revoke_one(Sessions, s.id, "cred-a")
  end

  test "another credential's session is :not_found and is NOT revoked" do
    s = session!(Sessions, "cred-b")

    assert SessionRevoke.revoke_one(Sessions, s.id, "cred-a") == {:error, :not_found}
    assert revoked_at(Sessions, s.id) == nil
  end

  test "an unknown session is :not_found" do
    assert SessionRevoke.revoke_one(Sessions, Ash.UUID.generate(), "cred-a") ==
             {:error, :not_found}
  end
end
