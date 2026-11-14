defmodule Samen.PiiResolutionPlanesTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): `Samen.Api.PiiResolution` is the ONE plane-aware masking decision every read goes
  through. These are the branch-level proofs the watch-list asked of it — each is a red path paired with a positive
  control (a test that cannot fail is a bug):

    * which repo the resolver decrypts against (explicit opt > the resource's own repo > the app default)
    * WHEN the grant checker is consulted (operator render; AI egress only with the host opt-in — never the tenant
      plane, never an empty batch) and WHICH values the prefetch will decrypt (the same rule `resolve_field` applies)
    * AI egress: masked on EVERY plane unless BOTH the opt-in and a literal `true` grant
    * the operator posture: no grant → absent (`%Ash.ForbiddenField{}`) for an API key, `••••` for an impersonation
    * the pii_declared custom-bag key per plane, including an operator WITH a live grant and an unknown plane
  """
  use ExUnit.Case, async: false

  alias Samen.Api.PiiResolution
  alias Samen.Masked
  alias SamenCore.Support.RevealDomain.RevealPerson

  @resource RevealPerson

  # --- doubles: every call is reported to the test process ---------------------------------------------------

  defmodule RecVault do
    @moduledoc false
    def reveal(%Samen.Masked{token: t}, repo, opts \\ []) do
      send(self(), {:reveal, t, repo, opts})
      {:ok, "plain-" <> to_string(t)}
    end

    def prefetch_rows(tokens, repo) do
      send(self(), {:prefetch, tokens, repo})
      Map.new(tokens, &{&1, :row})
    end
  end

  defmodule EmptyPrefetchVault do
    @moduledoc false
    def reveal(%Samen.Masked{token: t}, repo, opts \\ []) do
      send(self(), {:reveal, t, repo, opts})
      {:ok, "plain-" <> to_string(t)}
    end

    def prefetch_rows(_tokens, _repo), do: %{}
  end

  # A grant checker that implements the batch callback AND the single one; `verdict` rides in a pdict-free way
  # through the app env so one module serves true / false / truthy-non-true.
  defmodule Grant do
    @moduledoc false
    def verdict, do: Application.get_env(:samen_core, :__pii_planes_verdict, true)
    def granted_many(ctxs) do
      send(self(), {:many, ctxs})
      Enum.map(ctxs, fn _ -> verdict() end)
    end

    def granted?(ctx) do
      send(self(), {:one, ctx})
      verdict()
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:samen_core, :__pii_planes_verdict)
      Application.delete_env(:samen_core, :vault_repo)
    end)

    :ok
  end

  defp verdict!(v), do: Application.put_env(:samen_core, :__pii_planes_verdict, v)

  defp rec(token \\ "vt_a", id \\ Ecto.UUID.generate()),
    do: struct(@resource, %{id: id, emails: Masked.new(token, :emails)})

  defp tenant, do: %{plane: :tenant}
  defp operator, do: %{plane: :operator}
  defp impersonating, do: %{plane: :operator, impersonation: %{session_id: "s"}}

  defp resolve(records, actor, opts) do
    PiiResolution.resolve(
      List.wrap(records),
      @resource,
      actor,
      Keyword.merge([repo: :stub_repo, vault: RecVault, grant: Grant], opts)
    )
  end

  defp drain(tag, acc \\ []) do
    receive do
      msg when elem(msg, 0) == tag -> drain(tag, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ==========================================================================================================
  # which repo the resolver decrypts against
  # ==========================================================================================================

  describe "repo precedence (prepare/3)" do
    defp reveal_repo(opts) do
      q = Ash.Query.new(@resource) |> PiiResolution.prepare([vault: RecVault, grant: Grant] ++ opts, %{actor: tenant()})
      [hook] = q.after_action
      {:ok, [_]} = hook.(q, [rec()])
      assert_received {:reveal, _t, repo, _opts}
      repo
    end

    test "an explicit :repo opt beats the resource repo and the app default" do
      Application.put_env(:samen_core, :vault_repo, :env_repo)
      assert reveal_repo(repo: :explicit_repo) == :explicit_repo
    end

    test "with no opt, the resource's OWN repo beats the app default" do
      Application.put_env(:samen_core, :vault_repo, :env_repo)
      assert reveal_repo([]) == SamenCore.TestRepo
    end
  end

  # ==========================================================================================================
  # when the grant checker is consulted
  # ==========================================================================================================

  describe "grant consultation (prefetch)" do
    test "operator render consults the checker ONCE for the batch (positive control)" do
      [r] = resolve(rec(), operator(), [])
      assert r.emails == "plain-vt_a"
      assert [{:many, [%Samen.Reveal.Context{label: :emails}]}] = drain(:many)
      assert drain(:one) == []
    end

    test "the tenant plane never consults the checker" do
      assert [%{emails: "plain-vt_a"}] = resolve(rec(), tenant(), [])
      assert drain(:many) == []
      assert drain(:one) == []
    end

    test "an operator batch with nothing masked never consults the checker" do
      r = struct(@resource, %{id: Ecto.UUID.generate(), emails: nil})
      resolve(r, operator(), [])
      assert drain(:many) == []
      assert drain(:one) == []
    end

    test "egress consults the checker only with the host opt-in" do
      resolve(rec(), tenant(), egress: true)
      assert drain(:many) == []
      assert drain(:one) == []

      resolve(rec(), operator(), egress: true)
      assert drain(:many) == []
      assert drain(:one) == []

      resolve(rec(), tenant(), egress: true, grant_egress?: true)
      assert [{:many, [_]}] = drain(:many)
    end

    test "the egress opt-in alone does not make a NON-egress render consult the checker" do
      resolve(rec(), tenant(), grant_egress?: true)
      assert drain(:many) == []
      assert drain(:one) == []
    end
  end

  # ==========================================================================================================
  # which values the prefetch decrypts
  # ==========================================================================================================

  describe "prefetch decrypts exactly what resolve_field will" do
    defp prefetched_tokens do
      drain(:prefetch) |> Enum.flat_map(fn {:prefetch, tokens, _repo} -> tokens end)
    end

    test "tenant: every masked token is prefetched, deduplicated" do
      resolve([rec("vt_a"), rec("vt_a"), rec("vt_b")], tenant(), [])
      assert Enum.sort(prefetched_tokens()) == ["vt_a", "vt_b"]
    end

    test "operator: prefetched only when the grant verdict admits" do
      verdict!(true)
      resolve(rec("vt_a"), operator(), [])
      assert prefetched_tokens() == ["vt_a"]

      verdict!(false)
      assert [%Ash.ForbiddenField{}] = Enum.map(resolve(rec("vt_b"), operator(), []), & &1.emails)
      assert prefetched_tokens() == []
    end

    test "an unknown plane prefetches nothing, reveals nothing and does not raise" do
      for actor <- [%{plane: :weird}, %{}, nil] do
        assert [%{emails: %Masked{}}] = resolve(rec("vt_a"), actor, [])
        assert prefetched_tokens() == []
        refute_received {:reveal, _, _, _}
      end
    end

    test "egress: prefetched only for a LITERAL true verdict with the opt-in" do
      verdict!(true)
      resolve(rec("vt_t"), tenant(), egress: true, grant_egress?: true)
      assert prefetched_tokens() == ["vt_t"]
      drain(:reveal)

      verdict!(:yes)
      assert [%{emails: %Masked{}}] = resolve(rec("vt_y"), tenant(), egress: true, grant_egress?: true)
      assert prefetched_tokens() == []
      refute_received {:reveal, _, _, _}

      verdict!(true)
      assert [%{emails: %Masked{}}] = resolve(rec("vt_n"), tenant(), egress: true)
      assert prefetched_tokens() == []
    end

    test "no repo → the vault is never asked to prefetch" do
      resolve(rec(), tenant(), repo: nil)
      assert prefetched_tokens() == []
    end

    test "prefetched rows are handed to reveal only when there are some" do
      resolve(rec("vt_a"), tenant(), [])
      assert_received {:reveal, "vt_a", :stub_repo, [prefetched: %{"vt_a" => :row}]}

      resolve(rec("vt_e"), tenant(), vault: EmptyPrefetchVault)
      assert_received {:reveal, "vt_e", :stub_repo, []}
    end
  end

  # ==========================================================================================================
  # AI egress and the operator postures
  # ==========================================================================================================

  describe "egress and operator postures" do
    test "egress without the opt-in stays masked even when the checker would approve everything" do
      verdict!(true)
      assert [%{emails: %Masked{}}] = resolve(rec(), operator(), egress: true)
      refute_received {:reveal, _, _, _}
    end

    test "POSITIVE CONTROL: egress WITH the opt-in and a literal true grant resolves plaintext" do
      verdict!(true)
      assert [%{emails: "plain-vt_a"}] = resolve(rec(), operator(), egress: true, grant_egress?: true)
    end

    test "an operator API key without a grant is ABSENT; an impersonation is present-but-masked" do
      verdict!(false)
      assert [%{emails: %Ash.ForbiddenField{field: :emails}}] = resolve(rec(), operator(), [])
      assert [%{emails: %Ash.ForbiddenField{}}] = resolve(rec(), %{plane: :operator, impersonation: %{}}, [])
      assert [%{emails: %Ash.ForbiddenField{}}] = resolve(rec(), %{plane: :operator, impersonation: nil}, [])
      assert [%{emails: %Masked{}}] = resolve(rec(), impersonating(), [])
    end
  end
end
