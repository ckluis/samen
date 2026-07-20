defmodule DriftwoodWeb.AuthController do
  @moduledoc """
  The Driftwood login/logout controller (F2 / ADR-031) — the BYO-auth reference surface that
  proves a real, day-1 login exists under the framework session seam.

  `GET /login` renders a minimal email+password form. `POST /login` verifies via
  `Driftwood.Auth` and, on success, establishes the authenticated session
  (`DriftwoodWeb.Auth.log_in_user/3` → framework principal + sticky current org) before
  redirecting into the app. `GET /logout` clears the session. A production deploy swaps the
  verifier + this form for `phx.gen.auth` or an IdP callback — the session seam is unchanged.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias DriftwoodWeb.Auth

  @default_return "/operator/accounts"

  def new(conn, params) do
    render_login(conn, 200, nil, params["return_to"])
  end

  def create(conn, %{"email" => email, "password" => password} = params) do
    case Driftwood.Auth.verify(email, password) do
      {:ok, user_id, org_ids} ->
        conn
        |> Auth.log_in_user(user_id, List.first(org_ids))
        |> redirect(to: safe_return(params["return_to"]))

      :error ->
        render_login(conn, 401, "Invalid email or password.", params["return_to"])
    end
  end

  def create(conn, params) do
    render_login(conn, 400, "Email and password are required.", params["return_to"])
  end

  def delete(conn, _params) do
    conn
    |> Auth.log_out_user()
    |> redirect(to: "/login")
  end

  # -- minimal, dependency-free HTML (values escaped) --------------------------

  defp render_login(conn, status, error, return_to) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, login_html(error, return_to))
  end

  defp login_html(error, return_to) do
    error_block =
      case error do
        nil -> ""
        msg -> ~s(<p style="color:#b91c1c;margin:0 0 12px">#{esc(msg)}</p>)
      end

    return_field =
      case return_to do
        rt when is_binary(rt) and rt != "" ->
          ~s(<input type="hidden" name="return_to" value="#{esc(rt)}">)

        _ ->
          ""
      end

    """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sign in · Driftwood</title></head>
    <body style="font-family:system-ui,sans-serif;background:#f6f7f9;margin:0">
      <main style="max-width:360px;margin:12vh auto;padding:28px 24px;background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.08)">
        <h1 style="font-size:20px;margin:0 0 4px">Sign in</h1>
        <p style="color:#6b7280;margin:0 0 18px;font-size:14px">Driftwood freight console</p>
        #{error_block}
        <form method="post" action="/login">
          #{return_field}
          <label style="display:block;font-size:13px;font-weight:600;margin-bottom:4px">Email</label>
          <input name="email" type="email" autocomplete="username" required
            style="width:100%;box-sizing:border-box;padding:9px 10px;margin-bottom:12px;border:1px solid #d1d5db;border-radius:8px">
          <label style="display:block;font-size:13px;font-weight:600;margin-bottom:4px">Password</label>
          <input name="password" type="password" autocomplete="current-password" required
            style="width:100%;box-sizing:border-box;padding:9px 10px;margin-bottom:18px;border:1px solid #d1d5db;border-radius:8px">
          <button type="submit"
            style="width:100%;padding:10px;border:0;border-radius:8px;background:#3B4CCA;color:#fff;font-weight:600;cursor:pointer">Sign in</button>
        </form>
      </main>
    </body></html>
    """
  end

  defp esc(v), do: v |> to_string() |> Plug.HTML.html_escape()

  # Same-origin absolute path only (no open redirect); anything else → the default.
  defp safe_return("/" <> rest = path) when rest != "" do
    if String.starts_with?(path, "//"), do: @default_return, else: path
  end

  defp safe_return(_), do: @default_return
end
