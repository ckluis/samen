defmodule Samen.Replay.Ref do
  @moduledoc """
  A captured vault-routed attribute, recorded **by reference** (ADR-052 §2.2 rule 1).

  The sanitizer replaces every vault-routed attribute of an Ash record with one of these:
  the resource, the record's primary key, the attribute name and its label. The value itself
  — plaintext on the tenant plane, a `%Samen.Pii.Plaintext{}` in flight, a `%Samen.Masked{}`
  token — is never captured. The P3 player resolves a `Ref` at view time, on the VIEWER's
  plane, through `Samen.Api.PiiResolution`.
  """
  @enforce_keys [:resource, :attribute]
  defstruct [:resource, :pk, :attribute, :label]

  @type t :: %__MODULE__{
          resource: String.t(),
          pk: String.t() | integer() | nil,
          attribute: atom(),
          label: atom()
        }
end

defmodule Samen.Replay.Redacted do
  @moduledoc """
  A captured value whose content was dropped and whose SHAPE was kept (ADR-052 §2.2 rule 1).

  `kind` is a closed set (`kinds/0`); `length` is the value's length where that is a
  meaningful shape (a string's codepoint count, a map's size); `label` is a code-defined
  label (a vault field's declared label for a bare `%Samen.Masked{}`), never data.
  """
  @kinds [:free_text, :string, :binary, :atom, :masked, :vault_plaintext, :charlist]

  @enforce_keys [:kind]
  defstruct [:kind, :length, :label]

  @type kind ::
          :free_text | :string | :binary | :atom | :masked | :vault_plaintext | :charlist
  @type t :: %__MODULE__{kind: kind(), length: non_neg_integer() | nil, label: atom() | nil}

  @doc "The closed set of redaction kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds
end

defmodule Samen.Replay.Dropped do
  @moduledoc """
  A captured value that was dropped whole: a scope, an actor, a socket, a PID, a function, an
  unknown struct, a form, or something the sanitizer could not walk. `struct` names the
  struct MODULE (a code identifier) when the value was a struct, so a player can say what was
  there without showing it.
  """
  @kinds [
    :scope,
    :actor,
    :socket,
    :pid,
    :port,
    :reference,
    :function,
    :struct,
    :not_loaded,
    :depth,
    :budget,
    :sanitizer_error
  ]

  @enforce_keys [:kind]
  defstruct [:kind, :struct]

  @type t :: %__MODULE__{kind: atom(), struct: String.t() | nil}

  @doc "The closed set of drop kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds
end

defmodule Samen.Replay.Kept do
  @moduledoc """
  A string kept verbatim because the view DECLARED its assign key on the replay keep-list
  (`use Samen.Replay, keep_assigns: [...]`) and it passed the bounded checks (length cap, not
  email/SSN/phone-shaped). The only way free text reaches a frame.
  """
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}
end

defmodule Samen.Replay.Id do
  @moduledoc "A bare UUID string, kept as an id (ADR-052 §2.2 rule 1: ids are kept)."
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}
end

defmodule Samen.Replay.Record do
  @moduledoc """
  A captured Ash record: its resource, primary key and the per-attribute decisions of the
  sanitizer (`Ref` for vault-routed attributes, the value for attributes the ADR-015 CDC
  classifier would project, `Redacted{kind: :free_text}` for the rest).
  """
  @enforce_keys [:resource, :fields]
  defstruct [:resource, :pk, :fields]

  @type t :: %__MODULE__{resource: String.t(), pk: term(), fields: map()}
end

defmodule Samen.Replay.Count do
  @moduledoc "A LiveView stream or upload, recorded as a count only (ADR-052 §7)."
  @enforce_keys [:kind, :n]
  defstruct [:kind, :n]

  @type t :: %__MODULE__{kind: :stream | :upload | :streams | :uploads, n: non_neg_integer()}
end

defmodule Samen.Replay.More do
  @moduledoc "The tail of a list or map cut by the sanitizer's size cap: `n` elements not walked."
  @enforce_keys [:n]
  defstruct [:n]

  @type t :: %__MODULE__{n: non_neg_integer()}
end

defmodule Samen.Replay.Shape do
  @moduledoc """
  Event or URL params recorded as SHAPE, not content (ADR-052 §2.2 rule 2, D3).

  `fields` is a list of `%{key, type, length, class}` maps, plus `value` only when the key is
  on the event's declared keep-list and the value is a bounded label, integer or boolean.
  A nested map carries its own `fields`.
  """
  @enforce_keys [:fields]
  defstruct [:fields, more: 0]

  @type t :: %__MODULE__{fields: [map()], more: non_neg_integer()}
end
