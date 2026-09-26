defmodule Sake.Server.SessionTest do
  use ExUnit.Case, async: true

  alias Sake.Server.Session

  @secret String.duplicate("k", 64)

  test "mint and verify" do
    id = Session.mint(@secret, "2025-06-18", %{"elicitation" => %{}})
    assert is_binary(id) and byte_size(id) < 512
    assert Regex.match?(~r/^[A-Za-z0-9._\-]+$/, id)

    assert {:ok, %{revision: "2025-06-18", capabilities: %{"elicitation" => %{}}, minted_at: t}} =
             Session.verify(@secret, id)

    assert_in_delta t, System.system_time(:second), 5
    assert Session.verify(@secret, id <> "x") == :error
    assert Session.verify(String.duplicate("z", 64), id) == :error
    refute Session.renew?(%{minted_at: System.system_time(:second)})
    assert Session.renew?(%{minted_at: System.system_time(:second) - 90_000})
  end
end
