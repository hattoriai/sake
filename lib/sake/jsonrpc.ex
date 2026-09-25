defmodule Sake.JSONRPC do
  @moduledoc """
  JSON-RPC 2.0 messages as MCP uses them: requests with a string or integer
  id, notifications without one, results, errors, and batches (legacy
  revision 2025-03-26 only).
  """

  @type id :: String.t() | integer()
  @type parsed ::
          {:request, id(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:response, id(), map()}
          | {:error_response, id() | nil, map()}
          | {:batch, [parsed()]}
          | {:error, :malformed}

  @codes %{
    parse_error: -32_700,
    invalid_request: -32_600,
    method_not_found: -32_601,
    invalid_params: -32_602,
    internal: -32_603,
    header_mismatch: -32_020,
    missing_capability: -32_021,
    unsupported_version: -32_022,
    legacy_resource_not_found: -32_002
  }

  @spec code(atom()) :: integer()
  def code(name), do: Map.fetch!(@codes, name)

  @spec request(id(), String.t(), map() | nil) :: map()
  def request(id, method, params \\ nil) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method} |> put_params(params)
  end

  @spec notification(String.t(), map() | nil) :: map()
  def notification(method, params \\ nil) do
    %{"jsonrpc" => "2.0", "method" => method} |> put_params(params)
  end

  @spec result(id(), map()) :: map()
  def result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @spec error(id() | nil, integer(), String.t(), term()) :: map()
  def error(id, code, message, data \\ nil) do
    err = %{"code" => code, "message" => message}
    err = if data == nil, do: err, else: Map.put(err, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => err}
  end

  @spec parse(term()) :: parsed()
  def parse([_ | _] = batch) do
    parsed = Enum.map(batch, &parse/1)

    if Enum.any?(parsed, &match?({:error, _}, &1)),
      do: {:error, :malformed},
      else: {:batch, parsed}
  end

  def parse(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = msg) when is_binary(method) do
    with true <- valid_id?(id), {:ok, params} <- params(msg) do
      {:request, id, method, params}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse(%{"jsonrpc" => "2.0", "method" => method} = msg)
      when is_binary(method) and not is_map_key(msg, "id") do
    case params(msg) do
      {:ok, params} -> {:notification, method, params}
      _ -> {:error, :malformed}
    end
  end

  def parse(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) when is_map(result) do
    if valid_id?(id), do: {:response, id, result}, else: {:error, :malformed}
  end

  def parse(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => c, "message" => m} = error})
      when is_integer(c) and is_binary(m) do
    if id == nil or valid_id?(id), do: {:error_response, id, error}, else: {:error, :malformed}
  end

  def parse(_), do: {:error, :malformed}

  defp valid_id?(id), do: is_binary(id) or is_integer(id)

  defp params(%{"params" => p}) when is_map(p), do: {:ok, p}
  defp params(%{"params" => _}), do: :error
  defp params(_), do: {:ok, %{}}

  defp put_params(msg, nil), do: msg
  defp put_params(msg, params), do: Map.put(msg, "params", params)
end
