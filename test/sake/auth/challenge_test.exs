defmodule Sake.Auth.ChallengeTest do
  use ExUnit.Case, async: true
  alias Sake.Auth.Challenge

  test "parses bearer challenges" do
    assert %Challenge{
             scheme: "Bearer",
             resource_metadata: "https://mcp.example.com/.well-known/oauth-protected-resource",
             scope: ["files:read"]
           } =
             Challenge.parse(
               ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read")
             )

    assert %Challenge{
             error: "insufficient_scope",
             scope: ["files:write", "x"],
             error_description: "File write permission required"
           } =
             Challenge.parse(
               ~s(Bearer error="insufficient_scope", scope="files:write x", resource_metadata="https://m/.well-known/oauth-protected-resource", error_description="File write permission required")
             )

    assert %Challenge{scheme: "Bearer", scope: []} = Challenge.parse("Bearer")
    assert %Challenge{scheme: "Basic"} = Challenge.parse(~s(Basic realm="sake"))
  end
end
