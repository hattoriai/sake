defmodule Sake.Server.Mount do
  @moduledoc false
  # A server mounted inside another (`Sake.Server.mount/2`): its tools,
  # resources and prompts become the parent's, renamed under the mount's
  # prefix, and each keeps the spec it had in the mounted server in its
  # `mount` field, `{server, prefix, spec}`. That chain, outermost first,
  # is what lets the mounted server's middleware see its components as it
  # declared them, a component see its own server in `ctx.server`, and a
  # URI the component produces (a template's `list/1`, a broadcast) be
  # renamed on its way out.
  #
  # Names take the prefix with an underscore (`billing` + `create_invoice`
  # is `billing_create_invoice`), as FastMCP's mounts do. A URI takes it
  # as the first segment after the scheme (`invoice://{id}` becomes
  # `invoice://billing/{id}`, `ui://dashboard` becomes
  # `ui://billing/dashboard`), which keeps the scheme: an MCP App stays a
  # `ui://` resource, and the tool that shows it links the renamed URI.

  @prefix_re ~r/^[A-Za-z0-9][A-Za-z0-9_\-]{0,63}$/
  @uri_re ~r/^([A-Za-z][A-Za-z0-9+.\-]*:\/\/)(.*)$/s

  @type chain :: [{module(), keyword()}]

  @doc "Checks a mount's options and returns them with the scopes as a list."
  @spec options!(module(), module(), keyword()) :: keyword()
  def options!(parent, server, opts) do
    case Keyword.keys(opts) -- [:prefix, :scope] do
      [] ->
        :ok

      keys ->
        raise ArgumentError,
              "#{inspect(parent)}: mount takes prefix: and scope:, got #{inspect(keys)}"
    end

    prefix = opts[:prefix]

    if prefix != nil and not (is_binary(prefix) and Regex.match?(@prefix_re, prefix)) do
      raise ArgumentError,
            "#{inspect(parent)}: the prefix of #{inspect(server)} must be 1-64 letters, digits, _ or -, " <>
              "starting with a letter or digit, got #{inspect(prefix)}"
    end

    [prefix: prefix, scopes: List.wrap(opts[:scope])]
  end

  @doc "A component's name under the mount's prefix."
  @spec name(String.t() | nil, String.t()) :: String.t()
  def name(nil, name), do: name
  def name(prefix, name), do: prefix <> "_" <> name

  @doc "The name a mount's prefix gave, without it; `:error` for a name it did not give."
  @spec unname(String.t() | nil, String.t()) :: {:ok, String.t()} | :error
  def unname(nil, name), do: {:ok, name}

  def unname(prefix, name) do
    case String.split_at(name, byte_size(prefix) + 1) do
      {^prefix <> "_", rest} when rest != "" -> {:ok, rest}
      _ -> :error
    end
  end

  @doc "A URI under the mount's prefix; `:error` for one without a `scheme://`."
  @spec uri(String.t() | nil, String.t()) :: {:ok, String.t()} | :error
  def uri(nil, uri), do: {:ok, uri}

  def uri(prefix, uri) do
    case Regex.run(@uri_re, uri, capture: :all_but_first) do
      [scheme, rest] -> {:ok, scheme <> prefix <> "/" <> rest}
      nil -> :error
    end
  end

  @doc "The URI a mount's prefix gave, without it; `:error` for a URI it did not give."
  @spec unuri(String.t() | nil, String.t()) :: {:ok, String.t()} | :error
  def unuri(nil, uri), do: {:ok, uri}

  def unuri(prefix, uri) do
    with [scheme, rest] <- Regex.run(@uri_re, uri, capture: :all_but_first),
         {^prefix <> "/", rest} <- String.split_at(rest, byte_size(prefix) + 1) do
      {:ok, scheme <> rest}
    else
      _ -> :error
    end
  end

  @doc """
  The spec as the parent has it: renamed under the prefix, with the
  mount's scopes added and the mounted server's ttl as its ceiling.
  Raises (`ArgumentError`) for a name or URI the prefix cannot take.
  """
  @spec wrap(struct(), module(), keyword()) :: struct()
  def wrap(spec, server, opts) do
    case wrap_spec(spec, server, opts) do
      {:ok, wrapped} -> wrapped
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "As `wrap/3`, for a component known at runtime: `:error` instead of a raise."
  @spec try_wrap(struct(), module(), keyword()) :: {:ok, struct()} | :error
  def try_wrap(spec, server, opts) do
    case wrap_spec(spec, server, opts) do
      {:ok, wrapped} -> {:ok, wrapped}
      {:error, _message} -> :error
    end
  end

  defp wrap_spec(spec, server, opts) do
    prefix = opts[:prefix]

    with {:ok, renamed} <- rename(spec, prefix, server) do
      {:ok,
       %{
         renamed
         | scopes: Enum.uniq(spec.scopes ++ (opts[:scopes] || [])),
           ttl: ceiling(spec.ttl, server.__sake__(:ttl)),
           mount: {server, prefix, spec}
       }}
    end
  end

  defp rename(%Sake.Tool.Spec{} = spec, prefix, server) do
    name = name(prefix, spec.name)

    with :ok <- valid_name(name, server),
         {:ok, ui} <- ui(spec.ui, prefix, server) do
      {:ok, %{spec | name: name, ui: ui}}
    end
  end

  defp rename(%Sake.Prompt.Spec{} = spec, prefix, _server),
    do: {:ok, %{spec | name: name(prefix, spec.name)}}

  defp rename(%Sake.Resource.Spec{} = spec, prefix, server) do
    case uri(prefix, spec.uri) do
      {:ok, uri} -> {:ok, Sake.Resource.Spec.put_uri(spec, uri)}
      :error -> {:error, unprefixable(server, spec.uri, prefix)}
    end
  end

  defp valid_name(name, server) do
    if Regex.match?(~r/^[A-Za-z0-9_.\-]{1,128}$/, name),
      do: :ok,
      else:
        {:error,
         "#{inspect(server)}: the mounted tool name #{inspect(name)} is not a valid tool name"}
  end

  defp ui(nil, _prefix, _server), do: {:ok, nil}

  defp ui(uri, prefix, server) do
    case uri(prefix, uri) do
      {:ok, uri} -> {:ok, uri}
      :error -> {:error, unprefixable(server, uri, prefix)}
    end
  end

  defp unprefixable(server, uri, prefix) do
    "#{inspect(server)}: the URI #{inspect(uri)} has no scheme:// to put the prefix #{inspect(prefix)} after"
  end

  defp ceiling(nil, ttl), do: ttl
  defp ceiling(own, ttl), do: min(own, ttl)

  @doc "The spec as the server that declared it has it, at the end of the chain."
  @spec innermost(struct()) :: struct()
  def innermost(%{mount: {_server, _prefix, inner}}), do: innermost(inner)
  def innermost(spec), do: spec

  @doc """
  The context a component runs with: its own server's in `ctx.server`, so
  what it broadcasts with its own URIs reaches the parent's clients under
  the prefix.
  """
  @spec component_ctx(struct(), Sake.Context.t()) :: Sake.Context.t()
  def component_ctx(%{mount: {server, _prefix, inner}}, ctx),
    do: component_ctx(inner, %{ctx | server: server})

  def component_ctx(_spec, ctx), do: ctx

  @doc "A URI the component knows, as the client of the outermost server knows it."
  @spec outer_uri(struct(), String.t()) :: {:ok, String.t()} | :error
  def outer_uri(%{mount: {_server, prefix, inner}}, uri) do
    with {:ok, uri} <- outer_uri(inner, uri), do: uri(prefix, uri)
  end

  def outer_uri(_spec, uri), do: {:ok, uri}

  @doc "A URI the client of the outermost server sent, as the component knows it."
  @spec inner_uri(struct(), String.t()) :: {:ok, String.t()} | :error
  def inner_uri(%{mount: {_server, prefix, inner}}, uri) do
    with {:ok, uri} <- unuri(prefix, uri), do: inner_uri(inner, uri)
  end

  def inner_uri(_spec, uri), do: {:ok, uri}

  @doc """
  A mounted component's result as the client gets it: a URI in it (a
  resource link or an embedded resource of a tool's result, the contents
  of a read) that names a resource of the component's own server takes
  the mount's prefixes. Any other URI is left as it is: it is not the
  mounted server's to rename.
  """
  @spec outer_result(map(), struct()) :: map()
  def outer_result(result, %{mount: {_, _, _}} = spec) do
    owner = owner(spec)

    result
    |> update_list("content", &outer_content(&1, spec, owner))
    |> update_list("contents", &outer_uri_key(&1, spec, owner))
  end

  def outer_result(result, _spec), do: result

  defp owner(%{mount: {server, _prefix, %{mount: nil}}}), do: server
  defp owner(%{mount: {_server, _prefix, inner}}), do: owner(inner)

  defp update_list(result, key, fun) do
    case result do
      %{^key => list} when is_list(list) -> %{result | key => Enum.map(list, fun)}
      _ -> result
    end
  end

  defp outer_content(%{"type" => "resource_link"} = item, spec, owner),
    do: outer_uri_key(item, spec, owner)

  defp outer_content(%{"type" => "resource", "resource" => %{} = resource} = item, spec, owner),
    do: %{item | "resource" => outer_uri_key(resource, spec, owner)}

  defp outer_content(item, _spec, _owner), do: item

  defp outer_uri_key(%{"uri" => uri} = item, spec, owner) when is_binary(uri) do
    with {:ok, _spec, _params} <- Sake.Server.resource(owner, uri),
         {:ok, outer} <- outer_uri(spec, uri) do
      %{item | "uri" => outer}
    else
      _ -> item
    end
  end

  defp outer_uri_key(item, _spec, _owner), do: item

  @doc """
  The server and every server mounted in it, at any depth, each with the
  prefixes between it and the server, innermost first.
  """
  @spec tree(module()) :: [{module(), [String.t() | nil]}]
  def tree(server), do: [{server, []} | subtree(server, [])]

  defp subtree(server, prefixes) do
    Enum.flat_map(server.__sake__(:mounts), fn {mounted, opts} ->
      chain = [opts[:prefix] | prefixes]
      [{mounted, chain} | subtree(mounted, chain)]
    end)
  end

  @doc """
  A broadcast of a mounted server as the parent's clients get it: a
  resource URI takes the prefixes; `nil` for one that cannot.
  """
  @spec translate(term(), [String.t() | nil]) :: term() | nil
  def translate(event, []), do: event

  def translate({:resource_updated, uri}, prefixes) do
    Enum.reduce_while(prefixes, {:resource_updated, uri}, fn prefix, {:resource_updated, uri} ->
      case uri(prefix, uri) do
        {:ok, uri} -> {:cont, {:resource_updated, uri}}
        :error -> {:halt, nil}
      end
    end)
  end

  def translate(event, _prefixes), do: event
end
