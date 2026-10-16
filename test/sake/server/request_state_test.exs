defmodule Sake.Server.RequestStateTest do
  use ExUnit.Case, async: true

  alias Sake.Auth.TokenRecord
  alias Sake.Server.RequestState

  defmodule Acme do
    use Sake.Server, name: "acme", version: "1"
  end

  defmodule Beta do
    use Sake.Server, name: "beta", version: "1"
  end

  @secret String.duplicate("s", 64)
  @args %{"project" => "p1"}
  @inputs %{"who" => %{"action" => "accept", "content" => %{"name" => "Alice"}}}

  defp ctx(overrides \\ []) do
    token = %TokenRecord{
      subject_id: "alice",
      client_id: "client-a",
      resource: "https://audit.example/acme/mcp",
      scopes: ["admin"]
    }

    Sake.Context.new(
      Keyword.merge(
        [secret: @secret, method: "tools/call", server: Acme, token: token, scopes: token.scopes],
        overrides
      )
    )
  end

  defp token(changes), do: struct!(ctx().token, changes)

  test "the owner's continuation verifies, with its answers" do
    state = RequestState.sign(ctx(), "export", @args, @inputs)
    assert {:ok, @inputs} = RequestState.verify(ctx(), "export", @args, state)
    assert {:ok, @inputs} = RequestState.verify(ctx(scopes: []), "export", @args, state)
  end

  test "a state is bound to the server, client, resource, subject and issuer" do
    state = RequestState.sign(ctx(), "export", @args, @inputs)

    for other <- [
          ctx(server: Beta),
          ctx(token: token(client_id: "client-b")),
          ctx(token: token(resource: "https://audit.example/beta/mcp")),
          ctx(token: token(subject_id: "bob")),
          ctx(token: token(issuer: "https://idp.example")),
          ctx(token: token(subject_id: nil)),
          ctx(token: nil, scope: "alice"),
          ctx(token: nil)
        ] do
      assert :error = RequestState.verify(other, "export", @args, state)
    end
  end

  test "host scopes whose phash2 collide are still different principals" do
    a = "audit-user-10889"
    b = "audit-user-21717"
    assert :erlang.phash2(a) == :erlang.phash2(b)

    state = RequestState.sign(ctx(token: nil, scope: a), "export", @args, @inputs)
    assert {:ok, @inputs} = RequestState.verify(ctx(token: nil, scope: a), "export", @args, state)
    assert :error = RequestState.verify(ctx(token: nil, scope: b), "export", @args, state)
  end

  test "the method, component and arguments are bound" do
    state = RequestState.sign(ctx(), "export", @args, @inputs)

    assert :error = RequestState.verify(ctx(method: "prompts/get"), "export", @args, state)
    assert :error = RequestState.verify(ctx(), "import", @args, state)
    assert :error = RequestState.verify(ctx(), "export", %{"project" => "p2"}, state)
    assert :error = RequestState.verify(ctx(), "export", @args, state <> "x")
    assert :error = RequestState.verify(ctx(), "export", @args, nil)
  end

  test "an expired state does not verify" do
    payload = %{
      o: Sake.Tasks.owner(ctx()),
      m: "tools/call",
      n: "export",
      d: :sha256 |> :crypto.hash(:erlang.term_to_binary([{"project", "p1"}])) |> Base.encode16(),
      i: @inputs
    }

    sign = &Plug.Crypto.sign(@secret, "sake.request_state", &1, &2)

    assert {:ok, @inputs} = RequestState.verify(ctx(), "export", @args, sign.(payload, []))

    expired = sign.(payload, signed_at: System.system_time(:second) - 601)
    assert :error = RequestState.verify(ctx(), "export", @args, expired)
  end
end
