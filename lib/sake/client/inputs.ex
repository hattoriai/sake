defmodule Sake.Client.Inputs do
  @moduledoc false
  # Answers a server's requests to the client, by method: `on_input:` for
  # `elicitation/create`, `sampling:` for `sampling/createMessage`, `roots:`
  # for `roots/list`. A request nothing can answer has no entry, except an
  # elicitation, which is answered "cancel" (the person did not answer).

  alias Sake.Client.Session

  @type answer :: {:ok, map()} | {:error, map()}

  @spec answer(Session.t(), %{String.t() => map()}) :: %{String.t() => answer()}
  def answer(session, requests) do
    {elicitations, others} =
      Map.split_with(requests, fn {_key, request} ->
        request["method"] == "elicitation/create"
      end)

    others
    |> Enum.flat_map(fn {key, request} ->
      case answer_one(session, request) do
        nil -> []
        answer -> [{key, answer}]
      end
    end)
    |> Map.new()
    |> Map.merge(elicit(session, elicitations))
  end

  defp elicit(_session, requests) when requests == %{}, do: %{}

  defp elicit(%Session{on_input: nil}, requests),
    do: Map.new(requests, fn {key, _} -> {key, {:ok, %{"action" => "cancel"}}} end)

  defp elicit(%Session{on_input: fun} = session, requests) do
    answers = fun.(requests, session)
    Map.new(requests, fn {key, _} -> {key, {:ok, answers[key] || %{"action" => "cancel"}}} end)
  end

  defp answer_one(%Session{sampling: fun} = session, %{"method" => "sampling/createMessage"} = r)
       when is_function(fun, 2) do
    case fun.(r["params"] || %{}, session) do
      {:ok, %{} = result} -> {:ok, result}
      {:error, %{} = error} -> {:error, error}
    end
  end

  defp answer_one(%Session{roots: roots} = session, %{"method" => "roots/list"})
       when roots != nil do
    roots = if is_function(roots, 1), do: roots.(session), else: roots
    {:ok, %{"roots" => roots}}
  end

  defp answer_one(_session, _request), do: nil
end
