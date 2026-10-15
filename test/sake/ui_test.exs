defmodule Sake.UITest do
  use ExUnit.Case, async: true

  defmodule SalesMap do
    use Sake.UI,
      uri: "ui://test/map",
      name: "map",
      title: "Map",
      description: "A map of the sales",
      scope: "sales:read",
      ttl: 60_000,
      csp: [
        connect_domains: ["https://api.example.com"],
        resource_domains: ["https://tiles.example.com"],
        frame_domains: ["https://video.example.com"],
        base_uri_domains: ["https://cdn.example.com"]
      ],
      permissions: [:camera, :microphone, :geolocation, :clipboard_write],
      domain: "a904794854a047f6.claudemcpcontent.com",
      prefers_border: false,
      meta: %{"vendor" => 1}

    @impl true
    def render(ctx), do: ["<!doctype html><p>", Sake.UI.escape(ctx.scope), "</p>"]
  end

  defmodule Plain do
    use Sake.UI, uri: "ui://test/plain"

    @impl true
    def render(_ctx), do: {:safe, ["<!doctype html>", ?<, "p>"]}
  end

  defmodule Board do
    use Sake.UI, uri: "ui://test/board", template: "ui/board.html.eex"

    @impl true
    def assigns(_ctx),
      do: %{title: "Q3 <draft>", items: ["a & b", "<i>"], script: "if (1 < 2) go();"}
  end

  defmodule Bare do
    use Sake.UI, uri: "ui://test/bare", template: "ui/board.html.eex"
  end

  test "a UI is a fixed resource with the MCP App MIME type and _meta.ui" do
    assert %Sake.Resource.Spec{
             module: SalesMap,
             uri: "ui://test/map",
             name: "map",
             title: "Map",
             mime_type: "text/html;profile=mcp-app",
             scopes: ["sales:read"],
             ttl: 60_000,
             template: false,
             subscribe: false,
             ui: true
           } = SalesMap.spec()

    assert SalesMap.spec().meta == %{
             "vendor" => 1,
             "ui" => %{
               "csp" => %{
                 "connectDomains" => ["https://api.example.com"],
                 "resourceDomains" => ["https://tiles.example.com"],
                 "frameDomains" => ["https://video.example.com"],
                 "baseUriDomains" => ["https://cdn.example.com"]
               },
               "permissions" => %{
                 "camera" => %{},
                 "microphone" => %{},
                 "geolocation" => %{},
                 "clipboardWrite" => %{}
               },
               "domain" => "a904794854a047f6.claudemcpcontent.com",
               "prefersBorder" => false
             }
           }

    assert Sake.Resource.Spec.to_wire(SalesMap.spec(), "2026-07-28") == %{
             "uri" => "ui://test/map",
             "name" => "map",
             "title" => "Map",
             "description" => "A map of the sales",
             "mimeType" => "text/html;profile=mcp-app",
             "_meta" => SalesMap.spec().meta
           }

    # Nothing to declare: no `_meta` at all.
    assert %Sake.Resource.Spec{name: "plain", meta: nil} = Plain.spec()
  end

  test "render/1 returns a string, iodata or {:safe, iodata}" do
    ctx = Sake.Context.new(scope: "<acme>")
    assert SalesMap.read(%{}, ctx) == {:ok, "<!doctype html><p>&lt;acme&gt;</p>"}
    assert Plain.read(%{}, ctx) == {:ok, "<!doctype html><p>"}
  end

  test "a template: compiles into render/1 and escapes what it outputs" do
    assert {:ok, html} = Board.read(%{}, Sake.Context.new())
    assert html =~ "<title>Q3 &lt;draft&gt;</title>"
    assert html =~ "<li>a &amp; b</li><li>&lt;i&gt;</li>"
    assert html =~ "<script>if (1 < 2) go();</script>"
    assert function_exported?(Board, :render, 1)

    assert_raise ArgumentError, ~r/assign @title not available/, fn ->
      Bare.read(%{}, Sake.Context.new())
    end
  end

  test "escape/1 and raw/1" do
    assert Sake.UI.escape(~s(<a href="x">'&'</a>)) ==
             "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;"

    assert Sake.UI.escape(nil) == ""
    assert Sake.UI.escape(42) == "42"
    assert Sake.UI.escape(~c"<b>") == "&lt;b&gt;"
    assert Sake.UI.escape(["<", {:safe, "<b>"}, nil]) == "&lt;<b>"
    assert Sake.UI.escape(Sake.UI.raw(["<b>", "</b>"])) == "<b></b>"
    assert Sake.UI.raw({:safe, "x"}) == {:safe, "x"}
  end

  test "supported?/1 needs the extension with the MCP App MIME type" do
    ctx = &Sake.Context.new(client_capabilities: &1)
    assert Sake.UI.supported?(ctx.(%{"extensions" => Sake.UI.client_capability()}))
    refute Sake.UI.supported?(ctx.(%{}))
    refute Sake.UI.supported?(ctx.(%{"extensions" => %{"io.modelcontextprotocol/ui" => %{}}}))

    refute Sake.UI.supported?(
             ctx.(%{"extensions" => %{"io.modelcontextprotocol/ui" => %{"mimeTypes" => []}}})
           )

    refute Sake.UI.supported?(
             ctx.(%{"extensions" => %{"io.modelcontextprotocol/ui" => %{"mimeTypes" => "x"}}})
           )
  end

  test "compile-time errors" do
    assert_raise ArgumentError, ~r/needs a ui:\/\/ uri/, fn ->
      defmodule NotUI do
        use Sake.UI, uri: "https://example.com/app"
        def render(_ctx), do: ""
      end
    end

    assert_raise ArgumentError, ~r/fixed uri, not a template/, fn ->
      defmodule Templated do
        use Sake.UI, uri: "ui://test/{id}"
        def render(_ctx), do: ""
      end
    end

    assert_raise ArgumentError, ~r/needs render\/1 or a template:/, fn ->
      defmodule Empty do
        use Sake.UI, uri: "ui://test/empty"
      end
    end

    assert_raise ArgumentError, ~r/render\/1 or a template:, not both/, fn ->
      defmodule Both do
        use Sake.UI, uri: "ui://test/both", template: "ui/board.html.eex"
        def render(_ctx), do: ""
      end
    end

    assert_raise ArgumentError, ~r/unknown csp entry :script_domains/, fn ->
      defmodule BadCsp do
        use Sake.UI, uri: "ui://test/csp", csp: [script_domains: ["https://x"]]
        def render(_ctx), do: ""
      end
    end

    assert_raise ArgumentError, ~r/unknown permission :usb/, fn ->
      defmodule BadPermission do
        use Sake.UI, uri: "ui://test/permission", permissions: [:usb]
        def render(_ctx), do: ""
      end
    end

    assert_raise File.Error, fn ->
      defmodule MissingTemplate do
        use Sake.UI, uri: "ui://test/missing", template: "ui/missing.html.eex"
      end
    end
  end

  describe "compiled from files" do
    @describetag :tmp_dir

    # Compiles `source` as Mix does, and returns the module's external
    # resources as Mix reads them: the files whose change recompiles it.
    defp compile(dir, name, source) do
      path = Path.join(dir, name <> ".ex")
      File.write!(path, source)
      parent = self()

      {:ok, [module], _} =
        Kernel.ParallelCompiler.compile([path],
          return_diagnostics: true,
          each_module: fn _file, module, _binary ->
            send(parent, {:external, Module.get_attribute(module, :external_resource)})
          end
        )

      assert_received {:external, external}
      {module, external}
    end

    test "inline/1 reads the file at compile time and recompiles when it changes", %{
      tmp_dir: dir
    } do
      js = Path.join(dir, "app.js")
      File.write!(js, "if (1 < 2) start();")

      source = """
      defmodule SakeTest.Inlined do
        use Sake.UI, uri: "ui://test/inlined"
        @impl true
        def render(_ctx), do: ["<script>", inline(#{inspect(js)}), "</script>"]
      end
      """

      {module, external} = compile(dir, "inlined", source)
      assert external == [js]
      assert {:ok, "<script>if (1 < 2) start();</script>"} = module.read(%{}, Sake.Context.new())

      # The document is the file as it was when the module compiled; the
      # recompile that a change of the file triggers picks up the new one.
      File.write!(js, "start();")
      assert {:ok, "<script>if (1 < 2) start();</script>"} = module.read(%{}, Sake.Context.new())
      :code.purge(module)
      :code.delete(module)
      {module, _} = compile(dir, "inlined", source)
      assert {:ok, "<script>start();</script>"} = module.read(%{}, Sake.Context.new())
    end

    test "a template and the files it inlines are external resources", %{tmp_dir: dir} do
      css = Path.join(dir, "app.css")
      File.write!(css, "p > b { color: red }")
      File.write!(Path.join(dir, "page.html.eex"), ~s[<style><%= raw inline("#{css}") %></style>])

      {module, external} =
        compile(dir, "templated", """
        defmodule SakeTest.Templated do
          use Sake.UI, uri: "ui://test/templated", template: "page.html.eex"
        end
        """)

      assert Enum.sort(external) == Enum.sort([Path.join(dir, "page.html.eex"), css])
      assert {:ok, "<style>p > b { color: red }</style>"} = module.read(%{}, Sake.Context.new())
    end
  end
end
