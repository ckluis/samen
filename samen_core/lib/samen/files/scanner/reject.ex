defmodule Samen.Files.Scanner.Reject do
  @moduledoc """
  The DEFAULT file scanner — fail-closed (ADR-026 §2, decision 3).

  `Reject` is not a real scanner; it is the honest "no scanner is wired" posture.
  Every scan returns `{:ok, :held}`, so `Samen.Files.promote/3` never promotes a file:
  a freshly uploaded file stays `:quarantined` (not previewable/downloadable) until an
  operator explicitly wires a real scanner — or the explicit `Samen.Files.Scanner.Noop`
  opt-in.

  This is the fail-closed analog of the delivery no-op: the framework does NOT pretend
  a file is clean. Returning `{:ok, :clean}` from this default would be exactly the
  tautological lie the `Samen.Files.Scanner` contract abolishes — and the promotion
  red-path (RP-FI-3) would catch it.
  """
  @behaviour Samen.Files.Scanner

  @impl Samen.Files.Scanner
  def scan(binary, _config) when is_binary(binary), do: {:ok, :held}
  def scan(_binary, _config), do: {:error, :invalid_argument}
end
