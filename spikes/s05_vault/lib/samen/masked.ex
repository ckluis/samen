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
    - CSV: `to_string/1` is used by CSV encoders → `"••••"`

  Plaintext exists *only* transiently inside `Samen.Vault.reveal/2` (the single
  chokepoint), never inside a `Masked` struct. So even a hostile
  a hostile string interpolation of the field or `Jason.encode!(record)` cannot emit plaintext —
  it structurally isn't present.

  ## Fail-closed on accidental plaintext (red path c)

  There is exactly one function that returns plaintext for a subject:
  `Samen.Vault.reveal/2`. Any other attempt to coerce a `Masked` into a value
  yields the mask. `unmask!/1` exists ONLY for the reveal chokepoint to detect
  misuse: it raises unless called with the reveal capability token, so an
  "accidental plaintext interpolation" path is structurally detectable — see
  `Samen.Vault` and `test/plaintext_leak_test.exs`.
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
end
