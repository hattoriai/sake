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
  call blocks until the client answers on the stream.
  """

  alias Sake.Context

  @timeout 300_000

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
    case Map.fetch(ctx.inputs, key) do
      {:ok, answer} ->
        normalize(answer)

      :error ->
        cond do
          not Map.has_key?(ctx.client_capabilities, "elicitation") ->
            {:error, :unsupported}

          ctx.era == :modern ->
            throw(
              {:sake_input_required, key, %{"method" => "elicitation/create", "params" => params}}
            )

          true ->
            legacy(ctx, key, params)
        end
    end
  end

  defp legacy(%Context{transport: pid}, _key, params) when is_pid(pid) do
    id = "sake-elicit-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))
    :ok = Sake.Plug.Streams.register_elicit(id)
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
