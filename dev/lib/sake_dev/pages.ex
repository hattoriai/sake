defmodule SakeDev.Pages do
  @moduledoc false
  # Three small HTML pages for the development server. No template engine:
  # plain string functions, escaping anything that came from a person.
  import Plug.Conn
  import Plug.HTML, only: [html_escape: 1]

  def home(conn) do
    user_id = get_session(conn, :user_id)

    signed_in =
      case user_id && SakeDev.Accounts.get(user_id) do
        {:ok, person} -> person
        _ -> nil
      end

    body = """
    <h1>sake-dev</h1>
    #{session_line(signed_in)}
    <h2>Endpoints</h2>
    <ul>
      <li><code>/mcp</code> — protected, resource <code>/mcp</code></li>
      <li><code>/acme/mcp</code> — protected, tenant "acme"</li>
      <li><code>/beta/mcp</code> — protected, tenant "beta"</li>
      <li><code>/open/mcp</code> — no authorization, any origin</li>
    </ul>
    <h2>Try it</h2>
    <pre>claude mcp add --transport http sake-dev http://localhost:4000/acme/mcp</pre>
    <p>Sign in as <code>ana@example.com</code> / <code>secret</code> when the browser opens.</p>
    """

    html(conn, page("sake-dev", body))
  end

  def login(conn, return_to, error \\ nil) do
    body = """
    <h1>Sign in</h1>
    #{error_line(error)}
    <form method="post" action="/login">
      <input type="hidden" name="return_to" value="#{html_escape(return_to || "/")}">
      <p><label>Email <input type="email" name="email" autofocus></label></p>
      <p><label>Password <input type="password" name="password"></label></p>
      <p><button type="submit">Sign in</button></p>
    </form>
    <p>Try <code>ana@example.com</code> / <code>secret</code>.</p>
    """

    html(conn, page("Sign in", body))
  end

  defp session_line(nil), do: "<p>Signed out. <a href=\"/login\">Sign in</a>.</p>"

  defp session_line(person) do
    """
    <p>Signed in as #{html_escape(person.name)} (#{html_escape(person.email)}).</p>
    <form method="post" action="/logout"><button type="submit">Sign out</button></form>
    """
  end

  defp error_line(nil), do: ""
  defp error_line(message), do: "<p style=\"color: crimson\">#{html_escape(message)}</p>"

  defp page(title, body) do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>#{html_escape(title)}</title>
        <style>body { font-family: sans-serif; max-width: 40rem; margin: 3rem auto; }</style>
      </head>
      <body>#{body}</body>
    </html>
    """
  end

  defp html(conn, body) do
    conn |> put_resp_content_type("text/html") |> send_resp(200, body)
  end
end
