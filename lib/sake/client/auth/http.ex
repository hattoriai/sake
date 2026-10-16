defmodule Sake.Client.Auth.HTTP do
  @moduledoc false
  # The authorization flow's own HTTP requests: metadata documents, client
  # registration and the token endpoint. None of them follows a redirect
  # (a metadata document or a token answer from wherever a 3xx points is
  # not the one the client asked for), and every one goes over HTTPS, or
  # plain HTTP to a loopback host only.

  @loopback ["localhost", "127.0.0.1", "::1"]

  @spec secure?(term()) :: boolean()
  def secure?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, fragment: nil} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host, fragment: nil} when host in @loopback -> true
      _ -> false
    end
  end

  def secure?(_url), do: false

  @doc "GETs a JSON object; `{:error, :not_found}` for any answer but a 200 with one."
  @spec get_json(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_json(url, req) do
    with :ok <- check(url) do
      case Req.get(url, options([], req)) do
        {:ok, %Req.Response{status: 200, body: body}} -> object(body)
        {:ok, %Req.Response{}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  POSTs `body` (`json:` or `form:`) and decodes the JSON answer, whatever
  its status. The answer's headers come back too (a DPoP nonce travels
  in one), with lowercase names.
  """
  @spec post(String.t(), keyword(), [{String.t(), String.t()}], keyword()) ::
          {:ok, pos_integer(), map() | binary(), %{String.t() => [String.t()]}}
          | {:error, term()}
  def post(url, body, headers, req) do
    with :ok <- check(url) do
      case Req.post(url, body ++ options(headers, req)) do
        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:ok, status, decoded(body), headers}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp check(url), do: if(secure?(url), do: :ok, else: {:error, {:insecure_url, url}})

  defp options(headers, req) do
    [
      headers: [{"accept", "application/json"} | headers],
      redirect: false,
      retry: false,
      decode_body: false
    ] ++ req
  end

  defp object(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :not_found}
    end
  end

  defp object(_body), do: {:error, :not_found}

  defp decoded(body) do
    case object(body) do
      {:ok, map} -> map
      {:error, :not_found} -> body
    end
  end
end
