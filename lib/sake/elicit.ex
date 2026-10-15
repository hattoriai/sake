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
  alias Sake.Server.Ask

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
    case Ask.request(ctx, "elicitation", key, "elicitation/create", params) do
      {:ok, answer} -> normalize(answer)
      {:error, :unsupported} -> {:error, :unsupported}
      {:error, _} -> :cancel
    end
  end

  defp normalize(%{"action" => "accept"} = a), do: {:ok, a["content"] || %{}}
  defp normalize(%{"action" => "decline"}), do: :decline
  defp normalize(_), do: :cancel
end
