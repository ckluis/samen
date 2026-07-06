defmodule Samen.DownCheckLayered.CreateWidget2 do
  # A NON-expand migration layered ON TOP of the expand (higher version). Stands in
  # for a scope-mount migration (e.g. AddIdentityScope) added after an expand. Not
  # phase-tagged, so it is not itself down-tested — but its presence above the expand
  # is what broke the old `:down, step: 1` stepping. DownCheck must still exercise the
  # expand's down/0 with this migration sitting on top.
  use Ecto.Migration

  def up do
    create table(:dcl_widget2, primary_key: false) do
      add(:dc2_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:dc2_name, :text, null: false)
    end
  end

  def down do
    drop(table(:dcl_widget2))
  end
end
