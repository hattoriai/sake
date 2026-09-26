defmodule Sake.Elicit do
  @moduledoc """
  Asks the person for input from inside a component.

      case Sake.Elicit.form(ctx, :who, "Who should be greeted?", schema) do
        {:ok, %{"name" => name}} -> ...
        :decline -> ...
        :cancel -> ...
        {:error, :unsupported} -> ...
      end

  On a modern connection the call ends the handler; Sake answers the client
  with an input-required result, and when the client retries, the handler
  runs again and the same call returns the answer. So a handler must have
  no side effects before its elicitation calls. On a legacy connection the
  call blocks until the client answers on the stream; the request carries
  the handler's key in `_meta` under `"ai.hattori.sake/key"`, so a client
  can tell which question is being asked.
  """

  alias Sake.Context

  @timeout 300_000
  @vendor_key "ai.hattori.sake/key"

  @spec form(Context.t(), atom() | String.t(), String.t(), map()) ::
          {:ok, map()} | :decline | :cancel | {:error, :unsupported}
  def form(ctx, key, message, schema) do
    ask(ctx, to_string(key), %{
      "mode" => "form",
      "message" => message,
      "requestedSchema" => schema
    })
  end

  @spec url(Context.t(), atom() | String.t(), String.t(), String.t()) ::
          :ok | :decline | :cancel | {:error, :unsupported}
  def url(ctx, key, message, url) do
    if ctx.era == :legacy and ctx.protocol_version < "2025-11-25" do
      {:error, :unsupported}
    else
      case ask(ctx, to_string(key), %{"mode" => "url", "message" => message, "url" => url}) do
        {:ok, _} -> :ok
        other -> other
      end
    end
  end

  defp ask(ctx, key, params) do
    if Map.has_key?(ctx.client_capabilities, "elicitation") do
      answer(ctx, key, params)
    else
      {:error, :unsupported}
    end
  end

  # An answer in `ctx.inputs` is only ever honoured once the capability
  # check above has passed, so a client that never declared `elicitation`
  # cannot have its `inputResponses` read back as one.
  defp answer(ctx, key, params) do
    case Map.fetch(ctx.inputs, key) do
      {:ok, answer} ->
        normalize(answer)

      :error ->
        if ctx.era == :modern do
          throw(
            {:sake_input_required, key, %{"method" => "elicitation/create", "params" => params}}
          )
        else
          legacy(ctx, key, params)
        end
    end
  end

  defp legacy(%Context{transport: pid}, key, params) when is_pid(pid) do
    id = "sake-elicit-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
    :ok = Sake.Plug.Streams.register_elicit(id)
    params = Map.update(params, "_meta", %{@vendor_key => key}, &Map.put(&1, @vendor_key, key))
    send(pid, {:sake_elicit, self(), id, params})

    receive do
      {:sake_elicit_response, ^id, {:ok, answer}} -> normalize(answer)
      {:sake_elicit_response, ^id, {:error, _}} -> :cancel
    after
      @timeout -> :cancel
    end
  end

  defp legacy(_ctx, _key, _params), do: {:error, :unsupported}

  defp normalize(%{"action" => "accept"} = a), do: {:ok, a["content"] || %{}}
  defp normalize(%{"action" => "decline"}), do: :decline
  defp normalize(_), do: :cancel
end
