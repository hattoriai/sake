defmodule Sake.Server.SkillsTest do
  use ExUnit.Case, async: true

  import Sake.Test

  alias Sake.Skill
  alias SakeTest.ModernClient

  # ---- a library's server: a tool and the skill that uses it

  defmodule RunReportTool do
    use Sake.Tool, name: "run_report", description: "Runs a saved report"

    @impl true
    def execute(_args, _ctx), do: {:ok, "ran"}
  end

  defmodule RunReport do
    use Sake.Skill, dir: "../skills/run-report", ttl: 60_000
  end

  defmodule Reports do
    use Sake.Server, name: "reports", version: "1"
    tools [RunReportTool]
    skills [RunReport]
  end

  # ---- a host's catalog: one built skill listed, one not, one dynamic

  defmodule Playbooks do
    use Sake.Skill.Catalog, scope: "playbooks:read"

    @impl true
    def list(_ctx), do: [skill("onboarding")]

    @impl true
    def fetch("playbooks/" <> name, _ctx) when name in ["onboarding", "offboarding"],
      do: {:ok, skill(name)}

    def fetch("live/today", _ctx), do: today()
    def fetch(_path, _ctx), do: :error

    @impl true
    def read(%Skill{path: "live/today"}, "data.csv", ctx), do: {:ok, "user,#{ctx.scope}\n"}
    def read(_skill, _file, _ctx), do: {:error, :not_found}

    defp skill(name) do
      {:ok, skill} =
        Skill.build(
          %{
            "SKILL.md" =>
              "---\nname: #{name}\ndescription: The #{name} playbook\n---\n\nSteps.\n",
            "steps/one.md" => "One.\n"
          },
          path: "playbooks/" <> name
        )

      skill
    end

    defp today do
      Skill.dynamic("---\nname: today\ndescription: Today's figures\n---\n\nRead data.csv.\n",
        path: "live/today",
        files: ["data.csv"]
      )
    end
  end

  defmodule HideOffboarding do
    @moduledoc false
    def call(%{kind: :skills, items: items} = payload, _opts),
      do: {:cont, %{payload | items: Enum.reject(items, &(&1.uri =~ "offboarding"))}}

    def call(payload, _opts), do: {:cont, payload}
  end

  # ---- the host's app: it mounts the library's server and has its own

  defmodule App do
    use Sake.Server, name: "app", version: "1"
    skills [Playbooks]
    middleware :after_list, [HideOffboarding]
    mount Reports, prefix: "reports"
  end

  defmodule Plain do
    use Sake.Server, name: "plain", version: "1"
    tools [RunReportTool]
  end

  @skill_md File.read!(Path.expand("../skills/run-report/SKILL.md", __DIR__))

  describe "a server with a skill" do
    test "declares the extension, with directoryRead, and the resources capability" do
      {:ok, result} = discover(Reports)

      assert %{
               "resources" => %{},
               "extensions" => %{"io.modelcontextprotocol/skills" => %{"directoryRead" => true}}
             } = result["capabilities"]
    end

    test "lists its skill with a complete manifest" do
      client = connect(Reports)
      assert {:ok, [entry]} = list_skills(client)

      assert entry["uri"] == "skill://run-report/SKILL.md"
      assert entry["frontmatter"]["name"] == "run-report"
      assert length(entry["resources"]) == 4

      assert Enum.all?(
               entry["resources"],
               &match?(%{"digest" => "sha256:" <> _, "size" => _}, &1)
             )

      assert {:ok, ^entry} = get_skill(client, entry["uri"])
    end

    test "serves its files with resources/read, which the entry verifies" do
      client = connect(Reports)
      {:ok, [entry]} = list_skills(client)

      assert {:ok, @skill_md} = read_skill_file(client, entry, "skill://run-report/SKILL.md")

      assert {:ok, <<0x89, "PNG", _::binary>>} =
               read_skill_file(client, entry, "skill://run-report/templates/logo.png")

      assert {:error, {:skill_verification, :unlisted}} =
               read_skill_file(client, entry, "skill://run-report/.draft.md")
    end

    test "a text file is read as text, a binary one as a blob" do
      opts = ModernClient.opts(server: Reports)

      text = ModernClient.post(opts, "resources/read", %{"uri" => "skill://run-report/SKILL.md"})

      assert %{
               "contents" => [%{"mimeType" => "text/markdown", "text" => @skill_md}],
               "ttlMs" => 60_000
             } =
               result(text)

      blob =
        ModernClient.post(opts, "resources/read", %{
          "uri" => "skill://run-report/templates/logo.png"
        })

      assert %{"contents" => [%{"mimeType" => "image/png", "blob" => _}]} =
               result(blob)
    end

    test "lists its SKILL.md among the resources, for a client without the extension" do
      client = connect(Reports)

      assert {:ok,
              [
                %{
                  "uri" => "skill://run-report/SKILL.md",
                  "name" => "run-report",
                  "description" => "Run a saved report" <> _,
                  "mimeType" => "text/markdown"
                }
              ]} = list_resources(client)
    end

    test "reads its directories, one level at a time" do
      client = connect(Reports)

      assert {:ok, root} = read_resource_directory(client, "skill://run-report")

      assert Enum.map(root, &{&1["name"], &1["mimeType"]}) == [
               {"SKILL.md", "text/markdown"},
               {"references", "inode/directory"},
               {"templates", "inode/directory"}
             ]

      assert {:ok,
              [%{"name" => "logo.png"}, %{"name" => "weekly", "mimeType" => "inode/directory"}]} =
               read_resource_directory(client, "skill://run-report/templates")

      assert {:error, {:rpc, %{"code" => -32_602}}} =
               read_resource_directory(client, "skill://run-report/SKILL.md")
    end

    test "an unknown skill is -32602" do
      assert {:error, {:rpc, %{"code" => -32_602, "message" => "No skill is served at " <> _}}} =
               get_skill(connect(Reports), "skill://nope/SKILL.md")
    end
  end

  describe "a mounted server's skills" do
    test "move under the mount's prefix, with their digests" do
      client = connect(App, scope: "ana")
      {:ok, entries} = list_skills(client)

      mounted = Enum.find(entries, &(&1["uri"] == "skill://reports/run-report/SKILL.md"))
      assert mounted["frontmatter"]["name"] == "run-report"

      assert Enum.map(mounted["resources"], & &1["digest"]) ==
               Enum.map(RunReport.spec().skill.resources, & &1.digest)

      assert Enum.all?(
               mounted["resources"],
               &String.starts_with?(&1["uri"], "skill://reports/run-report/")
             )

      assert {:ok, @skill_md} =
               read_skill_file(client, mounted, "skill://reports/run-report/SKILL.md")

      assert {:ok, [_, _, _]} = read_resource_directory(client, "skill://reports/run-report")
    end

    test "a mount's only: and except: name a skill by module" do
      defmodule NoSkills do
        use Sake.Server, name: "no-skills", version: "1"
        mount Reports, except: [RunReport]
      end

      assert NoSkills.__sake__(:skills) == []
      assert NoSkills.__sake__(:tools) != []
    end
  end

  describe "a catalog's skills" do
    test "are listed for the request, and a skill it does not list is got by URI" do
      client = connect(App, scope: "ana")
      {:ok, entries} = list_skills(client)

      assert "skill://playbooks/onboarding/SKILL.md" in Enum.map(entries, & &1["uri"])
      refute Enum.any?(entries, &(&1["uri"] =~ "offboarding"))

      assert {:ok, %{"uri" => "skill://live/today/SKILL.md", "resources" => "dynamic"} = today} =
               get_skill(client, "skill://live/today/SKILL.md")

      assert {:error, {:skill_verification, :dynamic}} =
               read_skill_file(client, today, "skill://live/today/data.csv")

      assert {:ok, "user,ana\n"} =
               read_skill_file(client, today, "skill://live/today/data.csv", dynamic: true)

      assert {:ok, [%{"name" => "SKILL.md"}, %{"name" => "data.csv"}]} =
               read_resource_directory(client, "skill://live/today")
    end

    test "a skill the :after_list plugs hide does not exist, in the list or by URI" do
      client = connect(App, scope: "ana")

      assert {:error, {:rpc, %{"code" => -32_602}}} =
               get_skill(client, "skill://playbooks/offboarding/SKILL.md")

      assert {:error, {:rpc, %{"code" => -32_602}}} =
               read_resource(client, "skill://playbooks/offboarding/SKILL.md")
    end

    test "a catalog's lists are private: they depend on the request" do
      opts = ModernClient.opts(server: App)
      assert %{"cacheScope" => "private"} = result(ModernClient.post(opts, "skills/list"))
    end

    test "need the catalog's scope" do
      client = connect(App, scope: "ana", scopes: [])
      {:ok, entries} = list_skills(client)
      assert Enum.map(entries, & &1["uri"]) == ["skill://reports/run-report/SKILL.md"]

      assert {:error, {:insufficient_scope, %{scope: ["playbooks:read"]}}} =
               get_skill(client, "skill://playbooks/onboarding/SKILL.md")

      assert {:error, {:insufficient_scope, %{scope: ["playbooks:read"]}}} =
               read_resource(client, "skill://playbooks/onboarding/steps/one.md")

      client = connect(App, scope: "ana", scopes: ["playbooks:read"])
      assert {:ok, %{}} = get_skill(client, "skill://playbooks/onboarding/SKILL.md")
    end
  end

  describe "a server without skills" do
    test "declares no extension and answers its methods as unknown" do
      {:ok, result} = discover(Plain)
      refute Map.has_key?(result["capabilities"], "extensions")

      client = connect(Plain)
      refute Sake.Client.skills?(session(client))
      assert {:error, {:rpc, %{"code" => -32_601}}} = list_skills(client)
    end
  end

  describe "on a legacy session" do
    test "the extension is declared in initialize and its methods answer" do
      client = connect(Reports, era: :legacy)
      assert Sake.Client.skills?(session(client))
      assert {:ok, [entry]} = list_skills(client)
      refute Map.has_key?(entry, "ttlMs")
      assert {:ok, @skill_md} = read_skill_file(client, entry, entry["uri"])
    end
  end

  defp result(conn), do: ModernClient.json(conn)["result"]

  defp discover(server) do
    server
    |> then(&ModernClient.opts(server: &1))
    |> ModernClient.post("server/discover")
    |> then(&{:ok, result(&1)})
  end
end
