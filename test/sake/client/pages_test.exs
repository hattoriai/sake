defmodule Sake.Client.PagesTest do
  # Paged lists, lazy enumeration and cache metadata (issue #96).
  use ExUnit.Case, async: true

  alias Sake.Client
  alias Sake.Client.Auth.Headless
  alias Sake.Client.{CacheInfo, Page, ReadResult}
  alias SakeTest.{FakeOAuth, HTTP}

  # A modern server whose lists come in pages of `size` from `entries`
  # (the cursor is the next entry's index), with `meta` merged into every
  # list and read result; `pages` overrides a page by cursor. Every
  # request it gets goes to the test as `{:request, method, params}`.
  defp serve(opts) do
    bypass = Bypass.open()
    test = self()

    config = %{
      entries: Keyword.get(opts, :entries, []),
      size: Keyword.get(opts, :size, 2),
      meta: Keyword.get(opts, :meta, %{}),
      pages: Keyword.get(opts, :pages, %{}),
      legacy: Keyword.get(opts, :legacy, false)
    }

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      msg = JSON.decode!(body)
      params = msg["params"] || %{}
      send(test, {:request, msg["method"], params})
      respond(conn, msg["id"], reply(msg["method"], params, config))
    end)

    "http://localhost:#{bypass.port}/mcp"
  end

  defp respond(conn, _id, :accepted), do: Plug.Conn.resp(conn, 202, "")

  defp respond(conn, id, reply) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("mcp-session-id", "s")
    |> Plug.Conn.resp(200, JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => id}, reply)))
  end

  defp reply("server/discover", _params, %{legacy: true}),
    do: %{"error" => %{"code" => -32_601, "message" => "Method not found"}}

  defp reply("server/discover", _params, _config),
    do: %{"result" => %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{}}}

  defp reply("initialize", _params, _config) do
    %{
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "l", "version" => "1"}
      }
    }
  end

  defp reply("notifications/" <> _, _params, _config), do: :accepted

  defp reply("resources/read", params, config) do
    contents = %{"contents" => [%{"uri" => params["uri"], "text" => "hi"}]}
    %{"result" => Map.merge(contents, config.meta)}
  end

  defp reply(method, params, config) do
    case Map.fetch(config.pages, params["cursor"]) do
      {:ok, page} ->
        page

      :error ->
        page = page(method, config.entries, config.size, params)
        %{"result" => Map.merge(page, config.meta)}
    end
  end

  defp page(method, entries, size, params) do
    key =
      case method do
        "tools/list" -> "tools"
        "resources/list" -> "resources"
        "resources/templates/list" -> "resourceTemplates"
        "prompts/list" -> "prompts"
      end

    from = String.to_integer(params["cursor"] || "0")
    chunk = entries |> Enum.drop(from) |> Enum.take(size) |> Enum.map(&entry(key, &1))
    page = %{key => chunk}

    if from + size < Enum.count(entries),
      do: Map.put(page, "nextCursor", "#{from + size}"),
      else: page
  end

  defp entry("tools", n), do: %{"name" => "t#{n}", "inputSchema" => %{"type" => "object"}}
  defp entry("resources", n), do: %{"uri" => "res://#{n}", "name" => "r#{n}"}
  defp entry("resourceTemplates", n), do: %{"uriTemplate" => "res://#{n}/{x}", "name" => "rt#{n}"}
  defp entry("prompts", n), do: %{"name" => "p#{n}"}

  defp list_requests(acc \\ []) do
    receive do
      {:request, method, params} when method != "server/discover" ->
        list_requests([{method, params["cursor"]} | acc])

      {:request, _, _} ->
        list_requests(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp connect(url, opts \\ []) do
    {:ok, session} = Client.connect(url, opts)
    _ = list_requests()
    session
  end

  describe "one page at a time" do
    test "the first page, then the next from its cursor, with the cache metadata" do
      url =
        serve(
          entries: 1..5,
          meta: %{"ttlMs" => 60_000, "cacheScope" => "public", "_meta" => %{"x" => 1}}
        )

      session = connect(url)

      assert {:ok, %Page{} = page, session} = Client.list_tools_page(session)
      assert Enum.map(page.entries, & &1.name) == ["t1", "t2"]
      assert page.next_cursor == "2"
      assert %CacheInfo{ttl_ms: 60_000, scope: :public} = page.cache
      assert page.meta == %{"x" => 1}
      assert CacheInfo.fresh?(page)

      assert {:ok, page, session} = Client.list_tools_page(session, page.next_cursor)
      assert Enum.map(page.entries, & &1.name) == ["t3", "t4"]

      assert {:ok, %Page{next_cursor: nil, entries: [%{name: "t5"}]}, session} =
               Client.list_tools_page(session, page.next_cursor)

      # The session knows every tool its pages showed, for call_tool/3.
      assert session.tools |> Map.keys() |> Enum.sort() == ~w(t1 t2 t3 t4 t5)
      assert list_requests() == [{"tools/list", nil}, {"tools/list", "2"}, {"tools/list", "4"}]
    end

    test "every list has its page call" do
      session =
        connect(serve(entries: 1..3, meta: %{"ttlMs" => 1_000, "cacheScope" => "private"}))

      assert {:ok, %Page{entries: [%{"uri" => "res://1"}, _], cache: %{scope: :private}}, session} =
               Client.list_resources_page(session)

      assert {:ok, %Page{entries: [%{"uriTemplate" => "res://3/{x}"}]}, session} =
               Client.list_resource_templates_page(session, "2")

      assert {:ok, %Page{entries: [%{"name" => "p1"}, %{"name" => "p2"}], next_cursor: "2"}, _} =
               Client.list_prompts_page(session)
    end

    test "a zero ttlMs is never fresh" do
      session = connect(serve(entries: [1], meta: %{"ttlMs" => 0, "cacheScope" => "public"}))

      assert {:ok, %Page{cache: %CacheInfo{ttl_ms: 0} = cache}, _} =
               Client.list_tools_page(session)

      refute CacheInfo.fresh?(cache)
    end

    test "freshness runs out after ttlMs" do
      cache = %CacheInfo{ttl_ms: 100, scope: :public, fetched_at: 1_000}
      assert CacheInfo.fresh?(cache, 1_099)
      refute CacheInfo.fresh?(cache, 1_100)
    end

    test "a legacy server's pages carry no cache metadata, and are never judged fresh" do
      session = connect(serve(entries: 1..3, legacy: true))
      assert session.era == :legacy

      assert {:ok, %Page{cache: %CacheInfo{ttl_ms: nil, scope: nil}} = page, _} =
               Client.list_tools_page(session)

      refute CacheInfo.fresh?(page)
    end

    test "an unknown cacheScope is taken as private, an invalid ttlMs as none" do
      session = connect(serve(entries: [1], meta: %{"ttlMs" => -5, "cacheScope" => "galaxy"}))

      assert {:ok, %Page{cache: %CacheInfo{ttl_ms: nil, scope: :private}}, _} =
               Client.list_tools_page(session)
    end
  end

  describe "reduce_list/5" do
    test "stops after a bounded number of entries, without fetching further pages" do
      session = connect(serve(entries: 1..100, size: 10))

      assert {:ok, names, _session} =
               Client.reduce_list(session, :tools, [], fn tool, acc ->
                 acc = [tool.name | acc]
                 if length(acc) == 15, do: {:halt, acc}, else: {:cont, acc}
               end)

      assert Enum.reverse(names) == Enum.map(1..15, &"t#{&1}")
      assert list_requests() == [{"tools/list", nil}, {"tools/list", "10"}]
    end

    test "goes through every page when it is not stopped, from a given cursor" do
      session = connect(serve(entries: 1..5))

      assert {:ok, uris, _} =
               Client.reduce_list(session, :resources, [], &{:cont, [&1["uri"] | &2]},
                 cursor: "2"
               )

      assert Enum.reverse(uris) == ["res://3", "res://4", "res://5"]
    end

    test "an error on a later page ends it, with the session" do
      error = %{"error" => %{"code" => -32_603, "message" => "boom"}}
      session = connect(serve(entries: 1..6, pages: %{"4" => error}))

      assert {:error, {:rpc, %{"message" => "boom"}}, session} =
               Client.reduce_list(session, :prompts, 0, fn _, n -> {:cont, n + 1} end)

      assert %Sake.Client.Session{} = session

      assert list_requests() == [
               {"prompts/list", nil},
               {"prompts/list", "2"},
               {"prompts/list", "4"}
             ]
    end

    test "a cursor that comes back again is a loop" do
      loop = %{"result" => %{"tools" => [], "nextCursor" => "same"}}
      session = connect(serve(pages: %{nil => loop, "same" => loop}))

      assert {:error, :pagination_loop, _} =
               Client.reduce_list(session, :tools, [], &{:cont, [&1 | &2]})
    end

    test "max_pages: bounds the pages fetched" do
      session = connect(serve(entries: 1..10, size: 1))

      assert {:error, :pagination_loop, _} =
               Client.reduce_list(session, :tools, [], &{:cont, [&1 | &2]}, max_pages: 3)

      assert length(list_requests()) == 3
    end
  end

  describe "the eager lists keep their contract" do
    test "every page, entries in order, as before" do
      session = connect(serve(entries: 1..5, meta: %{"ttlMs" => 5, "cacheScope" => "public"}))

      assert {:ok, tools, session} = Client.list_tools(session)
      assert Enum.map(tools, & &1.name) == ~w(t1 t2 t3 t4 t5)
      assert Map.keys(session.tools) |> Enum.sort() == ~w(t1 t2 t3 t4 t5)

      assert {:ok, [%{"uri" => "res://1"} | _] = resources, session} =
               Client.list_resources(session)

      assert length(resources) == 5
      assert {:ok, templates, session} = Client.list_resource_templates(session)
      assert length(templates) == 5
      assert {:ok, prompts, _} = Client.list_prompts(session)
      assert Enum.map(prompts, & &1["name"]) == ~w(p1 p2 p3 p4 p5)
    end
  end

  describe "read_resource_result/2" do
    test "the contents with the read's cache metadata" do
      url =
        serve(meta: %{"ttlMs" => 30_000, "cacheScope" => "private", "_meta" => %{"m" => true}})

      session = connect(url)

      assert {:ok, %ReadResult{contents: [content], cache: cache, meta: %{"m" => true}}, session} =
               Client.read_resource_result(session, "res://1")

      assert %Sake.Content{type: :resource, uri: "res://1"} = content
      assert %CacheInfo{ttl_ms: 30_000, scope: :private} = cache

      # read_resource/2 keeps returning the contents alone.
      assert {:ok, [^content], _} = Client.read_resource(session, "res://1")
    end

    test "a legacy read has no cache metadata" do
      session = connect(serve(legacy: true))

      assert {:ok, %ReadResult{cache: %CacheInfo{ttl_ms: nil, scope: nil}, meta: %{}}, _} =
               Client.read_resource_result(session, "res://1")
    end
  end

  describe "with authorization" do
    test "a token refreshed mid-enumeration is in the session it returns" do
      state = FakeOAuth.state()
      base = HTTP.start({FakeOAuth, [test: self(), state: state, tool_pages: 3]})

      {:ok, session} =
        Client.connect(base <> "/mcp", auth: [authorize: &Headless.authorize/1])

      before = session.auth.token["access_token"]

      # The server forgets every token after the first page: the second
      # page's request is refused, refreshed, and sent again.
      assert {:ok, names, session} =
               Client.reduce_list(session, :tools, [], fn tool, acc ->
                 if acc == [], do: Agent.update(state, &Map.put(&1, :tokens, %{}))
                 {:cont, [tool.name | acc]}
               end)

      assert Enum.reverse(names) == ~w(t1 t2 t3)
      assert session.auth.token["access_token"] != before

      # The refreshed token works on its own.
      assert {:ok, %Page{entries: [%{name: "t1"}]}, _} = Client.list_tools_page(session)
    end
  end
end
