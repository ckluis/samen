defmodule Samen.VaultDekReuseTest do
  @moduledoc """
  Evaluation ARCH-2 — one KMS unwrap per vaulted VALUE, no DEK reuse. A 50-row x 3-field page
  was ~150 `Decrypt` calls against a network KMS. Within ONE `Samen.Api.PiiResolution` call the
  vault now unwraps each SUBJECT's DEK at most once (`Samen.Vault.unwrap_subjects/1`, a
  `Samen.Vault.DekMemo` threaded through the call's `opts`).

  What this module proves (each red path pairs with a positive control):

    * N rows x M fields over S subjects -> exactly S unwraps (was N x M), and the plaintexts
      are right per value; `Vault.reveal/3` is still called once per value
    * the reuse is ONE CALL wide: the next call unwraps again; a subject shredded in between is
      masked on the second call, the others still clear
    * a subject whose unwrap fails (shredded) denies only its own values, costs ONE failed
      unwrap (not one per value), and is never served a neighbour's key
    * a memo never serves a DEK for another subject or another adapter
    * authorisation is unchanged: an operator without a grant reaches the KMS ZERO times
      (today's behaviour — the prefetch only reads/unwraps values the plane will decrypt)
    * the memo holds key bytes only inside the call: redacting `Inspect`, nothing left in the
      process dictionary
  """
  use ExUnit.Case, async: false

  alias Samen.Api.PiiResolution
  alias Samen.Masked
  alias Samen.Vault
  alias Samen.Vault.DekMemo
  alias SamenCore.Support.RevealDomain.RevealPerson

  @repo SamenCore.TestRepo

  # --- doubles ------------------------------------------------------------------------------------------------

  defmodule CountingKms do
    @moduledoc false
    # Delegates to the file-backed store; every `unwrap/1` is reported to the calling process.
    @behaviour Samen.Kms
    alias Samen.Kms.FileBacked, as: F
    @impl true
    def unwrap(subject) do
      send(self(), {:kms_unwrap, subject})
      F.unwrap(subject)
    end

    @impl true
    defdelegate generate_subject_key(s), to: F
    @impl true
    defdelegate shred(s), to: F
    @impl true
    defdelegate attest(s), to: F
    @impl true
    defdelegate backups_disabled?(), to: F
    @impl true
    defdelegate key_material_present?(s), to: F
    @impl true
    defdelegate pseudonym(a, b), to: F
  end

  defmodule OtherKms do
    @moduledoc false
    @behaviour Samen.Kms
    alias Samen.Kms.FileBacked, as: F
    @impl true
    def unwrap(subject) do
      send(self(), {:other_unwrap, subject})
      F.unwrap(subject)
    end

    @impl true
    defdelegate generate_subject_key(s), to: F
    @impl true
    defdelegate shred(s), to: F
    @impl true
    defdelegate attest(s), to: F
    @impl true
    defdelegate backups_disabled?(), to: F
    @impl true
    defdelegate key_material_present?(s), to: F
    @impl true
    defdelegate pseudonym(a, b), to: F
  end

  # The real vault, reporting each per-value reveal (the audit-bearing unit stays per value).
  defmodule CountingVault do
    @moduledoc false
    def reveal(masked, repo, opts) do
      send(self(), {:reveal, masked.token})
      Samen.Vault.reveal(masked, repo, opts)
    end

    defdelegate prefetch_rows(tokens, repo), to: Samen.Vault
    defdelegate unwrap_subjects(rows), to: Samen.Vault
  end

  defmodule Grant do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, fn _ -> Application.get_env(:samen_core, :__dek_grant, false) end)
    def granted?(_), do: Application.get_env(:samen_core, :__dek_grant, false)
  end

  setup do
    Samen.TestSandbox.shared!(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, CountingKms)

    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
      Application.delete_env(:samen_core, :__dek_grant)
    end)

    :ok
  end

  # --- fixtures -----------------------------------------------------------------------------------------------

  # `fields` vaulted values for a fresh subject: [{token, plaintext}].
  defp subject!(tag, fields \\ 3) do
    id = "#{tag}-#{Ash.UUID.generate()}"

    vals =
      for i <- 1..fields do
        plain = "#{tag}.f#{i}.secret@example.com"
        {:ok, token} = Vault.store_field(id, :pii_email, :emails, plain, @repo)
        {token, plain}
      end

    %{id: id, vals: vals}
  end

  # One record per vaulted value (N = subjects x fields rows).
  defp records(subjects) do
    for s <- subjects, {token, plain} <- s.vals do
      {struct(RevealPerson, %{id: Ash.UUID.generate(), emails: Masked.new(token, :emails)}), plain}
    end
  end

  defp resolve(recs, actor, opts \\ []) do
    PiiResolution.resolve(
      Enum.map(recs, &elem(&1, 0)),
      RevealPerson,
      actor,
      Keyword.merge([repo: @repo, vault: CountingVault, grant: Grant], opts)
    )
  end

  defp tenant, do: %{plane: :tenant, org_id: Ash.UUID.generate()}
  defp operator, do: %{plane: :operator, impersonation: %{session_id: "s"}}

  defp drain(tag, acc \\ []) do
    receive do
      msg when elem(msg, 0) == tag -> drain(tag, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp unwraps, do: tag_count(:kms_unwrap)
  defp tag_count(tag), do: tag |> drain() |> length()

  defp plains(resolved), do: Enum.map(resolved, & &1.emails)

  # ==========================================================================================================

  describe "one unwrap per subject per resolve call" do
    test "N x M values over S subjects cost exactly S unwraps (per-value was N x M)" do
      subjects = [subject!("a"), subject!("b"), subject!("c")]
      recs = records(subjects)
      assert length(recs) == 9
      _ = drain(:kms_unwrap)

      # TODAY (baseline, the pre-change path): revealing each value alone unwraps per value.
      _ = drain(:kms_unwrap)
      for {r, plain} <- recs, do: assert({:ok, ^plain} = Vault.reveal(r.emails, @repo))
      assert unwraps() == 9

      # NEW: the same 9 values in one resolve call.
      resolved = resolve(recs, tenant())
      assert plains(resolved) == Enum.map(recs, &elem(&1, 1))
      unwrapped = drain(:kms_unwrap)
      assert length(unwrapped) == 3
      assert unwrapped |> Enum.map(&elem(&1, 1)) |> Enum.sort() == subjects |> Enum.map(& &1.id) |> Enum.sort()

      # The audit-bearing unit is untouched: `Vault.reveal/3` still runs once per VALUE.
      assert tag_count(:reveal) == 9
    end

    test "the reuse ends with the call: a second call unwraps again; a subject shredded between is masked" do
      a = subject!("a")
      b = subject!("b")
      recs = records([a, b])
      _ = drain(:kms_unwrap)

      assert plains(resolve(recs, tenant())) == Enum.map(recs, &elem(&1, 1))
      assert length(drain(:kms_unwrap)) == 2

      # no cross-call reuse: unwrapped afresh
      assert plains(resolve(recs, tenant())) == Enum.map(recs, &elem(&1, 1))
      assert length(drain(:kms_unwrap)) == 2

      # crypto-shred is immediate: the very next call sees nothing of `a`, `b` still clear
      {:ok, _} = Vault.shred(a.id)
      _ = drain(:kms_unwrap)
      out = resolve(recs, tenant())

      for {{rec, plain}, got} <- Enum.zip(recs, out) do
        if rec.emails.token in Enum.map(a.vals, &elem(&1, 0)),
          do: assert(%Masked{} = got.emails),
          else: assert(got.emails == plain)
      end

      refute inspect(out) =~ "a.f1.secret"
    end

    test "a failing subject denies only its own values, costs ONE failed unwrap, and poisons nobody" do
      bad = subject!("bad")
      good1 = subject!("good1")
      good2 = subject!("good2")
      {:ok, _} = Vault.shred(bad.id)
      recs = records([bad, good1, good2])
      _ = drain(:kms_unwrap)

      out = resolve(recs, tenant())
      bad_tokens = Enum.map(bad.vals, &elem(&1, 0))

      for {{rec, plain}, got} <- Enum.zip(recs, out) do
        if rec.emails.token in bad_tokens,
          do: assert(%Masked{} = got.emails, "shredded values stay masked"),
          else: assert(got.emails == plain, "POSITIVE CONTROL: healthy subjects still resolve")
      end

      # 3 subjects -> 3 unwraps, the failed one NOT retried per value (3 values)
      unwrapped = drain(:kms_unwrap) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert unwrapped == Enum.sort([bad.id, good1.id, good2.id])
    end
  end

  describe "the memo never crosses subjects, orgs or adapters" do
    test "a memo built for subject A is not used for subject B's row (B unwraps live, own key)" do
      a = subject!("org1:alice", 1)
      b = subject!("org2:alice", 1)
      [{ta, pa}] = a.vals
      [{tb, pb}] = b.vals
      rows = Vault.prefetch_rows([ta, tb], @repo)
      memo = Vault.unwrap_subjects(Map.take(rows, [ta]))
      _ = drain(:kms_unwrap)

      assert {:ok, ^pa} = Vault.reveal(Masked.new(ta, :emails), @repo, prefetched: rows, deks: memo)
      assert unwraps() == 0

      # B is not in the memo: it takes its OWN live unwrap and decrypts under its OWN key.
      assert {:ok, ^pb} = Vault.reveal(Masked.new(tb, :emails), @repo, prefetched: rows, deks: memo)
      assert [{:kms_unwrap, bid}] = drain(:kms_unwrap)
      assert bid == b.id
    end

    test "a mixed-subject batch resolves each value under its own subject's key" do
      subjects = [subject!("org1:same", 2), subject!("org2:same", 2)]
      recs = records(subjects)
      assert plains(resolve(recs, tenant())) == Enum.map(recs, &elem(&1, 1))
    end

    test "a memo built under one adapter is not trusted under another" do
      a = subject!("a", 1)
      [{t, p}] = a.vals
      rows = Vault.prefetch_rows([t], @repo)
      memo = Vault.unwrap_subjects(rows)
      _ = drain(:kms_unwrap)

      Application.put_env(:samen_core, :kms_adapter, OtherKms)
      assert {:ok, ^p} = Vault.reveal(Masked.new(t, :emails), @repo, prefetched: rows, deks: memo)
      assert [{:other_unwrap, id}] = drain(:other_unwrap)
      assert id == a.id
    end

    test "a subject-asserting reveal still binds the real subject before any unwrap" do
      a = subject!("a", 1)
      [{t, _}] = a.vals
      rows = Vault.prefetch_rows([t], @repo)
      memo = Vault.unwrap_subjects(rows)

      assert {:error, :subject_mismatch} =
               Vault.reveal(Masked.new(t, :emails), @repo,
                 prefetched: rows,
                 deks: memo,
                 subject_id: "someone-else"
               )
    end
  end

  describe "authorisation is unchanged" do
    test "operator WITHOUT a grant: masked and ZERO unwraps; WITH a grant: clear, one per subject" do
      subjects = [subject!("a"), subject!("b")]
      recs = records(subjects)
      _ = drain(:kms_unwrap)

      Application.put_env(:samen_core, :__dek_grant, false)
      denied = resolve(recs, operator())
      assert unwraps() == 0
      assert Enum.all?(denied, &match?(%Masked{}, &1.emails))
      refute inspect(denied) =~ "secret@example.com"

      # POSITIVE CONTROL: the same call under a live grant decrypts, one unwrap per subject.
      Application.put_env(:samen_core, :__dek_grant, true)
      granted = resolve(recs, operator())
      assert plains(granted) == Enum.map(recs, &elem(&1, 1))
      assert length(drain(:kms_unwrap)) == 2
    end

    test "AI egress without the host opt-in decrypts nothing and unwraps nothing" do
      recs = records([subject!("a")])
      _ = drain(:kms_unwrap)
      Application.put_env(:samen_core, :__dek_grant, true)

      out = resolve(recs, tenant(), egress: true)
      assert unwraps() == 0
      assert Enum.all?(out, &match?(%Masked{}, &1.emails))
    end
  end

  describe "the memo holds key bytes only inside the call" do
    test "Inspect is redacted (positive control: the key IS in the memo)" do
      a = subject!("a", 1)
      [{t, _}] = a.vals
      memo = Vault.unwrap_subjects(Vault.prefetch_rows([t], @repo))

      assert %DekMemo{entries: entries} = memo
      assert [{:ok, dek}] = Map.values(entries)
      assert byte_size(dek) == 32

      shown = inspect(memo, limit: :infinity)
      assert shown =~ "redacted"
      refute shown =~ Base.encode64(dek)
      refute shown =~ Base.encode16(dek, case: :lower)
      refute shown =~ inspect(dek)
      refute shown =~ a.id
    end

    test "nothing is left in the process dictionary after a resolve" do
      recs = records([subject!("a")])
      {:ok, dek} = Samen.Kms.FileBacked.unwrap(subject_of(recs))
      _ = resolve(recs, tenant())

      refute inspect(Process.get(), limit: :infinity) =~ inspect(dek)
      refute Enum.any?(Process.get(), fn {_, v} -> match?(%DekMemo{}, v) end)
    end
  end

  defp subject_of(recs) do
    {r, _} = hd(recs)
    %{subject_id: sid} = @repo.get(Samen.Vault.VaultRow, r.emails.token)
    sid
  end
end
