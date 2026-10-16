defmodule Sake.Server.RequestState do
  @moduledoc false
  # The opaque, signed `requestState` of a multi round-trip request. It binds
  # the principal, the method, the component, a digest of the arguments,
  # the answers gathered so far, and a short expiry.

  @salt "sake.request_state"
  @max_age 600

  @spec sign(Sake.Context.t(), String.t(), map(), map()) :: String.t()
  def sign(ctx, name, args, inputs) do
    Plug.Crypto.sign(ctx.secret, @salt, %{
      p: principal(ctx),
      m: ctx.method,
      n: name,
      d: digest(args),
      i: inputs
    })
  end

  @spec verify(Sake.Context.t(), String.t(), map(), term()) :: {:ok, map()} | :error
  def verify(ctx, name, args, state) when is_binary(state) do
    with {:ok, %{p: p, m: m, n: n, d: d, i: inputs}} <-
           Plug.Crypto.verify(ctx.secret, @salt, state, max_age: @max_age),
         true <- p == principal(ctx) and m == ctx.method and n == name and d == digest(args) do
      {:ok, inputs}
    else
      _ -> :error
    end
  end

  def verify(_ctx, _name, _args, _state), do: :error

  # A token from an external authorization server is that issuer's: the
  # same `sub` from another issuer is someone else.
  defp principal(%{token: %{issuer: iss} = token} = ctx) when is_binary(iss),
    do: {:issuer, iss, principal(%{ctx | token: %{token | issuer: nil}})}

  defp principal(%{token: %{subject_id: id}}) when is_binary(id), do: id

  defp principal(%{token: %{subject_id: nil, client_id: id}}) when is_binary(id),
    do: {:client, id}

  defp principal(%{scope: nil}), do: nil
  defp principal(%{scope: scope}), do: :erlang.phash2(scope)

  defp digest(args),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(normalize(args))) |> Base.encode16()

  defp normalize(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), normalize(v)} end) |> Enum.sort()

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other
end
