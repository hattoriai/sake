defmodule Sake.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hattoriai/sake"

  def project do
    [
      app: :sake,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :phoenix, :ecto, :ecto_sql],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/project.plt"}
      ],
      package: package(),
      docs: docs(),
      description: description(),
      name: "Sake",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :ssl, :eex]]
  end

  def cli do
    [preferred_envs: [precommit: :test, "test.conformance": :dev]]
  end

  # The development server modules (dev/lib) are the example server of the
  # tests as well.
  defp elixirc_paths(:test), do: ["lib", "test/support", "dev/lib"]
  defp elixirc_paths(:dev), do: ["lib", "dev/lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:bypass, "~> 2.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ecto, "~> 3.13", optional: true},
      {:ecto_sql, "~> 3.13", optional: true},
      {:jose, "~> 1.11", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:phoenix, "~> 1.8", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:plug, "~> 1.16"},
      {:postgrex, ">= 0.0.0", only: [:dev, :test]},
      {:req, "~> 0.5"},
      {:stream_data, "~> 1.1", only: :test},
      {:telemetry, "~> 1.0"}
    ]
  end

  defp description do
    "MCP for Elixir and Phoenix: a server for both protocol eras, an OAuth 2.1 authorization server on your own login, and a client."
  end

  defp package do
    [
      name: "sake",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/templates mix.exs .formatter.exs guides README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      # The banner of the README, at the same relative path in the docs.
      assets: %{"media" => "media"},
      extras: [
        "README.md",
        "guides/quickstart.md",
        "guides/tools.md",
        "guides/tasks.md",
        "guides/apps.md",
        "guides/resources_and_prompts.md",
        "guides/authorization.md",
        "guides/tenants.md",
        "guides/client.md",
        "guides/stdio.md",
        "guides/protocol_versions.md",
        "guides/security.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides:
          ~w(guides/quickstart.md guides/tools.md guides/tasks.md guides/apps.md guides/resources_and_prompts.md guides/authorization.md guides/tenants.md guides/client.md guides/stdio.md),
        Reference: ~w(guides/protocol_versions.md guides/security.md)
      ],
      groups_for_modules: [
        Server: [
          Sake.Server,
          Sake.Tool,
          Sake.Resource,
          Sake.UI,
          Sake.Prompt,
          Sake.Context,
          Sake.Content,
          Sake.Elicit,
          Sake.Sampling,
          Sake.Sampling.Result,
          Sake.Roots,
          Sake.Input,
          Sake.Progress,
          Sake.Plug,
          Sake.Plug.Streams,
          Sake.Plug.Headers,
          Sake.Router,
          Sake.Stdio
        ],
        Tasks: [
          Sake.Tasks,
          Sake.Tasks.Record,
          Sake.Tasks.Store,
          Sake.Tasks.Store.ETS,
          Sake.Tasks.Store.Ecto,
          Sake.Tasks.Migration
        ],
        Authorization: [
          Sake.Auth,
          Sake.Auth.Config,
          Sake.Auth.Subject,
          Sake.Auth.Consent,
          Sake.Auth.Clients,
          Sake.Auth.Client,
          Sake.Auth.Code,
          Sake.Auth.TokenRecord,
          Sake.Auth.Bearer,
          Sake.Auth.WellKnown,
          Sake.Auth.Authorize,
          Sake.Auth.Token,
          Sake.Auth.Revoke,
          Sake.Auth.DCR,
          Sake.Auth.CIMD,
          Sake.Auth.RouterPlug,
          Sake.Auth.Store,
          Sake.Auth.Store.ETS,
          Sake.Auth.Store.Ecto,
          Sake.Auth.Migration
        ],
        Client: [
          Sake.Client,
          Sake.Client.Session,
          Sake.Client.Challenge,
          Sake.Client.ToolResult,
          Sake.Client.Auth,
          Sake.Client.Auth.Browser,
          Sake.Client.Auth.Headless,
          Sake.Client.Auth.Store
        ],
        Protocol: [Sake.Protocol, Sake.JSONRPC, Sake.Schema]
      ]
    ]
  end

  defp aliases do
    [
      dev: "run --no-halt dev.exs",
      "test.conformance": ["cmd --cd conformance ./run.sh"],
      release: [
        "hex.publish --yes",
        "cmd git tag v#{@version} -f",
        "cmd git push",
        "cmd git push --tags"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
