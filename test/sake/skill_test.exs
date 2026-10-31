defmodule Sake.SkillTest do
  use ExUnit.Case, async: true

  alias Sake.Skill
  alias Sake.Skill.Frontmatter

  defmodule RunReport do
    use Sake.Skill, dir: "skills/run-report", scope: "reports:read", ttl: 60_000
  end

  defmodule Nested do
    use Sake.Skill, dir: "skills/run-report", path: "acme/reports/run-report", meta: %{"x" => 1}
  end

  @skill_md File.read!(Path.expand("skills/run-report/SKILL.md", __DIR__))

  describe "Frontmatter" do
    test "splits the frontmatter from the body" do
      assert {:ok, %{"name" => "a", "description" => "b"}, "\n# Body\n"} =
               Frontmatter.split("---\nname: a\ndescription: b\n---\n\n# Body\n")

      assert {:ok, %{"name" => "a"}, ""} = Frontmatter.split("﻿---\r\nname: a\r\n---")
    end

    test "reads the YAML that skill frontmatter is written in" do
      text = """
      name: a
      description: >-
        folded line one
        line two
      literal: |
        keep
          indented
      double: "tab\\tquote \\" é \\u00e9"
      single: 'it''s # not a comment'
      plain: one
        continued # a comment
      metadata:
        version: "1.0"
        count: 3
        ratio: 1.5
        on: true
        nothing: ~
        hex: 0x1F
      tools:
        - Bash
        - 'Read'
      """

      assert {:ok,
              %{
                "name" => "a",
                "description" => "folded line one line two",
                "literal" => "keep\n  indented\n",
                "double" => "tab\tquote \" é é",
                "single" => "it's # not a comment",
                "plain" => "one continued",
                "metadata" => %{
                  "version" => "1.0",
                  "count" => 3,
                  "ratio" => 1.5,
                  "on" => true,
                  "nothing" => nil,
                  "hex" => 31
                },
                "tools" => ["Bash", "Read"]
              }} = Frontmatter.parse(text)
    end

    test "keeps, clips and strips a block scalar's final line breaks" do
      assert {:ok, %{"a" => "x\n\n", "b" => "x\n", "c" => "x"}} =
               Frontmatter.parse("a: |+\n  x\n\nb: |\n  x\n\nc: >-\n  x\n")
    end

    test "refuses what it does not read, saying which line" do
      for {text, message} <- [
            {"name: [a, b]", "flow collections"},
            {"name: &x a", "anchors and aliases"},
            {"name: !tag a", "tags"},
            {"name: a: b", "must be quoted"},
            {"name: a\nname: b", "appears twice"},
            {"name:\n\t- a", "tabs"},
            {"name: \"open", "same line"},
            {"? a\n: b", "complex keys"}
          ] do
        assert {:error, error} = Frontmatter.parse(text)
        assert error =~ message, "#{inspect(text)}: #{error}"
        assert error =~ ~r/^line \d+ of SKILL.md/
      end
    end

    test "a SKILL.md without frontmatter is refused" do
      assert {:error, "SKILL.md has no frontmatter" <> _} = Frontmatter.split("# Title\n")
    end
  end

  describe "a skill compiled from a directory" do
    test "has its manifest: every file but the hidden ones, with its size and digest" do
      spec = RunReport.spec()

      assert %Skill.Spec{
               module: RunReport,
               uri: "skill://run-report/SKILL.md",
               scopes: ["reports:read"],
               ttl: 60_000,
               catalog: false
             } = spec

      assert %Skill{path: "run-report", frontmatter: frontmatter, resources: resources} =
               spec.skill

      assert frontmatter == %{
               "name" => "run-report",
               "description" =>
                 "Run a saved report and summarise it, with the filters the person asked for.",
               "license" => "Apache-2.0",
               "metadata" => %{"author" => "reports", "version" => "1.2"},
               "allowed-tools" => ["run_report"]
             }

      assert Enum.map(resources, & &1.uri) == [
               "skill://run-report/SKILL.md",
               "skill://run-report/references/FILTERS.md",
               "skill://run-report/templates/logo.png",
               "skill://run-report/templates/weekly/summary.md"
             ]

      [skill_md | _] = resources
      assert skill_md.size == byte_size(@skill_md)

      assert skill_md.digest ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, @skill_md), case: :lower)
    end

    test "takes a path whose last segment is its name, and an entry _meta" do
      assert Nested.spec().uri == "skill://acme/reports/run-report/SKILL.md"

      assert %{"uri" => "skill://acme/reports/run-report/SKILL.md", "_meta" => %{"x" => 1}} =
               Skill.to_wire(Nested.spec().skill)
    end

    test "is checked when it compiles" do
      for {opts, message} <- [
            {~s(dir: "skills/bad-name"), "must be 1-64 lowercase"},
            {~s(dir: "skills/run-report", path: "acme/other"), "must end with the skill's name"},
            {~s(dir: "skills/missing"), "does not exist"},
            {"[]", "needs a dir:"}
          ] do
        source = """
        defmodule Sake.SkillTest.Bad#{System.unique_integer([:positive])} do
          use Sake.Skill, #{opts}
        end
        """

        error = assert_raise ArgumentError, fn -> Code.compile_string(source, __ENV__.file) end
        assert error.message =~ message
      end
    end
  end

  describe "build/2 and dynamic/2" do
    test "build/2 computes the manifest of files given at runtime" do
      assert {:ok, skill} =
               Skill.build(%{"SKILL.md" => @skill_md, "a b/c.md" => "x"}, path: "team/run-report")

      assert skill.uri == "skill://team/run-report/SKILL.md"
      assert %{uri: "skill://team/run-report/a%20b/c.md", size: 1} = List.last(skill.resources)
      assert skill.paths["skill://team/run-report/a%20b/c.md"] == "a b/c.md"
    end

    test "build/2 refuses a skill without SKILL.md, a path out of it, and one past the limits" do
      assert {:error, "a skill needs a SKILL.md at its root"} = Skill.build(%{"x.md" => ""})
      assert {:error, message} = Skill.build(%{"SKILL.md" => @skill_md, "../x" => ""})
      assert message =~ "not a path within the skill"

      many = Map.new(1..512, &{"f#{&1}", ""})

      assert {:error, "a skill has at most 512 files" <> _} =
               Skill.build(Map.put(many, "SKILL.md", @skill_md))

      big = :binary.copy("x", 16 * 1024 * 1024)

      assert {:error, "a skill holds at most" <> _} =
               Skill.build(%{"SKILL.md" => @skill_md, "big" => big})

      reserved = "---\nname: a\ndescription: b\nmetadata:\n  io.modelcontextprotocol/x: y\n---\n"
      assert {:error, "the metadata key" <> _} = Skill.build(%{"SKILL.md" => reserved})
    end

    test "dynamic/2 has no manifest" do
      assert {:ok, skill} = Skill.dynamic(@skill_md, path: "live/run-report", files: ["data.csv"])

      assert %{"resources" => "dynamic", "uri" => "skill://live/run-report/SKILL.md"} =
               Skill.to_wire(skill)

      assert skill.paths["skill://live/run-report/data.csv"] == "data.csv"
    end
  end

  describe "verify/3" do
    setup do
      {:ok, skill} = Skill.build(%{"SKILL.md" => @skill_md, "x.md" => "x"})
      %{entry: skill |> Skill.to_wire() |> JSON.encode!() |> JSON.decode!()}
    end

    test "accepts a file with the entry's size and digest", %{entry: entry} do
      assert :ok = Skill.verify(entry, "skill://run-report/SKILL.md", @skill_md)
      assert :ok = Skill.verify(entry, "skill://run-report/x.md", "x")
    end

    test "refuses one that is not listed, or whose size or digest differs", %{entry: entry} do
      assert {:error, :unlisted} = Skill.verify(entry, "skill://run-report/y.md", "x")
      assert {:error, :size_mismatch} = Skill.verify(entry, "skill://run-report/x.md", "xy")
      assert {:error, :digest_mismatch} = Skill.verify(entry, "skill://run-report/x.md", "y")
    end

    test "refuses a SKILL.md whose frontmatter is not the entry's", %{entry: entry} do
      tampered = String.replace(@skill_md, "license: Apache-2.0", "license: MIT-0000")
      [skill_md | rest] = entry["resources"]

      entry = %{
        entry
        | "resources" => [
            %{skill_md | "digest" => Skill.digest(tampered), "size" => byte_size(tampered)} | rest
          ]
      }

      assert {:error, {:frontmatter_mismatch, ["license"]}} =
               Skill.verify(entry, "skill://run-report/SKILL.md", tampered)
    end

    test "has nothing to check a dynamic entry against" do
      assert {:error, :dynamic} =
               Skill.verify(%{"resources" => "dynamic"}, "skill://a/SKILL.md", "")

      assert {:error, :invalid_entry} = Skill.verify(%{}, "skill://a/SKILL.md", "")
    end
  end
end
