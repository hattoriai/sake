defmodule Sake.Skill.Catalog do
  @moduledoc """
  Skills the host learns at runtime: from its database, a content store,
  or whoever is asking.

      defmodule MyApp.MCP.Playbooks do
        use Sake.Skill.Catalog, scope: "playbooks:read"

        @impl true
        def list(ctx) do
          for playbook <- MyApp.Playbooks.published(ctx.scope),
              {:ok, skill} <- [skill(playbook)],
              do: skill
        end

        @impl true
        def fetch("playbooks/" <> name, ctx) do
          with {:ok, playbook} <- MyApp.Playbooks.get(ctx.scope, name), do: skill(playbook)
        end

        def fetch(_path, _ctx), do: :error

        defp skill(playbook) do
          Sake.Skill.build(%{"SKILL.md" => playbook.body}, path: "playbooks/" <> playbook.slug)
        end
      end

  and the server lists it with its other skills: `skills
  [MyApp.MCP.Playbooks]`.

  `list/1` returns the skills to list, built with `Sake.Skill.build/2`
  (a complete manifest, from the files' content) or `Sake.Skill.dynamic/2`
  (content generated when it is read, without one). The list may be
  partial, or empty: a catalog too large to enumerate lists none, and a
  client loads its skills by URI. `fetch/2` returns the skill at a path
  (the part of its URI between `skill://` and `/SKILL.md`), listed or not;
  without it, a skill is found in `list/1`. `read/3` returns the content
  of a dynamic skill's file, by its path within the skill; a built
  skill's files are served from what it holds.

  Options: `scope:`, `authentication:` and `ttl:`, which apply to every
  skill of the catalog, as to a `Sake.Skill`'s. What a catalog lists
  depends on the request, so its lists are `cacheScope: "private"`.
  """

  @doc "The skills to list. May be partial, or empty."
  @callback list(ctx :: Sake.Context.t()) :: [Sake.Skill.t()]

  @doc "The skill at `path`, whether `list/1` lists it or not."
  @callback fetch(path :: String.t(), ctx :: Sake.Context.t()) :: {:ok, Sake.Skill.t()} | :error

  @doc "The content of a dynamic skill's file, by its path within the skill."
  @callback read(skill :: Sake.Skill.t(), file :: String.t(), ctx :: Sake.Context.t()) ::
              {:ok, binary()} | {:error, :not_found}

  @optional_callbacks fetch: 2, read: 3

  defmacro __using__(opts) do
    quote do
      @behaviour Sake.Skill.Catalog
      @sake_opts unquote(opts)
      @before_compile Sake.Skill.Catalog
    end
  end

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :sake_opts)

    spec = %Sake.Skill.Spec{
      module: env.module,
      catalog: true,
      scopes: List.wrap(opts[:scope]),
      authentication:
        Sake.Auth.Authentication.requirement!(opts[:authentication], inspect(env.module)),
      ttl: opts[:ttl]
    }

    quote do
      @doc false
      def spec, do: unquote(Macro.escape(spec))
    end
  end
end
