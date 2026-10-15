defmodule Sake.Client.Auth.Browser do
  @moduledoc """
  Authorizes in the person's browser: opens the authorization URL with the
  system's opener (`open` on macOS, `xdg-open` elsewhere on Unix,
  `rundll32` on Windows) and waits for the redirect on a one-shot HTTP
  listener at the redirect URI's loopback address and port (RFC 8252
  §7.3). The default in `Sake.Client.Auth`.

  The redirect URI must be plain `http` on `127.0.0.1`, `[::1]` or
  `localhost` (which listens on `127.0.0.1`; RFC 8252 §8.3 prefers the
  literal address), with the port the listener can bind. The listener
  answers the browser with a short page saying the window can be closed,
  and stops after the redirect or after five minutes.

      auth: [authorize: &Sake.Client.Auth.Browser.authorize(&1, timeout: 120_000)]
  """

  require Logger

  @timeout 300_000
  @read_timeout 5_000

  @page """
  <!doctype html>
  <meta charset="utf-8">
  <title>Authorization</title>
  <p>The app has received the answer. You can close this window.</p>
  """

  @doc """
  Opens `url` and returns the parameters of the redirect. `opts`:
  `timeout:` (milliseconds, default five minutes), `open:` (a function of
  the URL that shows it to the person, instead of the system's opener).
  """
  @spec authorize(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def authorize(url, opts \\ []) do
    redirect =
      url |> URI.parse() |> Map.get(:query) |> Kernel.||("") |> URI.decode_query()

    with {:ok, redirect} <- loopback(redirect["redirect_uri"]),
         {:ok, socket} <- listen(redirect) do
      try do
        open = Keyword.get(opts, :open, &open/1)
        _ = open.(url)
        deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @timeout)
        accept(socket, redirect.path || "/", deadline)
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp loopback(redirect_uri) when is_binary(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "http", host: host, port: port} = uri
      when host in ["127.0.0.1", "localhost", "::1"] and is_integer(port) and port > 0 ->
        {:ok, uri}

      _ ->
        {:error, {:not_loopback, redirect_uri}}
    end
  end

  defp loopback(redirect_uri), do: {:error, {:not_loopback, redirect_uri}}

  defp listen(%URI{host: host, port: port}) do
    ip = if host == "::1", do: [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}], else: [ip: {127, 0, 0, 1}]

    case :gen_tcp.listen(port, [:binary, active: false, packet: :http_bin, reuseaddr: true] ++ ip) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:listen, port, reason}}
    end
  end

  # One connection at a time until the redirect arrives: a browser may ask
  # for something else first (a favicon), which gets a 404.
  defp accept(socket, path, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0 || {:error, :timeout},
         {:ok, conn} <- :gen_tcp.accept(socket, remaining) do
      case read(conn) do
        {:ok, ^path, query} ->
          respond(conn, "200 OK", @page)
          {:ok, URI.decode_query(query)}

        _ ->
          respond(conn, "404 Not Found", "")
          accept(socket, path, deadline)
      end
    end
  end

  defp read(conn) do
    case :gen_tcp.recv(conn, 0, @read_timeout) do
      {:ok, {:http_request, :GET, {:abs_path, target}, _version}} ->
        drain(conn)
        uri = URI.parse(target)
        {:ok, uri.path, uri.query || ""}

      _ ->
        :error
    end
  end

  defp drain(conn) do
    case :gen_tcp.recv(conn, 0, @read_timeout) do
      {:ok, {:http_header, _, _, _, _}} -> drain(conn)
      _ -> :ok
    end
  end

  defp respond(conn, status, body) do
    _ =
      :gen_tcp.send(conn, [
        "HTTP/1.1 ",
        status,
        "\r\ncontent-type: text/html; charset=utf-8\r\ncache-control: no-store",
        "\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\nconnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(conn)
  end

  # The URL is passed as one argument, never through a shell: an `&` in
  # the query must not end the command.
  defp open(url) do
    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:win32, _} -> {"rundll32", ["url.dll,FileProtocolHandler", url]}
        _ -> {"xdg-open", [url]}
      end

    with path when is_binary(path) <- System.find_executable(command),
         {_, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
      :ok
    else
      _ -> Logger.warning("Sake.Client: open this URL to authorize: #{url}")
    end
  end
end
