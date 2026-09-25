defmodule Sake.JSONRPCTest do
  use ExUnit.Case, async: true

  alias Sake.JSONRPC

  test "builds messages" do
    assert JSONRPC.request(1, "tools/list") == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "tools/list"
           }

    assert JSONRPC.request("a", "tools/call", %{"name" => "x"}) ==
             %{
               "jsonrpc" => "2.0",
               "id" => "a",
               "method" => "tools/call",
               "params" => %{"name" => "x"}
             }

    assert JSONRPC.notification("notifications/initialized") == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized"
           }

    assert JSONRPC.result(1, %{"tools" => []}) == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{"tools" => []}
           }

    assert JSONRPC.error(1, -32_601, "Method not found") ==
             %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32_601, "message" => "Method not found"}
             }

    assert JSONRPC.error(nil, -32_700, "Parse error", %{"x" => 1})["error"]["data"] == %{"x" => 1}
  end

  test "parses messages" do
    assert JSONRPC.parse(%{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "m",
             "params" => %{"a" => 1}
           }) == {:request, 1, "m", %{"a" => 1}}

    assert JSONRPC.parse(%{"jsonrpc" => "2.0", "id" => 1, "method" => "m"}) ==
             {:request, 1, "m", %{}}

    assert JSONRPC.parse(%{"jsonrpc" => "2.0", "method" => "n"}) == {:notification, "n", %{}}

    assert JSONRPC.parse(%{"jsonrpc" => "2.0", "id" => "x", "result" => %{}}) ==
             {:response, "x", %{}}

    assert JSONRPC.parse(%{
             "jsonrpc" => "2.0",
             "id" => 2,
             "error" => %{"code" => -1, "message" => "m"}
           }) ==
             {:error_response, 2, %{"code" => -1, "message" => "m"}}

    assert {:batch, [{:request, 1, "a", %{}}, {:notification, "b", %{}}]} =
             JSONRPC.parse([
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "a"},
               %{"jsonrpc" => "2.0", "method" => "b"}
             ])
  end

  test "rejects malformed messages" do
    assert JSONRPC.parse(%{"id" => 1, "method" => "m"}) == {:error, :malformed}

    assert JSONRPC.parse(%{"jsonrpc" => "2.0", "id" => nil, "method" => "m"}) ==
             {:error, :malformed}

    assert JSONRPC.parse(%{"jsonrpc" => "2.0", "id" => 1.5, "method" => "m"}) ==
             {:error, :malformed}

    assert JSONRPC.parse(%{"jsonrpc" => "2.0", "id" => 1, "method" => "m", "params" => [1]}) ==
             {:error, :malformed}

    assert JSONRPC.parse([]) == {:error, :malformed}
    assert JSONRPC.parse("x") == {:error, :malformed}
  end

  test "error codes" do
    assert JSONRPC.code(:parse_error) == -32_700
    assert JSONRPC.code(:invalid_request) == -32_600
    assert JSONRPC.code(:method_not_found) == -32_601
    assert JSONRPC.code(:invalid_params) == -32_602
    assert JSONRPC.code(:internal) == -32_603
    assert JSONRPC.code(:header_mismatch) == -32_020
    assert JSONRPC.code(:missing_capability) == -32_021
    assert JSONRPC.code(:unsupported_version) == -32_022
    assert JSONRPC.code(:legacy_resource_not_found) == -32_002
  end
end
