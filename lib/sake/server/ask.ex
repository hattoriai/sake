defmodule Sake.Server.Ask do
  @moduledoc false
  # A request from the server to the client in the middle of a component:
  # `elicitation/create`, `sampling/createMessage` or `roots/list`. One
  # path for all three, on every transport:
  #
  #   * the client did not declare the capability: `{:error, :unsupported}`;
  #   * the answer is already in `ctx.inputs` (a modern retry): that answer;
  #   * inside a task: the request waits on the task (`Sake.Tasks.Worker`);
  #   * modern: a throw that `Sake.Server.Dispatch` turns into an
  #     input-required result;
  #   * legacy: a JSON-RPC request on the call's response stream, and the
  #     handler blocks until the client POSTs its answer.

  alias Sake.Context

  @timeout 300_000
  @vendor_key "ai.hattori.sake/key"

  @type answer ::
          {:ok, term()} | {:error, :unsupported | :cancelled | :timeout | map()}

  @spec request(Context.t(), String.t(), String.t(), String.t(), map()) :: answer()
  def request(ctx, capability, key, method, params) do
    if Map.has_key?(ctx.client_capabilities, capability),
      do: answer(ctx, key, %{"method" => method, "params" => params}),
      else: {:error, :unsupported}
  end

  # An answer in `ctx.inputs` is only ever honoured once the capability
  # check above has passed, so a client that never declared the capability
  # cannot have its `inputResponses` read back as one.
  defp answer(ctx, key, request) do
    case Map.fetch(ctx.inputs, key) do
      {:ok, answer} -> {:ok, answer}
      :error -> ask(ctx, key, request)
    end
  end

  defp ask(%Context{task: id} = ctx, key, request) when is_binary(id),
    do: Sake.Tasks.Worker.ask(ctx, key, request)

  defp ask(%Context{era: :modern}, key, request),
    do: throw({:sake_input_required, %{key => request}})

  defp ask(%Context{transport: pid}, key, request) when is_pid(pid),
    do: legacy(pid, key, request)

  defp ask(_ctx, _key, _request), do: {:error, :unsupported}

  defp legacy(pid, key, %{"method" => method, "params" => params}) do
    id = "sake-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
    :ok = Sake.Plug.Streams.register_request(id)
    params = Map.update(params, "_meta", %{@vendor_key => key}, &Map.put(&1, @vendor_key, key))
    send(pid, {:sake_request, self(), id, method, params})

    response =
      receive do
        {:sake_response, ^id, response} -> response
      after
        @timeout -> {:error, :timeout}
      end

    :ok = Sake.Plug.Streams.unregister_request(id)
    response
  end
end
