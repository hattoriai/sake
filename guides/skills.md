# Skills

A tool says what it does; a skill says how to get a job done with
several tools. A reporting engine ships `list_reports` and `run_report`,
and a skill that tells the model which filters people mean by "last
quarter", which template a weekly summary follows, and what to check
before sending it. The client finds the skill when it connects, and
loads it only when the model needs it.

Sake serves skills over the Skills extension
(`io.modelcontextprotocol/skills`, SEP-2640), as its beta specification
describes it against the 2026-07-28 base revision
([modelcontextprotocol/ext-skills](https://github.com/modelcontextprotocol/ext-skills),
`specification/beta/skills.mdx`). Its client lists skills, gets them by
URI, and checks every file it reads against the skill's manifest.

## A skill in a directory

A skill is a directory in the
[Agent Skills](https://agentskills.io/specification) format: a
`SKILL.md` that starts with YAML frontmatter (a `name` and a
`description` at least), and any files beside it.

```text
lib/reports/mcp/skills/run-report/
  SKILL.md
  references/FILTERS.md
  templates/weekly.md
```

```markdown
---
name: run-report
description: >-
  Run a saved report and summarise it, with the filters the person
  asked for. Use when someone asks for figures from a saved report.
license: Apache-2.0
---

# Run a report

1. Find the report with `list_reports`.
2. Read `references/FILTERS.md` to turn what the person said into filters.
3. Run it with `run_report`, then summarise it as `templates/weekly.md` does.
```

A module compiles it:

```elixir
defmodule Reports.MCP.RunReport do
  use Sake.Skill, dir: "skills/run-report"
end
```

`dir:` is relative to the module's file. Every file under it is part of
the skill, except hidden ones (a name that starts with a `.`, such as
`.DS_Store`). Sake reads them when the module compiles, and checks the
skill there, so a mistake is a compile error, not a client's refusal:

- `SKILL.md` must have frontmatter with a `name` and a `description`.
- The name is 1 to 64 lowercase letters, digits and hyphens, neither
  starting nor ending with a hyphen nor holding two in a row.
- A `metadata` key under `io.modelcontextprotocol/` is the protocol's,
  and refused.
- A skill has at most 512 files and 16 MiB in all: the limits every
  client must support.

It also computes the manifest then: each file's size and SHA-256 digest.
The module recompiles when a file changes, or is added or removed.

Sake reads the frontmatter itself, without a YAML dependency. It reads
the YAML that frontmatter is written in: mappings, lists, plain and
quoted values, `|` and `>` blocks, comments. It refuses flow collections
(`[a, b]`, `{a: b}`), anchors and tags with a compile error that names
the line. A client compares the frontmatter it parses from `SKILL.md`
with the one Sake sends, so Sake refuses what it might read differently
rather than guessing.

`use Sake.Skill` options:

- `dir:` (required): the skill's directory.
- `path:` sets the skill's path, the part of its URI between `skill://`
  and `/SKILL.md`. It defaults to the name. The last segment must be the
  name, and the segments before it are yours to choose:
  `path: "reports/run-report"` serves
  `skill://reports/run-report/SKILL.md`.
- `scope:` and `authentication:` gate the skill as they gate a resource.
  A token without the scopes does not see the skill listed. It gets a
  403 that asks for them on `skills/get` and on every read of the
  skill's files.
- `ttl:` (ms): the longest a client may keep the skill's entry.
- `meta:`: the entry's `_meta`.

## Serving it

A server lists its skills next to its other components:

```elixir
defmodule Reports.MCP do
  use Sake.Server, name: "reports", version: "1.4.0"

  scope "reports:read", "Read and run saved reports"

  tools [Reports.MCP.ListReports, Reports.MCP.RunReportTool]
  skills [Reports.MCP.RunReport]
end
```

A server with skills declares the extension in its capabilities, with
`directoryRead: true`, and the `resources` capability:

```json
{
  "resources": {"listChanged": true, "subscribe": false},
  "extensions": {"io.modelcontextprotocol/skills": {"directoryRead": true}}
}
```

It answers:

- `skills/list`: each skill's entry. An entry has the URI of its
  `SKILL.md`, its frontmatter, and its manifest, which lists every file
  once with its `uri`, `digest` and `size`. The list is paginated by
  the server's `page_size`, and a skill's entry is never split across
  pages. It carries `ttlMs` and `cacheScope`, as the other lists do.
- `skills/get`: one skill's entry, by the URI of its `SKILL.md`, whether
  `skills/list` lists it or not. A URI with no skill is `-32602`.
- `resources/read`: the skill's files, at `skill://<path>/<file>`. A
  UTF-8 file is sent as text, anything else as a blob, so the bytes the
  client gets are the bytes the digest covers. `SKILL.md` is
  `text/markdown`; other files take the MIME type of their extension.
- `resources/directory/read`: a directory's direct children, the skill's
  root (`skill://run-report`) or one inside it. A subdirectory has the
  `inode/directory` MIME type, and a file URI is `-32602`.

`resources/list` lists each `SKILL.md` too, with the skill's name and
description. A client without the extension finds the skill there as an
ordinary resource, reads it, and resolves the relative paths in it
against its directory. The other files are not listed, but they can
still be read.

These methods work on every revision. A legacy session gets the extension
in its `initialize` result, and its results carry no `ttlMs`. A server
without skills declares nothing and answers these methods as unknown.

## A library's skill, a host's mount

A library ships its skill as it ships its tools: in its server, compiled
with it. For a library where Sake is an optional dependency, wrap the
skill module in the same `if Code.ensure_loaded?(Sake.Server)` (see
`guides/libraries.md`). Keep the skill's directory under `lib/` or
`priv/`, both of which go into the Hex package. The host mounts the
library's server, and its skills come along:

```elixir
defmodule MyApp.MCP do
  use Sake.Server, name: "my-app", version: "1.0.0"

  skills [MyApp.MCP.Onboarding]
  mount Reports.MCP, prefix: "reports", scope: "reports"
end
```

Under a prefix, a skill's URIs take the prefix as a resource's do, as
the first segment after `skill://`:

| The mounted server has | The client sees |
|---|---|
| `skill://run-report/SKILL.md` | `skill://reports/run-report/SKILL.md` |
| `skill://run-report/references/FILTERS.md` | `skill://reports/run-report/references/FILTERS.md` |

The skill's path gains a segment and keeps its name as the last one, so
its URIs still follow the extension's rules. Every URI in the manifest
moves with it. The files are the same bytes, so their digests stay the
same and a client verifies them as before. `SKILL.md` refers to its
other files by relative paths, which resolve to the new URIs. `scope:`
and the mounted server's `authentication:` apply to its skills as they
apply to its other components. `only:` and `except:` name a skill by
its module or by the URI of its `SKILL.md`:

```elixir
mount Reports.MCP, prefix: "reports", except: [Reports.MCP.RunReport]
```

A skill URI may be listed once in a server, its mounted servers'
included. A second one is a compile error, as for a resource.

## Skills the host gives at runtime

A host whose skills live in its database, or depend on who asks, serves
them from a catalog:

```elixir
defmodule MyApp.MCP.Playbooks do
  use Sake.Skill.Catalog, scope: "playbooks:read"

  @impl true
  def list(ctx) do
    for playbook <- MyApp.Playbooks.published(ctx.scope),
        {:ok, skill} <- [skill(playbook)],
        do: skill
  end

  @impl true
  def fetch("playbooks/" <> slug, ctx) do
    case MyApp.Playbooks.get(ctx.scope, slug) do
      nil -> :error
      playbook -> skill(playbook)
    end
  end

  def fetch(_path, _ctx), do: :error

  defp skill(playbook) do
    Sake.Skill.build(
      %{"SKILL.md" => playbook.body, "checklist.md" => playbook.checklist},
      path: "playbooks/" <> playbook.slug
    )
  end
end
```

```elixir
skills [Reports.MCP.RunReport, MyApp.MCP.Playbooks]
```

- `list/1` returns the skills to list. It may return only some of them,
  or none: a catalog too large to enumerate lists none, and a client
  loads its skills by URI.
- `fetch/2` returns the skill at a path, listed or not. Without it, a
  skill is found in `list/1`. `skills/get` and the reads of the skill's
  files use it, so a client can load a skill the listing leaves out.
- `Sake.Skill.build/2` makes a skill from its files' content, with the
  same checks and the same complete manifest as a compiled one. Prefer
  it.
- `Sake.Skill.dynamic/2` makes a skill whose content is generated when it
  is read, so it can have no stable digests. Its entry says
  `"resources": "dynamic"`. Its `SKILL.md` is given, and its other files
  come from the catalog's `read/3`, by their path within the skill.
  `files:` names them for `resources/directory/read`, the only way a
  client can find them. A dynamic skill offers no integrity, and a
  client may refuse to load it.

`scope:`, `authentication:` and `ttl:` apply to every skill of the
catalog. What a catalog lists depends on the request, so its results are
`cacheScope: "private"`. A catalog's skill whose URI a skill module
already has is left out.

## Middleware

An `:after_list` plug sees the skills a list is about to show as
`kind: :skills`, with `Sake.Skill.Spec`s in `:items`. Like a tool or
resource it drops, a skill it drops does not exist for the request:
`skills/get`, the reads of its files and its directories all answer as
for a skill the server does not have. A plug that handles only some
kinds needs a clause that passes the rest on:

```elixir
def call(%{kind: :skills, items: items, ctx: ctx} = payload, _opts),
  do: {:cont, %{payload | items: Enum.filter(items, &MyApp.Policy.allows?(ctx.scope, &1.uri))}}

def call(payload, _opts), do: {:cont, payload}
```

A read of a skill's file goes through the `:before_read` and
`:after_read` plugs of the server the client reads from. The resource
they see has the skill's spec in its `skill` field. The read plugs of a
mounted server do not run for its skills' files.

## Behind a proxy

A `Sake.Proxy` passes its upstream's skills on with `skills: true`. It is
off by default, since it adds the extension to the proxy's capabilities.
The proxy lists what the upstream's `skills/list` lists, cached as its
other lists are. It forwards `skills/get` for a skill the upstream does
not list, and reads the skill's files upstream.

The proxy keeps each entry, its manifest and digests included, as the
upstream sent it, and leaves out one that is not shaped as the extension
says or is over its limits. Mounted under a prefix, the upstream's
skills take the prefix as local ones do. A skill whose URI a local one
already has is left out: an upstream never shadows a local skill. The
proxy builds the directory reads of an upstream's skill from its
manifest, so a dynamic upstream skill has none.

## Identity across origins

A skill's URI is scoped to the server that serves it: two servers may
both serve `skill://refunds/SKILL.md` as unrelated skills. A client keys
a skill on the server it connected to and the URI. Through `mount` and a
proxy, the server the client connected to is the origin of every skill
it lists. A prefix keeps the mounted skills' URIs apart from its own,
and Sake refuses two skills at one URI. Names are labels, not
identifiers: two skills from different mounts may share a name, at
different URIs.

## The client

```elixir
{:ok, session} = Sake.Client.connect("https://reports.example.com/mcp")

if Sake.Client.skills?(session) do
  {:ok, skills, session} = Sake.Client.list_skills(session)
  # Show `frontmatter["name"]` and `frontmatter["description"]` to the model;
  # read nothing yet.

  # Later, when the model needs one:
  skill = hd(skills)
  {:ok, skill_md, session} = Sake.Client.read_skill_file(session, skill, skill["uri"])
end
```

- `skills?/1`: whether the server declared the extension. Call the other
  functions only when it did.
- `list_skills/1`: the entries, as the server sent them. Listing reads no
  file.
- `get_skill/2`: one skill's entry by the URI of its `SKILL.md`. A host
  that holds only a URI (from server instructions, another skill or the
  person) uses it, since a listing may be partial.
- `read_skill_file/4`: reads one file and checks it against the entry
  with `Sake.Skill.verify/3`. The file must be in the manifest, with
  its size and digest, and a `SKILL.md` must have the entry's
  frontmatter, compared field by field. Content that fails is not
  returned: `{:error, {:skill_verification, reason}, session}`. Get the
  entry again with `get_skill/2` and start over. A dynamic entry is
  refused unless `dynamic: true` is given.
- `read_resource_directory/2`: a directory's children, to browse. A
  directory read does not extend a skill's manifest: a file it shows
  that the entry does not list is not part of the skill.

Which skill to load, when, and whether the person approves it, is the
host's to decide. Sake does not activate skills. The extension's host
rules are the host's to follow: load files only when needed, tag skill
content with the server it came from, and never let a skill's
frontmatter (`allowed-tools`, say) grant permissions on its own.

## Testing

`Sake.Test` has the client's skill functions:

```elixir
test "the run-report skill loads and verifies" do
  client = connect(MyApp.MCP, scope: user, scopes: ["reports"])

  {:ok, skills} = list_skills(client)
  skill = Enum.find(skills, &(&1["uri"] == "skill://reports/run-report/SKILL.md"))

  for %{"uri" => uri} <- skill["resources"] do
    assert {:ok, _bytes} = read_skill_file(client, skill, uri)
  end
end
```
