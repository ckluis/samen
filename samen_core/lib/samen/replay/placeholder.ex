defmodule Samen.Replay.Placeholder do
  @moduledoc """
  What the replay PLAYER (ADR-052 §2.3) puts in a rebuilt assign where the recording holds no
  value it may show: a value recorded as shape only, a reference that no longer resolves, or a
  term the current code cannot decode.

  Kinds (a closed set, `kinds/0`):

    * `:redacted`     — recorded as shape only (`Samen.Replay.Redacted` other than `:masked`);
      renders `▒▒▒` with a length hint when one was recorded.
    * `:masked`       — a bare `%Samen.Masked{}` recorded label-only (ADR-052 §2.2.1 item 7: no
      token, no provenance, so it can never be resolved); renders `••••`.
    * `:shredded`     — a reference whose subject has been crypto-shredded; renders `[erased]`.
    * `:gone`         — a reference whose record the viewer can no longer read (deleted, or
      outside the viewer's org); renders `[gone]`.
    * `:code_changed` — a stored module, attribute or atom the loaded code no longer knows;
      renders `[changed]`.
    * `:dropped`      — a value the recorder dropped whole (a socket, a PID, a scope);
      renders nothing.
    * `:count`        — a LiveView stream or upload recorded as a count; renders `▒ n items`.

  It implements `Phoenix.HTML.Safe`, `String.Chars`, `Inspect` and `Jason.Encoder`, so a
  template that interpolates one renders the placeholder text and never raises. The text is a
  fixed string plus an integer — no recorded data reaches it.
  """

  @kinds [:redacted, :masked, :shredded, :gone, :code_changed, :dropped, :count]

  @enforce_keys [:kind]
  defstruct [:kind, :length]

  @type kind :: :redacted | :masked | :shredded | :gone | :code_changed | :dropped | :count
  @type t :: %__MODULE__{kind: kind(), length: non_neg_integer() | nil}

  @doc "The closed set of placeholder kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "A placeholder of `kind` (an unknown kind is `:code_changed`)."
  @spec new(atom(), non_neg_integer() | nil) :: t()
  def new(kind, length \\ nil)
  def new(kind, length) when kind in @kinds, do: %__MODULE__{kind: kind, length: hint(length)}
  def new(_kind, _length), do: %__MODULE__{kind: :code_changed}

  @doc "The placeholder's display text (fixed strings + an integer hint)."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{kind: :redacted, length: n}) when is_integer(n), do: "▒▒▒ (#{n})"
  def text(%__MODULE__{kind: :redacted}), do: "▒▒▒"
  def text(%__MODULE__{kind: :masked}), do: Samen.Masked.mask()
  def text(%__MODULE__{kind: :shredded}), do: "[erased]"
  def text(%__MODULE__{kind: :gone}), do: "[gone]"
  def text(%__MODULE__{kind: :code_changed}), do: "[changed]"
  def text(%__MODULE__{kind: :dropped}), do: ""
  def text(%__MODULE__{kind: :count, length: n}) when is_integer(n), do: "▒ #{n} items"
  def text(%__MODULE__{kind: :count}), do: "▒"
  def text(_), do: "[changed]"

  defp hint(n) when is_integer(n) and n >= 0, do: n
  defp hint(_), do: nil

  defimpl String.Chars do
    def to_string(p), do: Samen.Replay.Placeholder.text(p)
  end

  defimpl Inspect do
    def inspect(%Samen.Replay.Placeholder{kind: kind}, _opts),
      do: "#Placeholder<#{kind}>"
  end

  defimpl Jason.Encoder do
    def encode(p, opts), do: Jason.Encode.string(Samen.Replay.Placeholder.text(p), opts)
  end

  if Code.ensure_loaded?(Phoenix.HTML.Safe) do
    defimpl Phoenix.HTML.Safe, for: Samen.Replay.Placeholder do
      def to_iodata(p), do: Phoenix.HTML.Safe.to_iodata(Samen.Replay.Placeholder.text(p))
    end
  end
end
