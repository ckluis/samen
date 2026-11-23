defmodule SamenCore.Support.ScanFaultApproval do
  @moduledoc """
  Test fixture: the REAL `apv_approval` table, read through a resource whose read FAILS only when the query projects
  specific columns (`Ash.Query.select/2`) — the shape of the reveal queue's orphan scan
  (`Samen.Approvals.subject_refs_with_approval/4` selects `[:subject_ref]`). Every other read (the pending list
  `Samen.Approvals.list_pending/3`, which selects everything) is healthy. It lets a test take down ONLY the scan and
  prove the queue then answers `{:error, :unavailable}` instead of a list that claims to be complete.

  Deliberately NOT in `:ash_domains` (like `SamenCore.Support.UnreadableApproval`); plain `Ash.Resource` so it does not
  claim a second `apv` abbrev.
  """
  use Ash.Resource,
    domain: SamenCore.Support.ScanFaultApproval.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  postgres do
    table "apv_approval"
    repo SamenCore.TestRepo
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, source: :apv_id, public?: true
    attribute :org_id, :uuid, public?: true, source: :apv_org_id
    attribute :kind, :string, public?: true, source: :apv_kind
    attribute :subject_ref, :string, public?: true, source: :apv_subject_ref
    attribute :requested_at, :utc_datetime_usec, public?: true, source: :apv_requested_at
    attribute :state, :atom, public?: true, source: :apv_state, constraints: [one_of: [:pending, :approved, :rejected, :expired, :cancelled]]
  end

  actions do
    read :read do
      primary? true
      prepare SamenCore.Support.ScanFaultApproval.FailProjectedRead
    end
  end
end

defmodule SamenCore.Support.ScanFaultApproval.FailProjectedRead do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    if is_list(query.select),
      do: Ash.Query.add_error(query, "scan fault: a column-projected read is down"),
      else: query
  end
end

defmodule SamenCore.Support.ScanFaultApproval.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SamenCore.Support.ScanFaultApproval)
  end
end
