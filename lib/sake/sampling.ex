defmodule Sake.Sampling do
  @moduledoc """
  Asks the client's model to complete a conversation from inside a
  component (`sampling/createMessage`).

      case Sake.Sampling.create_message(ctx, :summary, [user: "Summarize: " <> text], max_tokens: 200) do
        {:ok, %Sake.Sampling.Result{text: summary}} -> {:ok, summary}
        {:error, :unsupported} -> {:error, "This tool needs a client that supports sampling."}
        {:error, _reason} -> {:error, "The client could not sample."}
      end

  Sampling is deprecated in the 2026-07-28 revision (SEP-2577) but still
  part of it, and many clients still use it; Sake supports it on every
  revision. The call travels exactly like a `Sake.Elicit` call: on a
  modern connection it ends the handler and returns the answer when the
  client retries (so no side effects before it), on a legacy connection it
  blocks until the client answers on the stream, and inside a task it
  waits for the client's `tasks/update`.

  `messages` is a list of `{role, content}` pairs, as a prompt returns
  them: `role` is `:user` or `:assistant`, `content` a string, a
  `Sake.Content`, a list of them, or a content map as it goes on the wire.
  A message map as it goes on the wire is accepted too.

  Options: `max_tokens` (required), `system_prompt`, `temperature`,
  `stop_sequences`, `model_preferences` (a wire map, or a keyword list of
  `hints` (model names), `cost_priority`, `speed_priority` and
  `intelligence_priority`), `include_context` (`:none`, `:this_server` or
  `:all_servers`), `metadata`, and from revision 2025-11-25 on, `tools`
  (tool modules, `Sake.Tool.Spec`s or wire maps) and `tool_choice`
  (`:auto`, `:required` or `:none`).

  Returns `{:ok, %Sake.Sampling.Result{}}`, `{:error, :unsupported}` when
  the client did not declare `sampling` (or, with `tools`, did not declare
  `sampling.tools`), `{:error, :cancelled}` when the task the call
  waits in was cancelled, `{:error, :timeout}` when a legacy client never
  answered, `{:error, :invalid_response}` when the answer is not a result
  object, and `{:error, error}` with the JSON-RPC error map a legacy client
  answered with.
  """

  alias Sake.{Content, Context}
  alias Sake.Server.Ask

  defmodule Result do
    @moduledoc """
    The client's answer to `Sake.Sampling.create_message/4`: the `role` of
    the message (`"assistant"`), its `content` as `Sake.Content` blocks,
    `text` (every text block joined), the `model` that produced it, the
    `stop_reason`, and the `raw` result map, which also holds content Sake
    has no struct for (such as tool use).
    """
    @type t :: %__MODULE__{
            role: String.t() | nil,
            content: [Sake.Content.t()],
            text: String.t(),
            model: String.t() | nil,
            stop_reason: String.t() | nil,
            raw: map()
          }
    defstruct [:role, :model, :stop_reason, content: [], text: "", raw: %{}]
  end

  @type message ::
          {atom() | String.t(), String.t() | Content.t() | [Content.t() | map()] | map()}
          | map()

  @spec create_message(Context.t(), atom() | String.t(), [message()], keyword()) ::
          {:ok, Result.t()}
          | {:error, :unsupported | :cancelled | :timeout | :invalid_response | map()}
  def create_message(ctx, key, messages, opts) do
    max_tokens =
      opts[:max_tokens] || raise ArgumentError, "Sake.Sampling.create_message needs max_tokens:"

    if opts[:tools] && not tools_supported?(ctx) do
      {:error, :unsupported}
    else
      params = params(ctx, messages, max_tokens, opts)

      case Ask.request(ctx, "sampling", to_string(key), "sampling/createMessage", params) do
        {:ok, %{} = answer} -> {:ok, result(answer)}
        {:ok, _other} -> {:error, :invalid_response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Tool use in sampling arrived with 2025-11-25, and only for a client
  # that declares `sampling.tools`.
  defp tools_supported?(ctx) do
    (ctx.era == :modern or ctx.protocol_version >= "2025-11-25") and
      match?(%{"sampling" => %{"tools" => _}}, ctx.client_capabilities)
  end

  defp params(ctx, messages, max_tokens, opts) do
    %{"messages" => Enum.map(messages, &message/1), "maxTokens" => max_tokens}
    |> put_some("systemPrompt", opts[:system_prompt])
    |> put_some("temperature", opts[:temperature])
    |> put_some("stopSequences", opts[:stop_sequences])
    |> put_some("modelPreferences", model_preferences(opts[:model_preferences]))
    |> put_some("includeContext", include_context(opts[:include_context]))
    |> put_some("metadata", opts[:metadata])
    |> put_some("tools", tools(opts[:tools], ctx))
    |> put_some("toolChoice", tool_choice(opts[:tool_choice]))
  end

  defp message({role, content}), do: %{"role" => to_string(role), "content" => content(content)}
  defp message(%{} = wire), do: wire

  defp content(text) when is_binary(text), do: Content.to_wire(Content.text(text))
  defp content(%Content{} = c), do: Content.to_wire(c)
  defp content(list) when is_list(list), do: Enum.map(list, &content/1)
  defp content(%{} = wire), do: wire

  defp model_preferences(nil), do: nil
  defp model_preferences(%{} = wire), do: wire

  defp model_preferences(prefs) when is_list(prefs) do
    %{}
    |> put_some("hints", prefs[:hints] && Enum.map(prefs[:hints], &%{"name" => &1}))
    |> put_some("costPriority", prefs[:cost_priority])
    |> put_some("speedPriority", prefs[:speed_priority])
    |> put_some("intelligencePriority", prefs[:intelligence_priority])
  end

  defp include_context(nil), do: nil
  defp include_context(:none), do: "none"
  defp include_context(:this_server), do: "thisServer"
  defp include_context(:all_servers), do: "allServers"
  defp include_context(value) when is_binary(value), do: value

  defp tools(nil, _ctx), do: nil
  defp tools(tools, ctx), do: Enum.map(tools, &tool(&1, ctx))

  defp tool(%Sake.Tool.Spec{} = spec, ctx), do: Sake.Tool.Spec.to_wire(spec, ctx.protocol_version)
  defp tool(%{} = wire, _ctx), do: wire
  defp tool(module, ctx) when is_atom(module), do: tool(module.spec(), ctx)

  defp tool_choice(nil), do: nil
  defp tool_choice(mode) when mode in [:auto, :required, :none], do: %{"mode" => to_string(mode)}
  defp tool_choice(%{} = wire), do: wire

  defp result(answer) do
    content =
      answer["content"]
      |> List.wrap()
      |> Enum.map(&Content.from_wire/1)
      |> Enum.reject(&match?({:error, _}, &1))

    %Result{
      role: answer["role"],
      content: content,
      text: content |> Enum.filter(&(&1.type == :text)) |> Enum.map_join("\n", & &1.text),
      model: answer["model"],
      stop_reason: answer["stopReason"],
      raw: answer
    }
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
