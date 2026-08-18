defmodule Samen.Fleet.SubjectKeyTest do
  use ExUnit.Case, async: false

  alias Samen.Fleet.{Handle, SubjectKey}

  describe "custody + stability (ADR-044 §16.2, carried-LOW 2)" do
    test "fetch/1 provisions on first use and is stable across calls" do
      app_id = "app-#{System.unique_integer([:positive])}"
      assert {:ok, dek1} = SubjectKey.fetch(app_id)
      assert {:ok, dek2} = SubjectKey.fetch(app_id)
      assert dek1 == dek2
    end

    test "two different apps get two different keys" do
      app_a = "app-a-#{System.unique_integer([:positive])}"
      app_b = "app-b-#{System.unique_integer([:positive])}"
      assert {:ok, dek_a} = SubjectKey.fetch(app_a)
      assert {:ok, dek_b} = SubjectKey.fetch(app_b)
      refute dek_a == dek_b
    end

    test "the subject id namespace is reserved (never erasure-swept)" do
      app_id = "app-#{System.unique_integer([:positive])}"
      assert Samen.Kms.reserved_subject?(SubjectKey.subject_id(app_id))
      assert {:error, :reserved_subject} = Samen.Kms.shred(SubjectKey.subject_id(app_id))
    end

    test "the raw key never appears in the handle — only the HMAC digest does" do
      app_id = "app-#{System.unique_integer([:positive])}"
      org_id = "org-1"
      {:ok, dek} = SubjectKey.fetch(app_id)
      {:ok, handle} = Handle.compute(app_id, org_id)

      refute String.contains?(handle, Base.encode16(dek, case: :lower))
      assert Handle.well_formed?(handle)
    end
  end

  describe "fleet_handle (§5.3)" do
    test "GREEN: matches?/4 confirms the same {app_id, org_id} pair" do
      app_id = "app-#{System.unique_integer([:positive])}"
      org_id = "org-42"
      {:ok, handle} = Handle.compute(app_id, org_id)
      assert Handle.matches?(app_id, org_id, handle)
    end

    test "RED: a different org_id does not match the same handle" do
      app_id = "app-#{System.unique_integer([:positive])}"
      {:ok, handle} = Handle.compute(app_id, "org-a")
      refute Handle.matches?(app_id, "org-b", handle)
    end

    test "RED: the SAME org_id under a DIFFERENT app's key does not match (unlinkable across products)" do
      app_a = "app-a-#{System.unique_integer([:positive])}"
      app_b = "app-b-#{System.unique_integer([:positive])}"
      org_id = "org-shared"
      {:ok, handle_a} = Handle.compute(app_a, org_id)
      refute Handle.matches?(app_b, org_id, handle_a)
    end

    test "handle_key_version/1 defaults to 1" do
      assert SubjectKey.handle_key_version() == 1
      assert SubjectKey.handle_key_version(version: 3) == 3
    end
  end
end
