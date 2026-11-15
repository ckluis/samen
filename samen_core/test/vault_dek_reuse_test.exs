defmodule Samen.VaultDekReuseTest do
  @moduledoc """
  Evaluation ARCH-2 — one KMS unwrap per vaulted VALUE, no DEK reuse. A 50-row x 3-field page
  was ~150 `Decrypt` calls against a network KMS. Within ONE `Samen.Api.PiiResolution` call the
  vault now unwraps each SUBJECT's DEK at most once (`Samen.Vault.unwrap_subjects/1`, a
  `Samen.Vault.DekMemo` threaded through the call's `opts`).

  What this module proves (each red path pairs with a positive control):

    * S records (= S subjects) x M vaulted fields -> exactly S unwraps (was S x M), and the
      plaintexts are right per value; `Vault.reveal/3` is still called once per value. (A vault
      subject IS the holding record's primary key — token binding — so several values per subject
      means several FIELDS of one record.)
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
  alias SamenCore.Support.CrmScopeFixture.Person

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

  # Grants keyed on the RECORD id (`ctx.subject_id`): `:__dek_grant_ids` lists the record ids the operator may reveal.
  defmodule PerRecordGrant do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, &granted?/1)

    def granted?(ctx),
      do: ctx.subject_id in Application.get_env(:samen_core, :__dek_grant_ids, [])
  end

  # Grants keyed on {record id, field label}: `:__dek_grant_labels` lists the pairs the operator may reveal.
  defmodule PerLabelGrant do
    @moduledoc false
    def granted_many(ctxs), do: Enum.map(ctxs, &granted?/1)

    def granted?(ctx),
      do: {ctx.subject_id, ctx.label} in Application.get_env(:samen_core, :__dek_grant_labels, [])
  end

  setup do
    Samen.TestSandbox.shared!(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, CountingKms)

    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
      Application.delete_env(:samen_core, :__dek_grant)
      Application.delete_env(:samen_core, :__dek_grant_ids)
      Application.delete_env(:samen_core, :__dek_grant_labels)
    end)

    :ok
  end

  # --- fixtures -----------------------------------------------------------------------------------------------

  @fields [:full_name, :emails, :phones]

  defp vault_of(name) do
    Person |> Samen.Pii.Info.fields() |> Enum.find(&(&1.name == name)) |> Map.fetch!(:vault)
  end

  # A record's worth of vaulted values: `nfields` of Person's fields, minted under the subject = the
  # record's primary key (as `Vault.Change` does). `vals` = [{field, token, plaintext}].
  defp subject!(tag, nfields \\ 3) do
    id = Ash.UUID.generate()

    vals =
      for name <- Enum.take(@fields, nfields) do
        plain = "#{tag}.#{name}.secret@example.com"
        {:ok, token} = Vault.store_field(id, vault_of(name), name, plain, @repo)
        {name, token, plain}
      end

    %{id: id, vals: vals}
  end

  defp tokens(s), do: Enum.map(s.vals, fn {_n, t, _p} -> t end)
  defp token_of(s, name), do: Enum.find_value(s.vals, fn {n, t, _} -> if n == name, do: t end)
  defp plain_of(s, name), do: Enum.find_value(s.vals, fn {n, _, p} -> if n == name, do: p end)

  # The record holding a subject's values: id = subject, each value under its own field.
  defp record(s) do
    struct(Person, Map.new([id: s.id] ++ for({n, t, _} <- s.vals, do: {n, Masked.new(t, n)})))
  end

  defp records(subjects), do: Enum.map(subjects, &record/1)

  defp resolve(recs, actor, opts \\ []) do
    PiiResolution.resolve(
      recs,
      Person,
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

  # {field => resolved value} for one resolved record.
  defp values(rec, nfields \\ 3), do: Map.new(Enum.take(@fields, nfields), &{&1, Map.fetch!(rec, &1)})
  defp expected(s), do: Map.new(s.vals, fn {n, _t, p} -> {n, p} end)

  # ==========================================================================================================

  describe "one unwrap per subject per resolve call" do
    test "N x M values over S subjects cost exactly S unwraps (per-value was N x M)" do
      subjects = [subject!("a"), subject!("b"), subject!("c")]
      recs = records(subjects)
      _ = drain(:kms_unwrap)

      # TODAY (baseline, the pre-change path): revealing each value alone unwraps per value.
      for s <- subjects, {_n, t, p} <- s.vals, do: assert({:ok, ^p} = Vault.reveal(Masked.new(t, :emails), @repo))
      assert unwraps() == 9

      # NEW: the same 9 values in one resolve call.
      resolved = resolve(recs, tenant())
      assert Enum.map(resolved, &values/1) == Enum.map(subjects, &expected/1)
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

      assert Enum.map(resolve(recs, tenant()), &values/1) == [expected(a), expected(b)]
      assert length(drain(:kms_unwrap)) == 2

      # no cross-call reuse: unwrapped afresh
      assert Enum.map(resolve(recs, tenant()), &values/1) == [expected(a), expected(b)]
      assert length(drain(:kms_unwrap)) == 2

      # crypto-shred is immediate: the very next call sees nothing of `a`, `b` still clear
      {:ok, _} = Vault.shred(a.id)
      _ = drain(:kms_unwrap)
      [out_a, out_b] = resolve(recs, tenant())

      assert Enum.all?(values(out_a), fn {_n, v} -> match?(%Masked{}, v) end)
      assert values(out_b) == expected(b)
      refute inspect([out_a, out_b]) =~ "a.emails.secret"
    end

    test "a failing subject denies only its own values, costs ONE failed unwrap, and poisons nobody" do
      bad = subject!("bad")
      good1 = subject!("good1")
      good2 = subject!("good2")
      {:ok, _} = Vault.shred(bad.id)
      recs = records([bad, good1, good2])
      _ = drain(:kms_unwrap)

      [out_bad, out1, out2] = resolve(recs, tenant())

      assert Enum.all?(values(out_bad), fn {_n, v} -> match?(%Masked{}, v) end), "shredded values stay masked"
      assert values(out1) == expected(good1), "POSITIVE CONTROL: healthy subjects still resolve"
      assert values(out2) == expected(good2)

      # 3 subjects -> 3 unwraps, the failed one NOT retried per value (3 values)
      unwrapped = drain(:kms_unwrap) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert unwrapped == Enum.sort([bad.id, good1.id, good2.id])
    end
  end

  describe "the memo never crosses subjects, orgs or adapters" do
    test "a memo built for subject A is not used for subject B's row (B unwraps live, own key)" do
      a = subject!("org1:alice", 1)
      b = subject!("org2:alice", 1)
      ta = token_of(a, :full_name)
      tb = token_of(b, :full_name)
      pa = plain_of(a, :full_name)
      pb = plain_of(b, :full_name)
      rows = Vault.prefetch_rows([ta, tb], @repo)
      memo = Vault.unwrap_subjects(Map.take(rows, [ta]))
      _ = drain(:kms_unwrap)

      assert {:ok, ^pa} = Vault.reveal(Masked.new(ta, :full_name), @repo, prefetched: rows, deks: memo)
      assert unwraps() == 0

      # B is not in the memo: it takes its OWN live unwrap and decrypts under its OWN key.
      assert {:ok, ^pb} = Vault.reveal(Masked.new(tb, :full_name), @repo, prefetched: rows, deks: memo)
      assert [{:kms_unwrap, bid}] = drain(:kms_unwrap)
      assert bid == b.id
    end

    test "a mixed-subject batch resolves each value under its own subject's key" do
      subjects = [subject!("org1:same", 2), subject!("org2:same", 2)]
      out = resolve(records(subjects), tenant())
      assert Enum.map(out, &values(&1, 2)) == Enum.map(subjects, &expected/1)
    end

    test "a memo built under one adapter is not trusted under another" do
      a = subject!("a", 1)
      t = token_of(a, :full_name)
      p = plain_of(a, :full_name)
      rows = Vault.prefetch_rows([t], @repo)
      memo = Vault.unwrap_subjects(rows)
      _ = drain(:kms_unwrap)

      Application.put_env(:samen_core, :kms_adapter, OtherKms)
      assert {:ok, ^p} = Vault.reveal(Masked.new(t, :full_name), @repo, prefetched: rows, deks: memo)
      assert [{:other_unwrap, id}] = drain(:other_unwrap)
      assert id == a.id
    end

    test "a subject-asserting reveal still binds the real subject before any unwrap" do
      a = subject!("a", 1)
      t = token_of(a, :full_name)
      rows = Vault.prefetch_rows([t], @repo)
      memo = Vault.unwrap_subjects(rows)

      assert {:error, :subject_mismatch} =
               Vault.reveal(Masked.new(t, :full_name), @repo,
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
      assert Enum.all?(denied, fn r -> Enum.all?(values(r), fn {_n, v} -> match?(%Masked{}, v) end) end)
      refute inspect(denied) =~ "secret@example.com"

      # POSITIVE CONTROL: the same call under a live grant decrypts, one unwrap per subject.
      Application.put_env(:samen_core, :__dek_grant, true)
      granted = resolve(recs, operator())
      assert Enum.map(granted, &values/1) == Enum.map(subjects, &expected/1)
      assert length(drain(:kms_unwrap)) == 2
    end

    test "a value the plane denies stays masked, even though its sibling (SAME subject, DEK in the memo) is clear" do
      s = subject!("s", 3)
      rec = record(s)
      _ = drain(:kms_unwrap)

      # A grant is per {record, field}: grant ONLY the :emails label of this record.
      Application.put_env(:samen_core, :__dek_grant_labels, [{s.id, :emails}])

      [out] =
        PiiResolution.resolve([rec], Person, operator(),
          repo: @repo,
          vault: CountingVault,
          grant: PerLabelGrant
        )

      assert out.emails == plain_of(s, :emails)
      assert %Masked{} = out.full_name
      assert %Masked{} = out.phones
      refute inspect(out.full_name) =~ plain_of(s, :full_name)
      refute inspect(out.phones) =~ plain_of(s, :phones)
      refute inspect(out.full_name) =~ "vt_"
      # one unwrap for S, and Vault.reveal/3 was never asked for the denied values
      assert unwraps() == 1
      assert drain(:reveal) == [{:reveal, token_of(s, :emails)}]

      # POSITIVE CONTROL: grant all three -> all clear (the denial above was the grant, not the memo)
      Application.put_env(:samen_core, :__dek_grant_labels, for(n <- @fields, do: {s.id, n}))

      [both] =
        PiiResolution.resolve([rec], Person, operator(),
          repo: @repo,
          vault: CountingVault,
          grant: PerLabelGrant
        )

      assert values(both) == expected(s)
    end

    test "building the memo never widens what is decrypted: a fully denied subject is never unwrapped" do
      allowed = subject!("allowed", 1)
      denied = subject!("denied", 2)

      recs = [record(allowed), record(denied)]
      _ = drain(:kms_unwrap)
      Application.put_env(:samen_core, :__dek_grant_ids, [allowed.id])

      out =
        PiiResolution.resolve(recs, Person, operator(),
          repo: @repo,
          vault: CountingVault,
          grant: PerRecordGrant
        )

      assert [%{full_name: pa}, %{full_name: %Masked{}, emails: %Masked{}}] = out
      assert pa == plain_of(allowed, :full_name)
      refute inspect(out) =~ plain_of(denied, :full_name)
      refute inspect(out) =~ plain_of(denied, :emails)
      # only the ALLOWED subject reached the KMS (the denied one's DEK is never in memory)
      assert drain(:kms_unwrap) == [{:kms_unwrap, allowed.id}]
    end

    test "a memo built by ANOTHER process is ignored: reveal unwraps live" do
      a = subject!("a", 1)
      t = token_of(a, :full_name)
      plain = plain_of(a, :full_name)
      rows = Vault.prefetch_rows([t], @repo)
      memo = Task.async(fn -> Vault.unwrap_subjects(rows) end) |> Task.await()
      _ = drain(:kms_unwrap)

      # the foreign memo is not used: a live unwrap happens in this process
      assert {:ok, ^plain} = Vault.reveal(Masked.new(t, :full_name), @repo, prefetched: rows, deks: memo)
      assert unwraps() == 1

      # POSITIVE CONTROL: a memo built by THIS process is used (no further unwrap)
      own = Vault.unwrap_subjects(rows)
      _ = drain(:kms_unwrap)
      assert {:ok, ^plain} = Vault.reveal(Masked.new(t, :full_name), @repo, prefetched: rows, deks: own)
      assert unwraps() == 0
    end

    test "a subject shredded mid-call is served for the rest of THAT call, never by the next" do
      a = subject!("a", 2)
      [t1, t2] = tokens(a)
      [p1, p2] = Enum.map(a.vals, &elem(&1, 2))
      rows = Vault.prefetch_rows([t1, t2], @repo)
      memo = Vault.unwrap_subjects(rows)

      assert {:ok, ^p1} = Vault.reveal(Masked.new(t1, :full_name), @repo, prefetched: rows, deks: memo)
      {:ok, _} = Vault.shred(a.id)
      # the shred check IS the unwrap, done once when the memo was built: this call still serves it
      assert {:ok, ^p2} = Vault.reveal(Masked.new(t2, :emails), @repo, prefetched: rows, deks: memo)
      # the next call builds a new memo and the shred is seen
      fresh = Vault.unwrap_subjects(Vault.prefetch_rows([t2], @repo))
      assert {:error, :shredded} = Vault.reveal(Masked.new(t2, :emails), @repo, deks: fresh)
    end

    test "AI egress without the host opt-in decrypts nothing and unwraps nothing" do
      recs = records([subject!("a")])
      _ = drain(:kms_unwrap)
      Application.put_env(:samen_core, :__dek_grant, true)

      [out] = resolve(recs, tenant(), egress: true)
      assert unwraps() == 0
      assert Enum.all?(values(out), fn {_n, v} -> match?(%Masked{}, v) end)
    end
  end

  describe "token binding: a foreign subject's key is never unwrapped" do
    test "T-R2: a record holding another subject's token costs ZERO unwraps of that subject; its own subject still costs one" do
      own = subject!("own", 3)
      foreign = subject!("foreign", 3)
      # `own`'s record, plus a record (a fresh id) whose :full_name cell holds `foreign`'s token
      holder = struct(Person, %{id: Ash.UUID.generate(), full_name: Masked.new(token_of(foreign, :full_name), :full_name)})
      _ = drain(:kms_unwrap)

      [out_own, out_holder] = resolve([record(own), holder], tenant())

      assert values(out_own) == expected(own), "POSITIVE CONTROL: the bound record resolves clear"
      assert %Masked{} = out_holder.full_name
      refute inspect(out_holder) =~ plain_of(foreign, :full_name)

      unwrapped = drain(:kms_unwrap) |> Enum.map(&elem(&1, 1))
      assert unwrapped == [own.id], "only the bound subject may be unwrapped, got #{inspect(unwrapped)}"
      refute foreign.id in unwrapped
      # reveal/3 is still asked per value that passed the plane; it refuses the foreign one itself
      assert tag_count(:reveal) == 4
    end

    test "a reveal that asserts the wrong field is refused BEFORE any unwrap" do
      s = subject!("s", 1)
      t = token_of(s, :full_name)
      rows = Vault.prefetch_rows([t], @repo)
      _ = drain(:kms_unwrap)

      assert {:error, :field_mismatch} =
               Vault.reveal(Masked.new(t, :full_name), @repo, prefetched: rows, field: {vault_of(:full_name), "emails"})

      assert unwraps() == 0

      # POSITIVE CONTROL: the right field unwraps and reveals
      p = plain_of(s, :full_name)
      assert {:ok, ^p} = Vault.reveal(Masked.new(t, :full_name), @repo, prefetched: rows, field: {vault_of(:full_name), "full_name"})
      assert unwraps() == 1
    end
  end

  describe "the memo holds key bytes only inside the call" do
    test "Inspect is redacted (positive control: the key IS in the memo)" do
      a = subject!("a", 1)
      memo = Vault.unwrap_subjects(Vault.prefetch_rows(tokens(a), @repo))

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
      a = subject!("a")
      {:ok, dek} = Samen.Kms.FileBacked.unwrap(a.id)
      _ = resolve(records([a]), tenant())

      refute inspect(Process.get(), limit: :infinity) =~ inspect(dek)
      refute Enum.any?(Process.get(), fn {_, v} -> match?(%DekMemo{}, v) end)
    end
  end
end
