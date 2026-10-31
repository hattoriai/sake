defmodule Sake.Skill.Spec do
  @moduledoc """
  The compiled definition of a skill, or of a catalog of skills, as a
  server lists it.

  `skill` is the `Sake.Skill`, at the URIs this level of the server
  knows; `uri` its `SKILL.md`'s. A `Sake.Skill.Catalog`'s spec has
  neither until the catalog gives its skills, at runtime: each then gets
  a spec of its own, with `catalog` set. `mount` is `nil` for a skill the
  server declares itself, and `{server, prefix, spec}` for one it
  mounted, as for a resource. `proxy` is the `Sake.Proxy` whose upstream
  serves the skill.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :module,
    :uri,
    :skill,
    :ttl,
    catalog: false,
    scopes: [],
    authentication: nil,
    mount: nil,
    proxy: nil
  ]
end
