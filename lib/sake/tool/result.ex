defmodule Sake.Tool.Result do
  @moduledoc ~S"""
  A tool result spelled out: its structured value, what the model reads,
  and its `_meta`, each given on its own.

  The convenient returns of `execute/2` cover most tools: a string is
  text, a map or a non-empty list is structured content with its JSON as
  text, a list of `Sake.Content` is content. They cannot say "the
  structured result is `[]`", or `nil`, `"ok"`, `42` or `true`: those
  read as no content, or as text. A `Sake.Tool.Result` can:

      def execute(%{query: q}, ctx) do
        issues = Issues.search(ctx.scope, q)
        {:ok, Sake.Tool.Result.new(structured: issues, text: "#{length(issues)} issues")}
      end

  Options of `new/1`:

    * `:structured` — any JSON value, `nil` (JSON `null`) included. Only
      given means present: leave it out for a result with no structured
      content.
    * `:text` — what the model reads, as text; or `:content`, a list of
      `Sake.Content`. Without either, the model reads the structured
      value's JSON, as with a map result.
    * `:meta` — the result's `_meta`.
    * `:error` — `true` for a tool error (`isError`) that still carries
      structured content.

  `structuredContent` may be any JSON value from revision 2026-07-28; the
  revisions before it allow only an object. On those, a structured value
  that is not an object is left out of the result, and the model still
  reads its JSON (or the given text). A result is checked against the
  tool's `output_schema` (see "Output schemas" in `guides/tools.md`).
  """

  @type t :: %__MODULE__{
          structured: term(),
          structured?: boolean(),
          text: String.t() | nil,
          content: [Sake.Content.t()] | nil,
          meta: map() | nil,
          error: boolean()
        }

  defstruct structured: nil, structured?: false, text: nil, content: nil, meta: nil, error: false

  @doc "A result; see the module documentation for the options."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    case Keyword.keys(opts) -- [:structured, :text, :content, :meta, :error] do
      [] -> :ok
      keys -> raise ArgumentError, "Sake.Tool.Result.new/1 does not take #{inspect(keys)}"
    end

    if Keyword.has_key?(opts, :text) and Keyword.has_key?(opts, :content) do
      raise ArgumentError, "Sake.Tool.Result.new/1 takes text: or content:, not both"
    end

    %__MODULE__{
      structured: opts[:structured],
      structured?: Keyword.has_key?(opts, :structured),
      text: opts[:text],
      content: opts[:content],
      meta: opts[:meta],
      error: opts[:error] == true
    }
  end
end
