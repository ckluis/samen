defmodule Samen.Masked do
  @moduledoc """
  `%Masked{}` — the vault field's **normal value** (ADR-001; doc §control:
  "masking is the field type's normal value — no CSV, API, or log path leaks by
  omission").

  A `Masked` value carries the vault **token** (the FK into the vault) and the
  field's declared label — but **never any plaintext**. There is therefore no
  plaintext to leak by any serialization path. Rendering is `"••••"`
  everywhere:

    - `String.Chars` (`to_string/1`, string interpolation) → `"••••"`
    - `Inspect` (`inspect/1`, logger `~p`) → `#Masked<••••>`
    - `Jason.Encoder` (JSON API / webhook payloads) → `"••••"`
    - `Phoenix.HTML.Safe` (HEEx `<%= @person.email %>`) → `"••••"` (Gate-0 fix
      task #1 — the one unmet acceptance clause from S0.5)
    - CSV / `IO.iodata` (`to_iodata/1`, CSV encoders that build iodata) → `"••••"`

  Plaintext exists *only* transiently inside `Samen.Vault.reveal/3` behind the
  `Samen.Reveal` grant seam (the single chokepoint), never inside a `Masked`
  struct. So even a hostile string interpolation of the field or
  `Jason.encode!(record)` cannot emit plaintext — it structurally isn't present.

  ## Phoenix.HTML.Safe (Gate-0 fix task #1)

  `Phoenix.HTML.Safe` has **no `Any` fallback** and **no `String.Chars`
  delegation**, so a HEEx `<%= @person.email %>` on a value that does not
  implement the protocol raises `Protocol.UndefinedError` — it does NOT fall
  back to `to_string/1`. S0.5 shipped `String.Chars`, `Inspect`, and
  `Jason.Encoder` but not `Phoenix.HTML.Safe`; the Gate-0 audit flagged the
  LiveView masking clause as the one unmet acceptance clause (fail-safe — a raise
  discloses nothing — but the clause "renders `••••` in LiveView" was untested
  and would not hold). This module closes that gap: `Samen.Masked` implements
  `Phoenix.HTML.Safe` so a HEEx render produces `"••••"` and never raises.

  `phoenix_html` is a real dependency of `samen_core` (see `mix.exs`), so the
  protocol module is always present at compile time and the `defimpl` below is
  always compiled. The `Code.ensure_loaded?/1` guard is retained as
  defence-in-depth so the library still compiles if a host strips the dep.

  ## Fail-closed on accidental plaintext

  There is exactly one function that returns plaintext for a subject:
  `Samen.Vault.reveal/3` (gated by `Samen.Reveal`). Any other attempt to coerce a
  `Masked` into a value yields the mask string `"••••"`. No serialization path can
  produce plaintext from a `Masked` value by construction (the struct carries no
  plaintext).
  """

  @mask "••••"

  @enforce_keys [:token, :label]
  defstruct token: nil, label: nil

  @type t :: %__MODULE__{token: String.t(), label: atom()}

  @doc "The canonical mask string."
  @spec mask() :: String.t()
  def mask, do: @mask

  @doc "Wrap a vault token as a masked field value."
  @spec new(String.t(), atom()) :: t()
  def new(token, label) when is_binary(token) and is_atom(label) do
    %__MODULE__{token: token, label: label}
  end

  @doc "Is this value the masked type? (structural guard used by verifiers/tests)"
  @spec masked?(term()) :: boolean()
  def masked?(%__MODULE__{}), do: true
  def masked?(_), do: false

  @doc """
  The mask as `IO.iodata` — the value CSV encoders and `IO.puts/1` /
  `IO.iodata_to_binary/1` consume. Covers the "CSV-ish IO.iodata" egress path
  (T1.5 acceptance (a)). Never contains plaintext.
  """
  @spec to_iodata(t()) :: iodata()
  def to_iodata(%__MODULE__{}), do: @mask

  defimpl String.Chars do
    def to_string(%Samen.Masked{}), do: Samen.Masked.mask()
  end

  defimpl Inspect do
    def inspect(%Samen.Masked{}, _opts) do
      # NEVER reveal the token or any plaintext in inspect output.
      "#Masked<" <> Samen.Masked.mask() <> ">"
    end
  end

  defimpl Jason.Encoder do
    def encode(%Samen.Masked{}, opts) do
      Jason.Encode.string(Samen.Masked.mask(), opts)
    end
  end

  # Phoenix.HTML.Safe implementation — Gate-0 fix task #1.
  #
  # Renders %Masked{} as the mask string in HEEx templates so
  # `<%= @person.email %>` renders "••••" and never raises Protocol.UndefinedError.
  #
  # `to_iodata/1` must return iodata that is ALREADY safe (Phoenix does not
  # re-escape a protocol impl's output). The mask string is fixed ASCII/UTF-8 with
  # no HTML-special characters, so returning it verbatim is correct and cannot
  # inject markup. We route through `Phoenix.HTML.Safe.to_iodata/1` on the mask
  # STRING so the escaping guarantee is inherited from Phoenix's own String impl
  # rather than asserted by hand.
  #
  # phoenix_html is a real dep (mix.exs); the guard is defence-in-depth for a host
  # that strips it (then the protocol simply isn't defined and HEEx isn't in use).
  if Code.ensure_loaded?(Phoenix.HTML.Safe) do
    defimpl Phoenix.HTML.Safe, for: Samen.Masked do
      def to_iodata(%Samen.Masked{}) do
        Phoenix.HTML.Safe.to_iodata(Samen.Masked.mask())
      end
    end
  end
end
