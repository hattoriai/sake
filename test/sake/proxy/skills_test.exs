defmodule Sake.Proxy.SkillsTest do
  # Proxies are named processes, started with each test's upstream URL.
  use ExUnit.Case, async: false

  import Sake.Test

  alias SakeTest.HTTP

  defmodule RunReport do
    use Sake.Skill, dir: "../skills/run-report"
  end

  defmodule Hidden do
    @moduledoc false
    # The upstream serves this skill without listing it.
    use Sake.Skill.Catalog

    @impl true
    def list(_ctx), do: []

    @impl true
    def fetch("hidden", _ctx) do
      Sake.Skill.build(%{"SKILL.md" => "---\nname: hidden\ndescription: Unlisted\n---\n"})
    end

    def fetch(_path, _ctx), do: :error
  end

  defmodule Upstream do
    use Sake.Server, name: "skills-upstream", version: "1"
    skills [RunReport, Hidden]
  end

  defmodule Router do
    use Plug.Router
    plug :match
    plug :dispatch

    forward "/mcp",
      to: Sake.Plug,
      init_opts: [server: Sake.Proxy.SkillsTest.Upstream, secret: String.duplicate("u", 64)]
  end

  defmodule Proxy do
    use Sake.Proxy,
      name: "skills-proxy",
      version: "1",
      upstream: "http://127.0.0.1:1/mcp",
      skills: true
  end

  defmodule Silent do
    use Sake.Proxy, name: "silent-proxy", version: "1", upstream: "http://127.0.0.1:1/mcp"
  end

  defmodule Gateway do
    use Sake.Server, name: "gateway", version: "1"
    skills [RunReport]
    mount Proxy, prefix: "up"
  end

  @skill_md File.read!(Path.expand("../skills/run-report/SKILL.md", __DIR__))

  setup do
    url = HTTP.start(Router) <> "/mcp"
    %{url: url}
  end

  test "a proxy with skills: true passes the upstream's skills on", %{url: url} do
    start_supervised!({Proxy, upstream: url})
    client = connect(Proxy)

    assert Sake.Client.skills?(session(client))
    assert {:ok, [entry]} = list_skills(client)
    assert entry["uri"] == "skill://run-report/SKILL.md"

    assert entry ==
             RunReport.spec().skill |> Sake.Skill.to_wire() |> JSON.encode!() |> JSON.decode!()

    assert {:ok, @skill_md} = read_skill_file(client, entry, entry["uri"])
    assert {:ok, [_, _, _]} = read_resource_directory(client, "skill://run-report")

    # A skill the upstream does not list is found by its skills/get.
    assert {:ok, %{"uri" => "skill://hidden/SKILL.md"}} =
             get_skill(client, "skill://hidden/SKILL.md")

    assert {:error, {:rpc, %{"code" => -32_602}}} = get_skill(client, "skill://nope/SKILL.md")
  end

  test "mounted under a prefix, the upstream's skills take it, next to local ones", %{url: url} do
    start_supervised!({Proxy, upstream: url})
    client = connect(Gateway)

    assert {:ok, entries} = list_skills(client)

    assert Enum.map(entries, & &1["uri"]) == [
             "skill://run-report/SKILL.md",
             "skill://up/run-report/SKILL.md"
           ]

    up = List.last(entries)
    assert Enum.all?(up["resources"], &String.starts_with?(&1["uri"], "skill://up/run-report/"))
    assert {:ok, @skill_md} = read_skill_file(client, up, up["uri"])

    assert {:ok, "# Filters" <> _} =
             read_skill_file(client, up, "skill://up/run-report/references/FILTERS.md")

    assert {:ok, %{"uri" => "skill://up/hidden/SKILL.md"}} =
             get_skill(client, "skill://up/hidden/SKILL.md")
  end

  test "a proxy passes no skills on unless it says so", %{url: url} do
    start_supervised!({Silent, upstream: url})
    client = connect(Silent)

    refute Sake.Client.skills?(session(client))
    assert {:error, {:rpc, %{"code" => -32_601}}} = list_skills(client)
  end
end
