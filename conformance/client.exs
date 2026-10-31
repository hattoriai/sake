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

# Some scenarios pass the tool calls they want made (with arguments) as
# JSON in MCP_CONFORMANCE_CONTEXT.
context =
  case System.get_env("MCP_CONFORMANCE_CONTEXT") do
    nil -> %{}
    json -> JSON.decode!(json)
  end

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

# The authorization extensions' scenarios run a grant without a person;
# their credentials (a secret or a private key, the workload's JWT, the
# person's ID token and the identity provider) arrive in the context too.
auth =
  case scenario do
    "auth/client-credentials-basic" ->
      Keyword.put(auth, :grant, :client_credentials)

    "auth/client-credentials-jwt" ->
      [
        grant: :client_credentials,
        client_id: context["client_id"],
        private_key: {context["private_key_pem"], context["signing_algorithm"]}
      ]

    "auth/wif-jwt-bearer" ->
      [grant: :jwt_bearer, client_id: context["client_id"], assertion: context["valid_jwt"]]

    "auth/enterprise-managed-authorization" ->
      Keyword.merge(auth,
        grant: :enterprise,
        id_token: context["idp_id_token"],
        idp: [token_endpoint: context["idp_token_endpoint"], client_id: context["idp_client_id"]]
      )

    _ ->
      auth
  end

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

    # A plain value of the right type for every required argument, the
    # way a model filling in a call would have to.
    sample = fn
      %{"type" => "number"} -> 1
      %{"type" => "integer"} -> 1
      %{"type" => "boolean"} -> true
      %{"type" => "object"} -> %{}
      %{"type" => "array"} -> []
      _ -> "test"
    end

    by_name = Map.new(tools, &{&1.name, &1})

    arguments = fn
      # json-schema-2020-12-preservation: the echo tool takes another
      # tool's input schema back verbatim, so the suite can see what
      # survived the client's parsing.
      %{name: "json_schema_echo"} ->
        %{"schema" => by_name["json_schema_2020_12_tool"].input_schema}

      tool ->
        schema = tool.input_schema
        properties = schema["properties"] || %{}
        Map.new(schema["required"] || [], &{&1, sample.(properties[&1] || %{})})
    end

    calls =
      case context["toolCalls"] do
        nil -> Enum.map(tools, &{&1.name, arguments.(&1)})
        listed -> Enum.map(listed, &{&1["name"], &1["arguments"] || %{}})
      end

    session =
      Enum.reduce(calls, session, fn {name, args}, session ->
        case Sake.Client.call_tool(session, name, args) do
          {:ok, result, session} ->
            report.("call_tool:#{name}", result.text)
            session

          {:error, reason, session} ->
            report.("call_tool_error:#{name}", reason)
            session
        end
      end)

    # Skills (SEP-2640): the client lists them, as a host does on
    # connecting, and loads the first, as a host does once its model
    # needs it: SKILL.md, checked against the entry, then the files the
    # entry lists, each checked too, stopping at the first that fails.
    # In `sep-2640-client-no-prefetch` the host never needs the skill, so
    # it reads nothing: listing alone must not fetch a file.
    session =
      with true <- Sake.Client.skills?(session),
           {:ok, skills, session} <- Sake.Client.list_skills(session) do
        report.("list_skills", Enum.map(skills, & &1["uri"]))

        case skills do
          [skill | _] when scenario != "sep-2640-client-no-prefetch" ->
            files =
              case skill["resources"] do
                list when is_list(list) -> Enum.map(list, & &1["uri"]) -- [skill["uri"]]
                _ -> []
              end

            Enum.reduce_while([skill["uri"] | files], session, fn uri, session ->
              case Sake.Client.read_skill_file(session, skill, uri) do
                {:ok, bytes, session} ->
                  report.("read_skill_file:#{uri}", byte_size(bytes))
                  {:cont, session}

                {:error, reason, session} ->
                  report.("read_skill_file_error:#{uri}", reason)
                  {:halt, session}
              end
            end)

          _ ->
            session
        end
      else
        false ->
          session

        {:error, reason, session} ->
          report.("list_skills_error", reason)
          session
      end

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
