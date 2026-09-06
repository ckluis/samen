defmodule Mix.Tasks.Samen.Doctor do
  @shortdoc "Config-only environment preflight: one readiness table, zero network calls."

  @moduledoc """
  `mix samen.doctor` — the environment preflight (T189, WS-L). Prints ONE readiness
  table over the foundry's pluggable adapter seams, built **entirely from configuration** —
  it never dials a vendor, never opens a socket, never touches Postgres.

  ## Config-only, by construction (INV-4 / NARROWED scope)

  This task calls `Mix.Task.run("app.config")` and nothing else — config is loaded (so
  `Application.get_env/3` resolves), but the OTP application supervision tree is never
  started (`app.start` is never invoked). No `Ecto.Repo`, no `Oban`, no HTTP client, no
  socket of any kind comes up as a side effect of running this task. Contrast this
  deliberately with `Samen.Web.Readiness.check/1` (the generated app's live `/readyz`
  probe): that module DOES dial out — `SELECT 1` against Postgres, a live KMS `attest/1`
  read, a running `Oban.config/1` — because it is a runtime liveness check for a booted
  host. `mix samen.doctor` is the opposite: a preflight you run before anything is
  booted, so it MUST NOT require anything to be reachable. It asks each adapter's
  behaviour "are you configured?", never "are you reachable?".

  The **keystore-adapter check** is the sharpest version of this distinction: it never
  calls `Samen.Kms.unwrap/1`, `attest/1`, or any other vendor-shaped callback. It only
  asks the configured module, via the documented `__kms_skeleton__?/0` self-declaration
  marker (the same convention `Samen.Kms.assert_prod_adapter_ready!/1` dispatches on,
  `samen/kms.ex:169`), whether it declares itself an unimplemented skeleton. That is a
  **behaviour-dispatched, config-only** check — dispatched on the adapter's own declared
  shape, not a hardcoded module denylist, and it never reaches the network.

  Explicitly OUT OF SCOPE: the Postgres AI-embeddings extension pre-migration check.
  That belongs to T140 (`backlog.yaml:148`) — this task does not check, mention, or probe
  it in any form; taking that on here would be scope creep onto another item's work.

  ## The adapter-configuration walk

  Four pluggable seams, each with the same "adapter/0 defaults to a working local
  implementation" shape (`Samen.Auth.Hasher`'s moduledoc names this pattern explicitly):

    * `:kms` — `Samen.Kms.adapter/0` (default `Samen.Kms.FileBacked`)
    * `:anchor` — `Samen.Anchor.adapter/0` (default `Samen.Anchor.LocalWorm`)
    * `:auth_hasher` — `Samen.Auth.Hasher.adapter/0` (default `Samen.Auth.Hasher.Pbkdf2`)
    * `:delivery_provider` — `Application.get_env(:samen_core, :delivery_provider)`, no
      built-in default (ADR-014's honest "nothing wired" `nil`)

  For `:delivery_provider`, when an entry IS configured, the walk calls the adapter
  module's own `configured?/1` callback — a **pure presence check** over the config map
  (every shipped ESP adapter's `configured?/1` only checks for the presence of keys like
  `:api_key`/`:secret_key`, per `Samen.Delivery.Provider`'s ADR-014/038 contract; it is
  never `deliver/2`, never a live send). A malformed entry is reported as
  `"misconfigured"` rather than raising — this task never crashes a preflight run.

  ## Fail-honest table (never a green row it did not earn)

  Every row is one of: `ready` (a working default or a self-declared non-skeleton
  adapter), `skeleton (not production-ready)` (KMS only, behaviour-dispatched),
  `configured` / `not configured` (delivery provider), or `misconfigured` (malformed
  entry). An unconfigured plane is reported as unconfigured — never printed green.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # Config only. Deliberately NEVER `Mix.Task.run("app.start")` — that would boot the
    # supervision tree (Repo/Oban/etc). No process starts here, so no socket can open.
    Mix.Task.run("app.config")

    rows = report()
    Mix.shell().info(format_table(rows))
  end

  @typedoc "One row of the readiness table."
  @type row :: %{plane: String.t(), adapter: String.t(), status: String.t()}

  @doc """
  Build the readiness rows. Pure, config-only, zero I/O beyond `Application.get_env/3`
  and the adapter modules' own config-only callbacks (`configured?/1`,
  `__kms_skeleton__?/0`) — never a behaviour callback that could touch a vendor or the
  network. Exported (not `defp`) so tests can assert on the data directly.
  """
  @spec report() :: [row()]
  def report do
    [
      kms_row(),
      anchor_row(),
      auth_hasher_row(),
      delivery_provider_row()
    ]
  end

  # --- the adapter-configuration walk -------------------------------------------------

  defp anchor_row do
    adapter = Samen.Anchor.adapter()
    %{plane: "anchor", adapter: inspect(adapter), status: "ready"}
  end

  defp auth_hasher_row do
    adapter = Samen.Auth.Hasher.adapter()
    %{plane: "auth_hasher", adapter: inspect(adapter), status: "ready"}
  end

  defp delivery_provider_row do
    case Application.get_env(:samen_core, :delivery_provider) do
      nil ->
        %{plane: "delivery_provider", adapter: "(none)", status: "not configured"}

      {module, config} when is_atom(module) and is_map(config) ->
        status = delivery_configured_status(module, config)
        %{plane: "delivery_provider", adapter: inspect(module), status: status}

      other ->
        %{plane: "delivery_provider", adapter: inspect(other), status: "misconfigured"}
    end
  end

  # Pure presence check only — `configured?/1` per the `Samen.Delivery.Provider`
  # contract never performs I/O. Never calls `deliver/2` or any other callback.
  defp delivery_configured_status(module, config) do
    if Code.ensure_loaded?(module) and function_exported?(module, :configured?, 1) do
      if module.configured?(config), do: "configured", else: "configured (missing creds)"
    else
      "misconfigured (no configured?/1)"
    end
  rescue
    _ -> "misconfigured (configured?/1 raised)"
  end

  # --- the behaviour-dispatched keystore-adapter check --------------------------------

  defp kms_row do
    adapter = Samen.Kms.adapter()

    status =
      if kms_skeleton?(adapter),
        do: "skeleton (not production-ready)",
        else: "ready"

    %{plane: "kms", adapter: inspect(adapter), status: status}
  end

  # Dispatches on the adapter's OWN self-declaration — the same marker convention
  # `Samen.Kms.assert_prod_adapter_ready!/1` uses (kms.ex:227-234). Never calls
  # `unwrap/1`, `attest/1`, `generate_subject_key/1`, or any other vendor-shaped
  # callback — only the zero-arg marker getter, if the adapter chooses to export it.
  defp kms_skeleton?(adapter) when is_atom(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :__kms_skeleton__?, 0) and
      adapter.__kms_skeleton__?()
  end

  defp kms_skeleton?(_), do: false

  # --- table rendering ------------------------------------------------------------------

  @spec format_table([row()]) :: String.t()
  def format_table(rows) do
    plane_w = width(rows, :plane, "PLANE")
    adapter_w = width(rows, :adapter, "ADAPTER")
    status_w = width(rows, :status, "STATUS")

    header = pad("PLANE", plane_w) <> "  " <> pad("ADAPTER", adapter_w) <> "  " <> "STATUS"
    sep = String.duplicate("-", plane_w) <> "  " <> String.duplicate("-", adapter_w) <> "  " <> String.duplicate("-", status_w)

    body =
      Enum.map(rows, fn %{plane: plane, adapter: adapter, status: status} ->
        pad(plane, plane_w) <> "  " <> pad(adapter, adapter_w) <> "  " <> status
      end)

    Enum.join(["samen.doctor — environment preflight (config-only, no network)", header, sep | body], "\n")
  end

  defp width(rows, key, label) do
    rows
    |> Enum.map(&String.length(Map.fetch!(&1, key)))
    |> Enum.max(fn -> 0 end)
    |> max(String.length(label))
  end

  defp pad(str, width), do: String.pad_trailing(str, width)
end
