defmodule Samen.Web.Auth.TotpPending do
  @moduledoc """
  The not-yet-confirmed TOTP secret of an in-progress enrolment, kept STABLE across the mounts of
  `Samen.Web.Auth.TotpEnrollLive` (eval 2026-11-13 tenant-b F14).

  The page used to generate a fresh secret on every `mount/3` — the dead render, the connected
  render, and every socket reconnect — so a user who scanned the QR code and whose socket then
  reconnected was asked to verify a code against a DIFFERENT secret than the one in their
  authenticator app.

  One secret per credential is held here for `#{15} minutes` (an enrolment attempt) and dropped on
  confirm or disable. It lives ONLY in this node's process memory (a protected ETS table owned by
  this GenServer) — the same class of storage as the LiveView socket assigns it replaces. It is
  never written to the database, a cookie, the session, a URL or a log, so it is no less protected
  than before: it still only reaches the database through `Samen.Identity.Totp.enroll/4`, vaulted,
  after a valid code. (Single-node by design: a reconnect that lands on another node starts a new
  attempt, exactly as before.)

  If the table is unavailable (the supervisor is not running) `fetch_or_create/1` degrades to a
  fresh unstored secret — the old behaviour, never a crash.
  """
  use GenServer

  @table __MODULE__
  @ttl_ms :timer.minutes(15)

  alias Samen.Web.Auth.Totp

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The pending secret for `credential_id`, minted on first use and reused until it expires or is dropped."
  @spec fetch_or_create(String.t() | nil) :: binary()
  def fetch_or_create(credential_id) when is_binary(credential_id) do
    case lookup(credential_id) do
      {:ok, secret} -> secret
      :error -> GenServer.call(__MODULE__, {:create, credential_id})
    end
  catch
    :exit, _ -> Totp.generate_secret()
  end

  def fetch_or_create(_), do: Totp.generate_secret()

  @doc "Forget the pending secret (after a confirmed enrolment, or a disable)."
  @spec drop(String.t() | nil) :: :ok
  def drop(credential_id) when is_binary(credential_id) do
    GenServer.call(__MODULE__, {:drop, credential_id})
  catch
    :exit, _ -> :ok
  end

  def drop(_), do: :ok

  defp lookup(credential_id) do
    case :ets.lookup(@table, credential_id) do
      [{^credential_id, secret, expires_at}] ->
        if expires_at > now(), do: {:ok, secret}, else: :error

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, credential_id}, _from, state) do
    # Re-check under the serialising process: two mounts racing must get the same secret.
    secret =
      case lookup(credential_id) do
        {:ok, secret} ->
          secret

        :error ->
          secret = Totp.generate_secret()
          :ets.insert(@table, {credential_id, secret, now() + @ttl_ms})
          sweep()
          secret
      end

    {:reply, secret, state}
  end

  def handle_call({:drop, credential_id}, _from, state) do
    :ets.delete(@table, credential_id)
    {:reply, :ok, state}
  end

  defp sweep do
    t = now()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", t}], [true]}])
  end
end
