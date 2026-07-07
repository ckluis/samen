defmodule Samen.CustomObjects.Domain do
  @moduledoc """
  The Ash domain that hosts the Tier-2 `tnt_record` resource
  (`Samen.CustomObjects.Record`).

  A single-resource domain: the tenant regime keeps ONE physical `tnt_record`
  table keyed by object, never a table per custom object (the vision doc rejects
  Twenty's runtime-DDL metadata architecture — §"Twenty CRM = a SPEC, not a
  dependency"). The object/field *catalog* tables (`tnt_object`/`tnt_field`) are
  plain DDL, not Ash resources, so they are not members of this domain.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.CustomObjects.Record)
  end
end
