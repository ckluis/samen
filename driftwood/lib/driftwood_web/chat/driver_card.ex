defmodule DriftwoodWeb.Chat.DriverCard do
  @moduledoc """
  Driftwood's bespoke object-unfurl card for `freight.driver` (ADR-012 §4.4 / §6.4) — the
  VERTICAL OVERRIDE SEAM, proven. Registered on the chat mount's `:object_cards` label (data,
  not a framework edit), so a `samen:freight.driver:<id>` pasted into a Driftwood chat message
  unfurls with a freight-shaped card: the driver's name (masked `••••` to the operator), CDL
  state, ELD provider, and a status pill.

  MASKING BY CONSTRUCTION: the record was ALREADY resolved for the viewer's plane by
  `Samen.Web.ObjectRef.resolve/3` (OrgScope + PiiResolution). This card only LAYS OUT resolved
  values through `Samen.Web.ObjectRef.FieldValue` (a `%Masked{}` passes through untouched). It
  never reads a column directly, never unwraps a mask, never reveals through the vault. The
  vaulted `full_name`/`cdl_number` therefore mask to `••••` on the operator plane by
  construction — the framework promise, in the vertical.
  """

  alias Samen.Web.ObjectRef.{Card, FieldValue}

  @spec card(String.t(), module(), struct()) :: Card.t()
  def card(key, _resource, driver) do
    fields =
      [
        {"CDL", FieldValue.generic(Map.get(driver, :cdl_number))},
        {"CDL state", FieldValue.generic(Map.get(driver, :cdl_state))},
        {"ELD", FieldValue.generic(Map.get(driver, :eld_provider))}
      ]
      |> Enum.reject(fn {_l, v} -> v in [nil, "—"] end)

    %Card{
      key: key,
      id: driver.id,
      title: FieldValue.full_name(Map.get(driver, :full_name)),
      subtitle: "Driver",
      fields: fields,
      badges: status_badge(Map.get(driver, :status)),
      icon: "D"
    }
  end

  defp status_badge(nil), do: []
  defp status_badge(:available), do: [{"ok", "available"}]
  defp status_badge(:on_load), do: [{"info", "on load"}]
  defp status_badge(:out_of_service), do: [{"warn", "out of service"}]
  defp status_badge(:terminated), do: [{"bad", "terminated"}]
  defp status_badge(other), do: [{"mut", to_string(other)}]
end
