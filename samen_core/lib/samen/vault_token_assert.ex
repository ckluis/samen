defmodule Samen.VaultTokenAssert do
  @moduledoc """
  The ONE assertion for "no vault token in this text" (ADR-001 §6.2: a `vt_*` token must never reach a
  DOM, a CSV, an API body, a provider payload or an audit row).

  A bare `refute html =~ "vt_"` is not that assertion. A rendered page carries random URL-safe base64
  tokens — the CSRF token in every workspace-switcher form and `<meta name="csrf-token">`, the signed
  LiveView session and static tokens, LiveView element ids (`phx-…`) — whose alphabet includes `v`, `t`
  and `_`, so a page render contains `vt_` by chance now and then and the test fails once, then passes on the
  rerun. Measured: 7 of 100 000 renders (each in a fresh process, as each test is) of the operator
  Account detail page contained it.

  `leaks/1` is what a real leak looks like, with two arms:

    1. **grammar** — a string shaped like a token `Samen.Vault.generate_token/0` mints (`"vt_"` + 32
       lowercase hex, `Samen.Vault.tokens_in/1`) ANYWHERE in the text: in an element, an attribute, a
       `data-` value, a JSON string, even inside a CSRF value. A random base64 token contains 32 hex
       characters after `vt_` with probability (16/64)^32, about 5e-20: this arm has no false positives.
    2. **prefix** — the bare `"vt_"` marker the tests plant as a canary (`vt_realtoken`, `vt_secret_777`):
       any `vt_` left after the framework's own random tokens are blanked out. Only those carriers are
       blanked: the value of the `_csrf_token` input and the `csrf-token` meta, the `data-phx-session` /
       `data-phx-static` attributes and `id="phx-<random>"` attributes. Everywhere else the prefix still fails.

  So the helper is never weaker than the bare substring check on anything a test can plant outside those
  carriers, and a real token fails in every position. Presence is asserted with `assert_vault_token/2`
  (the grammar, exactly).
  """

  import ExUnit.Assertions, only: [flunk: 1]

  # The attributes whose VALUE is a random framework token. Blanked before the prefix arm looks.
  @csrf_tag ~r/<[a-zA-Z][^>]*\b(?:name="_csrf_token"|name="csrf-token")[^>]*>/
  @csrf_attr ~r/\b(value|content)="[^"]*"/
  @phx_attr ~r/\b(data-phx-(?:session|static|main|parent-id)|data-csrf)="[^"]*"/
  # Only an `id="phx-…"` ATTRIBUTE: a `phx-vt_…` word anywhere else (text, `data-id`, a class, JSON) is not a LiveView id.
  @phx_id ~r/(?<![\w-])id="phx-[A-Za-z0-9_-]{8,}"/

  @doc """
  The vault-token evidence in `text`: every grammar match (arm 1), then each prefix hit (arm 2) as a short
  snippet around it. `[]` means clean.
  """
  @spec leaks(iodata(), keyword()) :: [String.t()]
  def leaks(text, opts \\ []) do
    text = text!(text, "leaks/2")
    grammar = Samen.Vault.tokens_in(text)
    prefix = text |> blank_framework_tokens() |> prefix_hits(Keyword.get(opts, :boundary, false))
    Enum.uniq(grammar ++ prefix)
  end

  # Only text is checked: a binary or iodata. `nil`, an atom, a map or a number is NOT "no token" — a test that
  # passes the wrong thing (a field that is absent, a struct) must fail loudly, not pass because `to_string/1`
  # turned it into "". The test's subject has to be present first.
  defp text!(text, _who) when is_binary(text), do: text

  defp text!(text, who) when is_list(text) do
    IO.iodata_to_binary(text)
  rescue
    ArgumentError -> bad_input!(text, who)
  end

  defp text!(other, who), do: bad_input!(other, who)

  defp bad_input!(other, who) do
    flunk(
      "Samen.VaultTokenAssert.#{who} expects a binary or iodata, got #{inspect(other, limit: 5, printable_limit: 80)}" <>
        " — assert the field is present first, then check it for a token"
    )
  end

  @doc """
  `text` carries no vault token (see the moduledoc). Returns `text` so it pipes.

  `boundary: true` makes the prefix arm `\\bvt_`, for a page that legitimately renders identifiers ending in
  `vt_` (an `evt_…` event id): the grammar arm is unaffected, so a real token still fails.
  """
  @spec refute_vault_token(iodata(), String.t() | nil, keyword()) :: iodata()
  def refute_vault_token(text, message \\ nil, opts \\ []) do
    _ = text!(text, "refute_vault_token/3")

    case leaks(text, opts) do
      [] ->
        text

      found ->
        flunk(
          (message || "a vault token is present") <>
            "\n  vault token evidence: #{inspect(Enum.take(found, 3))}"
        )
    end
  end

  @doc """
  `text` carries a vault token of the real grammar (`"vt_"` + 32 lowercase hex): the presence twin of
  `refute_vault_token/2`, exact (a bare `"vt_"` somewhere does not satisfy it). Returns the tokens found.
  """
  @spec assert_vault_token(iodata(), String.t() | nil) :: [String.t()]
  def assert_vault_token(text, message \\ nil) do
    text = text!(text, "assert_vault_token/2")

    case Samen.Vault.tokens_in(text) do
      [] ->
        flunk(
          (message || "expected a vault token (vt_ + 32 hex)") <>
            "\n  in: #{inspect(String.slice(text, 0, 200))}"
        )

      tokens ->
        tokens
    end
  end

  @doc false
  # `text` with the framework's random tokens replaced by a neutral marker.
  @spec blank_framework_tokens(binary()) :: binary()
  def blank_framework_tokens(text) do
    text
    |> then(
      &Regex.replace(@csrf_tag, &1, fn tag -> Regex.replace(@csrf_attr, tag, ~s(\\1="~")) end)
    )
    |> then(&Regex.replace(@phx_attr, &1, ~s(\\1="~")))
    |> then(&Regex.replace(@phx_id, &1, ~s(id="phx-~")))
  end

  # Each `vt_` with 20 characters of context either side, so a failure shows WHERE.
  defp prefix_hits(text, boundary?) do
    re = if boundary?, do: ~r/.{0,20}\bvt_.{0,20}/s, else: ~r/.{0,20}vt_.{0,20}/s
    re |> Regex.scan(text) |> List.flatten() |> Enum.map(&String.trim/1)
  end
end
