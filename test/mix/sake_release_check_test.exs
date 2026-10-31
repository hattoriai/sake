defmodule Mix.Tasks.Sake.ReleaseCheckTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Sake.ReleaseCheck

  @moduletag :tmp_dir

  @git %{branch: "main", dirty: false, head: "abc", origin: "abc", tagged: false}

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "guides"))

    File.write!(
      Path.join(root, "CHANGELOG.md"),
      "# Changelog\n\n## 1.2.3 (2026-10-31)\n\n- x\n\n## 1.2.2 (2026-10-01)\n"
    )

    File.write!(Path.join(root, "README.md"), ~s(  [{:sake, "~> 1.2"}, {:bandit, "~> 1.5"}]\n))
    File.write!(Path.join(root, "guides/libraries.md"), ~s({:sake, "~> 1.2", optional: true}\n))

    File.write!(
      Path.join(root, "SECURITY.md"),
      "| Version | Supported |\n| --- | --- |\n| 1.2.x | yes |\n| 1.1.x | no |\n"
    )

    %{root: root}
  end

  test "passes on a cut release from an up-to-date main", %{root: root} do
    assert ReleaseCheck.check(root, "1.2.3", @git) == :ok
  end

  test "fails when the changelog was not cut", %{root: root} do
    File.write!(
      Path.join(root, "CHANGELOG.md"),
      "# Changelog\n\n## Unreleased\n\n## 1.2.2 (2026-10-01)\n"
    )

    assert ReleaseCheck.check(root, "1.2.3", @git) ==
             {:error,
              [~s(the first heading of CHANGELOG.md is "Unreleased", not "1.2.3 \(<date>\)")]}
  end

  test "fails for a heading without a date", %{root: root} do
    File.write!(Path.join(root, "CHANGELOG.md"), "# Changelog\n\n## 1.2.3\n")
    assert {:error, [problem]} = ReleaseCheck.check(root, "1.2.3", @git)
    assert problem =~ "is \"1.2.3\""
  end

  test "fails for a requirement of another series", %{root: root} do
    File.write!(Path.join(root, "guides/quickstart.md"), ~s({:sake, "~> 1.1"}\n))

    assert ReleaseCheck.check(root, "1.2.3", @git) ==
             {:error, [~s(guides/quickstart.md asks for {:sake, "~> 1.1"}, not "~> 1.2")]}
  end

  test "fails when SECURITY.md does not support the series", %{root: root} do
    assert ReleaseCheck.check(root, "1.3.0", @git) ==
             {:error,
              [
                ~s(the first heading of CHANGELOG.md is "1.2.3 \(2026-10-31\)", not "1.3.0 \(<date>\)"),
                ~s(README.md asks for {:sake, "~> 1.2"}, not "~> 1.3"),
                ~s(guides/libraries.md asks for {:sake, "~> 1.2"}, not "~> 1.3"),
                "SECURITY.md does not list 1.3.x as supported"
              ]}
  end

  test "fails off main, with changes, behind origin, or with the tag already there", %{root: root} do
    git = %{branch: "feature", dirty: true, head: "abc", origin: "def", tagged: true}

    assert ReleaseCheck.check(root, "1.2.3", git) ==
             {:error,
              [
                "the checkout is feature, not main",
                "the checkout has uncommitted changes",
                "main is not the commit origin/main points at",
                "the tag v1.2.3 already exists"
              ]}

    assert {:error, ["the checkout is not on a branch, not main"]} =
             ReleaseCheck.check(root, "1.2.3", %{@git | branch: nil})
  end

  test "refuses to run outside Sake" do
    assert ReleaseCheck.ensure_sake!(app: :sake) == :ok
    assert_raise Mix.Error, fn -> ReleaseCheck.ensure_sake!(app: :other) end
  end

  # Between releases the changelog has an `Unreleased` heading; the rest
  # must always match the version.
  test "this repository's requirements and SECURITY.md match its version" do
    root = Path.expand("../..", __DIR__)
    version = Mix.Project.config()[:version]

    case ReleaseCheck.check(root, version, @git) do
      :ok -> :ok
      {:error, problems} -> assert Enum.all?(problems, &(&1 =~ "CHANGELOG.md"))
    end
  end
end
