defmodule Samen.MaskingCase do
  @moduledoc """
  Per-plane masking-test helpers (WS-E E2i.1) — the green/red/sabotage assertion
  shape from the shipped masking red-paths (WS-A notifications inbox, WS-E E2.2
  file preview), encoded as a helper library so every new PII surface (E3 CSV
  export, E4 search projection, E5 profile self-edit, E7.2 flagship probe) writes
  the SAME non-vacuous three-part proof instead of re-deriving it by hand.
  Sibling of `Samen.RedPath`/`Samen.Factory` (WS-D D1): test infra shipped in
  lib so hosts and verticals consume it too.

  ## The per-plane masking-test pattern (masking watch-list discipline)

  Every surface that renders a vault-routed (🔒) field ships THREE proofs:

    1. **GREEN** — the tenant plane (and operator-WITH-grant) resolves the field
       CLEAR: the plaintext, not a `%Samen.Masked{}`. → `assert_plane_clear!/2`
    2. **RED** — the operator-without-grant plane resolves to `%Samen.Masked{}`:
       renders `••••`, NEVER the plaintext, NEVER a `vt_*` vault token.
       → `assert_plane_masked!/2`, `assert_masked_dom!/2`, `assert_two_plane!/3`
    3. **SABOTAGE twin (anti-tautology)** — the red assertion is REFUTABLE: the
       same record flipped to the tenant plane goes clear (the resolver is the
       gate, not a blanket mask), and a deliberately-leaked render IS detected
       by the same scan. → `assert_leak_detected!/2` + a plane flip via
       `resolve_on_plane/4`

  A masking test with only half of this is vacuous — see the reference
  consumers: `samen_web/test/samen/web/file_preview_masking_test.exs` (first
  consumer, WS-E E2.2) and `samen_web/test/samen/web/notifications_masking_test.exs`.

  ## Usage

      use Samen.MaskingCase   # imports the helpers below

      resolved = resolve_on_plane(record, MyApp.Notification, :operator,
                   repo: MyApp.Repo, grant: DenyAllGrant)
      assert_plane_masked!(resolved.rendered_body, @secret)

  `resolve_on_plane/4` runs `Samen.Api.PiiResolution.resolve/4` — the SAME seam
  every framework read surface (`Samen.Web.Files.Reads`, list/detail Reads, CSV
  export cells, search projections) resolves through — with the canonical
  per-plane actor shape (`plane_actor/1`).
  """

  import ExUnit.Assertions

  alias Samen.Masked

  @mask "••••"

  defmacro __using__(_opts) do
    quote do
      import Samen.MaskingCase
    end
  end

  @doc "The canonical mask string a `%Samen.Masked{}` renders as."
  def mask, do: @mask

  @doc """
  The canonical per-plane actor for masking tests: `:tenant` → the org's own
  plane (PII clear); `:operator` → an impersonating operator (PII masked unless
  a reveal grant covers the subject).
  """
  def plane_actor(:tenant), do: %{plane: :tenant}

  def plane_actor(:operator),
    do: %{plane: :operator, impersonation: %{session_id: "op-session"}}

  @doc """
  Resolve one record through `Samen.Api.PiiResolution.resolve/4` on `plane` —
  the same seam the framework read surfaces run on every result. `opts` pass
  through to the resolver (`:repo` required; `:grant` injects the reveal
  authority for operator cases).
  """
  def resolve_on_plane(record, resource, plane, opts \\ []) do
    [resolved] = Samen.Api.PiiResolution.resolve([record], resource, plane_actor(plane), opts)
    resolved
  end

  @doc """
  GREEN half: the resolved value on this plane is the CLEAR plaintext — equal to
  `plaintext` and not a `%Samen.Masked{}`. Returns the value.
  """
  def assert_plane_clear!(value, plaintext) do
    assert value == plaintext,
           "expected the plane to resolve CLEAR to #{inspect(plaintext)}, got: #{inspect(value)}"

    refute match?(%Masked{}, value)
    value
  end

  @doc """
  RED half: the resolved value on the operator-without-grant plane is a
  `%Samen.Masked{}` — renders exactly `••••`, never the plaintext, never a
  `vt_*` vault token. Pass the plaintext (when known) so the not-the-plaintext
  refutation is explicit. Returns the value.
  """
  def assert_plane_masked!(value, plaintext \\ nil) do
    assert match?(%Masked{}, value),
           "expected a %Samen.Masked{} on the operator plane, got: #{inspect(value)}"

    if plaintext != nil, do: refute(value == plaintext)
    assert to_string(value) == @mask
    refute to_string(value) =~ "vt_"
    value
  end

  @doc """
  Both directions on the SAME record — tenant clear ∧ operator masked. The only
  difference between the two reads is the plane, so this is the anti-tautology
  proof that masking is the resolver's per-plane decision.
  """
  def assert_two_plane!(tenant_value, operator_value, plaintext) do
    assert tenant_value == plaintext
    refute match?(%Masked{}, tenant_value)
    refute operator_value == plaintext
    assert to_string(operator_value) == @mask
    :ok
  end

  @doc """
  DOM green half for a masked render: the mask string is present; every entry
  in `plaintexts` is ABSENT (mask-by-omission); no `vt_*` vault token anywhere
  in the DOM. Returns the html.
  """
  def assert_masked_dom!(html, plaintexts) do
    assert html =~ @mask, "expected the masked render to show #{@mask}"

    Enum.each(List.wrap(plaintexts), fn plaintext ->
      refute html =~ plaintext,
             "mask-by-omission FAILED: plaintext #{inspect(plaintext)} leaked into the DOM"
    end)

    refute html =~ "vt_", "a vt_* vault token leaked into the DOM"
    html
  end

  @doc """
  SABOTAGE twin: prove the mask scan is refutable — a render fed the LEAKED
  plaintext (a modeled broken resolver) IS caught by the same scan that the
  masked render passes. A `refute html =~ plaintext` that could never fail is a
  tautology; this makes the flip explicit.
  """
  def assert_leak_detected!(leaked_html, plaintext) do
    assert leaked_html =~ plaintext,
           "the sabotage render was expected to LEAK #{inspect(plaintext)} (proving the " <>
             "mask scan is refutable), but the leak was not present — the sabotage is vacuous"

    leaked_html
  end
end
