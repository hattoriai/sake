defmodule Sake.SecretTest do
  # `{Sake, secret_key_base: {MyAppWeb.Endpoint, :config, [:secret_key_base]}}`
  # sits before the endpoint in a supervision tree: the `{m, f, a}` cannot
  # answer when Sake starts, only once the endpoint has.
  use ExUnit.Case, async: false

  def secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      nil -> raise "not started yet"
      secret -> secret
    end
  end

  setup do
    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :secret})
      :persistent_term.erase({Sake, :secret_key_base})
    end)
  end

  test "an {m, f, a} secret is called when it is used, not when Sake starts" do
    start_supervised!(
      {Sake,
       secret_key_base: {__MODULE__, :secret, []},
       auth: [
         subject: SakeDev.Subject,
         issuer: "http://localhost",
         allow_insecure: true,
         servers: [SakeDev.Server]
       ],
       streams: false,
       tasks: false}
    )

    secret = String.duplicate("s", 64)
    :persistent_term.put({__MODULE__, :secret}, secret)

    assert Sake.Secret.configured() == secret
    assert Sake.Auth.Page.secret(Sake.Auth.config()) == secret
  end

  test "a secret that is neither a long binary nor {m, f, a} is refused when Sake starts" do
    assert {:error, reason} =
             start_supervised({Sake, secret_key_base: "short", streams: false, tasks: false})

    assert inspect(reason) =~ "at least 32 bytes"
  end
end
