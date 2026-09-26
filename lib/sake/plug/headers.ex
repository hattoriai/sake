defmodule Sake.Plug.Headers do
  @moduledoc """
  The request headers that mirror the body on the modern Streamable HTTP
  transport: `Mcp-Method`, `Mcp-Name` and `Mcp-Param-*`, with the Base64
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

    case {value, Plug.Conn.get_req_header(conn, header)} do
      {nil, []} ->
        {:cont, :ok}

      {nil, [_ | _]} ->
        {:halt, {:error, "#{display} header is present but the body has no value"}}

      {_value, []} ->
        {:halt, {:error, "#{display} header is missing"}}

      {value, [raw | _]} ->
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
    case Plug.Conn.get_req_header(conn, header) do
      [] ->
        {:error, "#{display} header is missing"}

      [raw | _] ->
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
