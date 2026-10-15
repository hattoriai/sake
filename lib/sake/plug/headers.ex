defmodule Sake.Plug.Headers do
  @moduledoc """
  The request headers that mirror the body on the modern Streamable HTTP
  transport: `Mcp-Method`, `Mcp-Name` (the tool or prompt name, the
  resource URI, or the task ID) and `Mcp-Param-*`, with the Base64
  sentinel encoding for values that are not plain ASCII.
  """

  @sentinel_start "=?base64?"
  @sentinel_end "?="

  @doc "Encodes a string, integer or boolean for a header."
  @spec encode_value(String.t() | integer() | boolean()) :: String.t()
  def encode_value(v) when is_integer(v), do: Integer.to_string(v)
  def encode_value(true), do: "true"
  def encode_value(false), do: "false"

  def encode_value(v) when is_binary(v) do
    if plain?(v) and not sentinel?(v),
      do: v,
      else: @sentinel_start <> Base.encode64(v) <> @sentinel_end
  end

  @spec decode_value(String.t()) :: {:ok, String.t()} | :error
  def decode_value(v) do
    if sentinel?(v) do
      inner =
        v
        |> String.replace_prefix(@sentinel_start, "")
        |> String.replace_suffix(@sentinel_end, "")

      Base.decode64(inner)
    else
      {:ok, v}
    end
  end

  defp sentinel?(v),
    do: String.starts_with?(v, @sentinel_start) and String.ends_with?(v, @sentinel_end)

  defp plain?(v) do
    v != "" and v == String.trim(v) and
      String.to_charlist(v) |> Enum.all?(&(&1 in 0x21..0x7E or &1 == 0x20))
  end

  defp header_safe?(v),
    do: String.to_charlist(v) |> Enum.all?(&(&1 in 0x21..0x7E or &1 in [0x20, 0x09]))

  # RFC 9110 §5.5: the whitespace around a field value is not part of it.
  # Plug hands the value over as the client sent it, so it is stripped
  # here, before any comparison with the body.
  defp field_value(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] -> nil
      [raw | _] -> String.replace(raw, ~r/\A[ \t]+|[ \t]+\z/, "")
    end
  end

  @doc "Checks the mirrored headers of a modern request against the body."
  @spec validate(Plug.Conn.t(), Sake.JSONRPC.parsed(), Sake.Tool.Spec.t() | nil) ::
          :ok | {:error, String.t()}
  def validate(conn, {:request, _id, method, params}, spec) do
    with :ok <- check(conn, "mcp-method", "Mcp-Method", method),
         :ok <- name(conn, method, params),
         do: params(conn, method, params, spec)
  end

  def validate(_conn, _parsed, _spec), do: :ok

  defp name(conn, "tools/call", params), do: check(conn, "mcp-name", "Mcp-Name", params["name"])
  defp name(conn, "prompts/get", params), do: check(conn, "mcp-name", "Mcp-Name", params["name"])

  defp name(conn, "resources/read", params),
    do: check(conn, "mcp-name", "Mcp-Name", params["uri"])

  # The tasks extension routes on the task ID.
  defp name(conn, method, %{"taskId" => id})
       when method in ["tasks/get", "tasks/update", "tasks/cancel"] and is_binary(id),
       do: check(conn, "mcp-name", "Mcp-Name", id)

  defp name(_conn, _method, _params), do: :ok

  defp params(conn, "tools/call", params, %Sake.Tool.Spec{headers: headers})
       when headers != %{} do
    args = params["arguments"] || %{}

    Enum.reduce_while(headers, :ok, fn {hname, path}, :ok ->
      check_param(conn, hname, get_in(args, path))
    end)
  end

  defp params(_conn, _method, _params, _spec), do: :ok

  defp check_param(conn, hname, value) do
    header = "mcp-param-" <> String.downcase(hname)
    display = "Mcp-Param-" <> hname

    case {value, field_value(conn, header)} do
      {nil, nil} ->
        {:cont, :ok}

      {nil, _raw} ->
        {:halt, {:error, "#{display} header is present but the body has no value"}}

      {_value, nil} ->
        {:halt, {:error, "#{display} header is missing"}}

      {value, raw} ->
        check_param_value(display, value, raw)
    end
  end

  defp check_param_value(display, value, raw) do
    if header_safe?(raw) do
      param_match(display, value, decode_value(raw))
    else
      {:halt, {:error, "#{display} header contains invalid characters"}}
    end
  end

  defp param_match(display, value, {:ok, decoded}) do
    if same?(decoded, value),
      do: {:cont, :ok},
      else:
        {:halt,
         {:error, "#{display} header value '#{decoded}' does not match body value '#{value}'"}}
  end

  defp param_match(display, _value, :error),
    do: {:halt, {:error, "#{display} header contains invalid characters"}}

  defp check(conn, header, display, expected) do
    case field_value(conn, header) do
      nil ->
        {:error, "#{display} header is missing"}

      raw ->
        case decode_value(raw) do
          {:ok, ^expected} ->
            :ok

          {:ok, other} ->
            {:error, "#{display} header value '#{other}' does not match body value '#{expected}'"}

          :error ->
            {:error, "#{display} header contains invalid characters"}
        end
    end
  end

  defp same?(decoded, value) when is_binary(value), do: decoded == value
  defp same?(decoded, true), do: decoded == "true"
  defp same?(decoded, false), do: decoded == "false"

  defp same?(decoded, value) when is_number(value) do
    case Float.parse(decoded) do
      {f, ""} -> f == value / 1
      _ -> false
    end
  end

  defp same?(_, _), do: false
end
