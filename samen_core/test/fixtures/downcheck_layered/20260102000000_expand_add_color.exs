defmodule Samen.DownCheckLayered.ExpandAddColor do
  # A well-formed EXPAND migration whose down/0 DownCheck must exercise even though a
  # NON-expand migration (create_widget2, v20260103…) is layered ON TOP of it. This is
  # the regression scenario: mounting the Identity scope added a plain migration with a
  # LATER version than the expand, and the old `:down, step: 1` peeled the newer
  # (non-expand) migration instead of this expand. The `:down, to: version - 1` fix
  # rolls the stack down THROUGH this expand regardless of what sits above it.
  use Samen.Migration, phase: :expand

  def change do
    expand_setup()
    add_nullable_column(:dcl_widget, :dcl_color, :text)
  end
end
