defmodule Samen.Context.Alias do
  @moduledoc """
  A single `alias_resource Kernel, as: Name` entry (T3.10).

  `resource` is the kernel resource being re-identified; `as` is the vertical's
  ubiquitous-language name for it. This is a NAME mapping only — it deliberately
  does not carry a second Ash resource, so the kernel's policies/vault/audit
  cannot be widened or bypassed by the rename.
  """
  defstruct [:resource, :as, __spark_metadata__: nil]

  @type t :: %__MODULE__{resource: module(), as: module()}
end

defmodule Samen.Context.Calculation do
  @moduledoc """
  A single reshape `calculate name, type, expr(...)` entry (T3.10).

  A derived (computed) field over the kernel resource's existing columns. `expr`
  is the quoted expression captured at compile time and replayed via
  `Ash.Query.calculate/8` at query time. It never declares physical storage.
  """
  defstruct [:name, :type, :expr, __spark_metadata__: nil]

  @type t :: %__MODULE__{name: atom(), type: term(), expr: Macro.t()}
end

defmodule Samen.Context.Reshape do
  @moduledoc """
  A `reshape Kernel do … end` block (T3.10): a set of derived calculations against
  ONE kernel resource. `calculations` is the list of `Samen.Context.Calculation`
  entries declared inside the block.
  """
  defstruct resource: nil, calculations: [], __spark_metadata__: nil

  @type t :: %__MODULE__{resource: module(), calculations: [Samen.Context.Calculation.t()]}
end
