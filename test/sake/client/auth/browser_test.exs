defmodule Sake.Client.Auth.BrowserTest do
  use ExUnit.Case, async: true
  alias Sake.Client.Auth.{Browser, Headless}

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp authorization_url(redirect_uri) do
    "https://auth.example.com/authorize?" <>
      URI.encode_query(%{"redirect_uri" => redirect_uri, "state" => "s"})
  end

  describe "Browser" do
    test "waits for the redirect on the loopback listener, past other requests" do
      redirect_uri = "http://127.0.0.1:#{free_port()}/callback"
      parent = self()

      # Stands in for the person's browser: it asks for a favicon first. It
      # reads the page after `authorize/2` has returned, so the test waits
      # for it, and hears of a failed request rather than of nothing.
      open = fn url ->
        send(parent, {:opened, url})

        Task.start(fn ->
          base = String.replace_suffix(redirect_uri, "/callback", "")
          send(parent, {:favicon, Req.get(base <> "/favicon.ico", retry: false)})
          send(parent, {:page, Req.get(redirect_uri <> "?code=c&state=s&iss=x", retry: false)})
        end)
      end

      url = authorization_url(redirect_uri)

      assert {:ok, %{"code" => "c", "state" => "s", "iss" => "x"}} =
               Browser.authorize(url, open: open)

      assert_received {:opened, ^url}
      assert_receive {:favicon, {:ok, %{status: 404}}}, 2_000
      assert_receive {:page, {:ok, %{status: 200, body: body}}}, 2_000
      assert body =~ "close this window"
    end

    test "gives up after the timeout and frees the port" do
      port = free_port()
      url = authorization_url("http://127.0.0.1:#{port}/callback")

      assert {:error, :timeout} = Browser.authorize(url, open: fn _ -> :ok end, timeout: 50)
      assert {:ok, socket} = :gen_tcp.listen(port, ip: {127, 0, 0, 1})
      :gen_tcp.close(socket)
    end

    test "needs a loopback redirect URI with a port" do
      for redirect_uri <- ["https://app.example.com/callback", "http://192.168.1.2:80/callback"] do
        assert {:error, {:not_loopback, ^redirect_uri}} =
                 Browser.authorize(authorization_url(redirect_uri),
                   open: fn _ -> flunk("opened") end
                 )
      end
    end
  end

  describe "Headless" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
    end

    defp redirect(bypass, location) do
      Bypass.expect_once(bypass, "GET", "/authorize", fn conn ->
        conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.resp(302, "")
      end)
    end

    test "reads the response from the redirect without following it", %{
      bypass: bypass,
      base: base
    } do
      redirect(bypass, "http://127.0.0.1:1/cb?code=c&state=s")

      url =
        base <> "/authorize?" <> URI.encode_query(%{"redirect_uri" => "http://127.0.0.1:1/cb"})

      assert {:ok, %{"code" => "c", "state" => "s"}} = Headless.authorize(url)
    end

    test "refuses a redirect anywhere but the redirect URI", %{bypass: bypass, base: base} do
      redirect(bypass, "/login?return_to=/authorize")

      url =
        base <> "/authorize?" <> URI.encode_query(%{"redirect_uri" => "http://127.0.0.1:1/cb"})

      assert {:error, {:unexpected_redirect, "/login?return_to=/authorize"}} =
               Headless.authorize(url)
    end

    test "refuses an answer that is not a redirect", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "GET", "/authorize", &Plug.Conn.resp(&1, 200, "<form>"))

      url =
        base <> "/authorize?" <> URI.encode_query(%{"redirect_uri" => "http://127.0.0.1:1/cb"})

      assert {:error, {:no_redirect, 200}} = Headless.authorize(url)
    end
  end
end
