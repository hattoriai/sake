defmodule Sake.Plug.HeadersTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Sake.Plug.Headers

  test "value encoding" do
    assert Headers.encode_value("us-west1") == "us-west1"
    assert Headers.encode_value(42) == "42"
    assert Headers.encode_value(true) == "true"
    assert Headers.encode_value("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?="
    assert Headers.encode_value(" padded ") == "=?base64?IHBhZGRlZCA=?="
    assert Headers.encode_value("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?="
    assert Headers.encode_value("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="
    assert Headers.decode_value("=?base64?SGVsbG8sIOS4lueVjA==?=") == {:ok, "Hello, 世界"}
    assert Headers.decode_value("plain") == {:ok, "plain"}
    assert Headers.decode_value("=?base64?***?=") == :error
  end

  defp conn_with(headers) do
    Enum.reduce(headers, conn(:post, "/mcp"), fn {k, v}, c -> put_req_header(c, k, v) end)
  end

  test "method and name mirroring" do
    parsed = {:request, 1, "tools/call", %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2}}}
    {:ok, spec} = Sake.Server.tool(SakeDev.Server, "add")

    assert :ok =
             Headers.validate(
               conn_with([{"mcp-method", "tools/call"}, {"mcp-name", "add"}]),
               parsed,
               spec
             )

    assert {:error, "Mcp-Method header is missing"} =
             Headers.validate(conn_with([{"mcp-name", "add"}]), parsed, spec)

    assert {:error, "Mcp-Method header value 'tools/list' does not match body value 'tools/call'"} =
             Headers.validate(
               conn_with([{"mcp-method", "tools/list"}, {"mcp-name", "add"}]),
               parsed,
               spec
             )

    assert {:error, "Mcp-Name header is missing"} =
             Headers.validate(conn_with([{"mcp-method", "tools/call"}]), parsed, spec)

    assert :ok =
             Headers.validate(
               conn_with([{"mcp-method", "tools/call"}, {"mcp-name", "=?base64?YWRk?="}]),
               parsed,
               spec
             )

    assert :ok =
             Headers.validate(
               conn_with([{"mcp-method", "tools/list"}]),
               {:request, 1, "tools/list", %{}},
               nil
             )
  end

  test "param mirroring" do
    parsed =
      {:request, 1, "tools/call",
       %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2, "precision" => 2}}}

    {:ok, spec} = Sake.Server.tool(SakeDev.Server, "add")
    base = [{"mcp-method", "tools/call"}, {"mcp-name", "add"}]
    assert :ok = Headers.validate(conn_with(base ++ [{"mcp-param-precision", "2"}]), parsed, spec)

    assert :ok =
             Headers.validate(conn_with(base ++ [{"mcp-param-precision", "2.0"}]), parsed, spec)

    assert {:error, "Mcp-Param-Precision header is missing"} =
             Headers.validate(conn_with(base), parsed, spec)

    assert {:error, "Mcp-Param-Precision header value '3' does not match body value '2'"} =
             Headers.validate(conn_with(base ++ [{"mcp-param-precision", "3"}]), parsed, spec)

    absent = {:request, 1, "tools/call", %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2}}}
    assert :ok = Headers.validate(conn_with(base), absent, spec)

    assert {:error, "Mcp-Param-Precision header is present but the body has no value"} =
             Headers.validate(conn_with(base ++ [{"mcp-param-precision", "1"}]), absent, spec)

    null =
      {:request, 1, "tools/call",
       %{"name" => "add", "arguments" => %{"a" => 1, "b" => 2, "precision" => nil}}}

    assert :ok = Headers.validate(conn_with(base), null, spec)

    assert {:error, "Mcp-Param-Precision header contains invalid characters"} =
             Headers.validate(conn_with(base ++ [{"mcp-param-precision", "2\x01"}]), parsed, spec)
  end
end
