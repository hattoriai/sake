# The client driver for the official MCP conformance client suite. The
# suite starts its own reference server, then runs this script (via
# `client.sh`) with the server URL as the last argument, and reads the
# JSON-RPC traffic on the wire to judge the client's behaviour: this
# script only needs to behave like an ordinary, well-written client.
#
# Run through `conformance/client.sh` (which cds to the project root so
# `mix` finds `Sake`), never directly.

scenario = System.get_env("MCP_CONFORMANCE_SCENARIO")
if scenario, do: IO.puts(:stderr, "MCP_CONFORMANCE_SCENARIO=#{scenario}")

[url | _] = Enum.reverse(System.argv())

report = fn label, value ->
  text = if is_binary(value), do: value, else: inspect(value)
  IO.puts(JSON.encode!(%{"label" => label, "result" => text}))
end

# A well-behaved automated client cannot show a person a form, so it
# accepts every elicitation with whatever defaults the request's schema
# declares (falling back to an empty answer for a field with none).
on_input = fn requests, _session ->
  Map.new(requests, fn {key, %{"params" => params}} ->
    defaults =
      params
      |> get_in(["requestedSchema", "properties"])
      |> Kernel.||(%{})
      |> Enum.filter(fn {_k, v} -> is_map(v) and Map.has_key?(v, "default") end)
      |> Map.new(fn {k, v} -> {k, v["default"]} end)

    {key, %{"action" => "accept", "content" => defaults}}
  end)
end

# The auth scenarios' authorization servers approve every request at once,
# so the headless `authorize` stands in for the person. Pre-registered
# credentials, in the scenarios that have them, arrive in
# `MCP_CONFORMANCE_CONTEXT`; the Client ID Metadata Document URL is the one
# the suite expects a client to present when the server supports them.
context =
  case System.get_env("MCP_CONFORMANCE_CONTEXT") do
    nil -> %{}
    json -> JSON.decode!(json)
  end

auth = [
  authorize: &Sake.Client.Auth.Headless.authorize/1,
  client_metadata_url: "https://conformance-test.local/client-metadata.json",
  client_id: context["client_id"],
  client_secret: context["client_secret"]
]

case Sake.Client.connect(url, on_input: on_input, auth: auth) do
  {:ok, session} ->
    {tools, session} =
      case Sake.Client.list_tools(session) do
        {:ok, tools, session} ->
          report.("list_tools", Enum.map(tools, & &1.name))
          {tools, session}

        {:error, reason, session} ->
          report.("list_tools_error", reason)
          {[], session}
      end

    session =
      Enum.reduce(tools, session, fn tool, session ->
        case Sake.Client.call_tool(session, tool.name, %{}) do
          {:ok, result, session} ->
            report.("call_tool:#{tool.name}", result.text)
            session

          {:error, reason, session} ->
            report.("call_tool_error:#{tool.name}", reason)
            session
        end
      end)

    {resources, session} =
      case Sake.Client.list_resources(session) do
        {:ok, resources, session} ->
          report.("list_resources", Enum.map(resources, & &1["uri"]))
          {resources, session}

        {:error, reason, session} ->
          report.("list_resources_error", reason)
          {[], session}
      end

    session =
      Enum.reduce(resources, session, fn resource, session ->
        case Sake.Client.read_resource(session, resource["uri"]) do
          {:ok, contents, session} ->
            report.("read_resource:#{resource["uri"]}", length(contents))
            session

          {:error, reason, session} ->
            report.("read_resource_error:#{resource["uri"]}", reason)
            session
        end
      end)

    {prompts, session} =
      case Sake.Client.list_prompts(session) do
        {:ok, prompts, session} ->
          report.("list_prompts", Enum.map(prompts, & &1["name"]))
          {prompts, session}

        {:error, reason, session} ->
          report.("list_prompts_error", reason)
          {[], session}
      end

    final_session =
      Enum.reduce(prompts, session, fn prompt, session ->
        case Sake.Client.get_prompt(session, prompt["name"], %{}) do
          {:ok, result, session} ->
            report.("get_prompt:#{prompt["name"]}", Map.get(result, "messages"))
            session

          {:error, reason, session} ->
            report.("get_prompt_error:#{prompt["name"]}", reason)
            session
        end
      end)

    Sake.Client.close(final_session)

  {:error, reason} ->
    report.("connect_error", reason)
end
