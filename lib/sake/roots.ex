defmodule Sake.Roots do
  @moduledoc """
  Asks the client for its roots — the directories or other locations it
  lets the server work in (`roots/list`).

      case Sake.Roots.list(ctx) do
        {:ok, roots} -> {:ok, Enum.map_join(roots, "\\n", & &1.uri)}
        {:error, :unsupported} -> {:error, "This tool needs a client that shares its roots."}
        {:error, _reason} -> {:error, "The client did not list its roots."}
      end

  Roots are deprecated in the 2026-07-28 revision (SEP-2577) but still
  part of it, and many clients still use them; Sake supports them on every
  revision. The call travels exactly like a `Sake.Elicit` call (see
  there), keyed by `key`.

  Returns `{:ok, [%{uri: uri, name: name}]}` (`name` may be `nil`),
  `{:error, :unsupported}` when the client did not declare `roots`, or the
  same errors as `Sake.Sampling.create_message/4`.
  """

  alias Sake.Context
  alias Sake.Server.Ask

  @type root :: %{uri: String.t(), name: String.t() | nil}

  @spec list(Context.t(), atom() | String.t()) ::
          {:ok, [root()]}
          | {:error, :unsupported | :cancelled | :timeout | :invalid_response | map()}
  def list(ctx, key \\ :roots) do
    case Ask.request(ctx, "roots", to_string(key), "roots/list", %{}) do
      {:ok, %{"roots" => roots}} when is_list(roots) -> {:ok, Enum.flat_map(roots, &root/1)}
      {:ok, _other} -> {:error, :invalid_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp root(%{"uri" => uri} = root) when is_binary(uri), do: [%{uri: uri, name: root["name"]}]
  defp root(_), do: []
end
