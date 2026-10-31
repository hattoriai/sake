defmodule Mix.Tasks.Sake.ReleaseCheck do
  @shortdoc "Checks that the repository is ready for a release of Sake"

  @moduledoc """
  Checks the repository before a release of Sake.

      $ mix sake.release_check

  This task is for work on Sake itself; the `release` alias runs it before
  `mix hex.publish`, and nothing is published or tagged when it fails. In
  any project but Sake, it stops with an error. It fetches `main` and the
  tags from `origin` first, then fails when:

    * the first heading of `CHANGELOG.md` is not this version's, with its
      date (`## 0.5.0 (2026-10-31)`): an `## Unreleased` heading above it
      means the changelog was not cut;
    * a `{:sake, "~> ..."}` requirement in the README or a guide is not
      this version's series (`~> 0.5` for any 0.5.x);
    * `SECURITY.md` does not list this version's series as supported;
    * the checkout is not `main`, has uncommitted changes, or is not the
      commit `origin/main` points at;
    * the tag `v<version>` already exists.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    config = Mix.Project.config()
    ensure_sake!(config)
    version = config[:version]

    _ = git(["fetch", "--quiet", "origin", "main", "--tags"])

    case check(File.cwd!(), version, git_state(version)) do
      :ok ->
        Mix.shell().info("Sake #{version} is ready for a release: tag v#{version} and publish")

      {:error, problems} ->
        Mix.raise("""
        Sake #{version} is not ready for a release:

        #{Enum.map_join(problems, "\n", &("  * " <> &1))}

        Cut the changelog, bump the requirements and SECURITY.md in a release \
        pull request, merge it, then run `mix release` on an up-to-date main.\
        """)
    end
  end

  @doc false
  @spec ensure_sake!(keyword()) :: :ok
  def ensure_sake!(config) do
    if config[:app] == :sake do
      :ok
    else
      Mix.raise("mix sake.release_check is for work on Sake itself; it checks a Sake release")
    end
  end

  @typedoc "What git says about the checkout."
  @type git :: %{
          branch: String.t() | nil,
          dirty: boolean(),
          head: String.t() | nil,
          origin: String.t() | nil,
          tagged: boolean()
        }

  @doc false
  # The problems of the repository at `root`, for `version`, with the
  # checkout's state as `git`.
  @spec check(Path.t(), String.t(), git()) :: :ok | {:error, [String.t()]}
  def check(root, version, git) do
    problems =
      changelog_problems(root, version) ++
        requirement_problems(root, version) ++
        security_problems(root, version) ++
        git_problems(git, version)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp changelog_problems(root, version) do
    case File.read(Path.join(root, "CHANGELOG.md")) do
      {:ok, source} ->
        source
        |> then(&Regex.run(~r/^## (.+)$/m, &1, capture: :all_but_first))
        |> heading_problems(version)

      {:error, _reason} ->
        ["there is no CHANGELOG.md"]
    end
  end

  defp heading_problems(nil, _version), do: ["CHANGELOG.md has no release heading"]

  defp heading_problems([heading], version) do
    if heading =~ ~r/\A#{Regex.escape(version)} \(\d{4}-\d{2}-\d{2}\)\z/,
      do: [],
      else: [~s(the first heading of CHANGELOG.md is "#{heading}", not "#{version} \(<date>\)")]
  end

  defp requirement_problems(root, version) do
    expected = "~> " <> series(version)

    for path <- docs(root),
        [requirement] <-
          Regex.scan(~r/\{:sake, "([^"]+)"/, File.read!(path), capture: :all_but_first),
        requirement != expected,
        do:
          "#{Path.relative_to(path, root)} asks for {:sake, \"#{requirement}\"}, not \"#{expected}\""
  end

  defp docs(root),
    do: [Path.join(root, "README.md") | Path.wildcard(Path.join(root, "guides/*.md"))]

  defp security_problems(root, version) do
    row = ~r/^\|\s*#{Regex.escape(series(version))}\.x\s*\|\s*yes\s*\|/m

    case File.read(Path.join(root, "SECURITY.md")) do
      {:ok, source} ->
        if source =~ row,
          do: [],
          else: ["SECURITY.md does not list #{series(version)}.x as supported"]

      {:error, _reason} ->
        ["there is no SECURITY.md"]
    end
  end

  defp git_problems(git, version) do
    [
      git.branch != "main" && "the checkout is #{git.branch || "not on a branch"}, not main",
      git.dirty && "the checkout has uncommitted changes",
      git.head != git.origin && "main is not the commit origin/main points at",
      git.tagged && "the tag v#{version} already exists"
    ]
    |> Enum.filter(&is_binary/1)
  end

  # The requirement's series: `0.5` for 0.5.x, `1.2` for 1.2.x (`~> 1.2`
  # also takes later minors, which a 1.x series allows).
  defp series(version) do
    [major, minor | _] = String.split(version, ".")
    major <> "." <> minor
  end

  defp git_state(version) do
    %{
      branch: git(["symbolic-ref", "--quiet", "--short", "HEAD"]),
      dirty: git(["status", "--porcelain"]) not in [nil, ""],
      head: git(["rev-parse", "HEAD"]),
      origin: git(["rev-parse", "origin/main"]),
      tagged: git(["tag", "--list", "v" <> version]) not in [nil, ""]
    }
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {_out, _status} -> nil
    end
  end
end
