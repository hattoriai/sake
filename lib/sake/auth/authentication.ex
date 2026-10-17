defmodule Sake.Auth.Authentication do
  @moduledoc false
  # How and when the person behind a grant signed in (RFC 9470): the
  # authentication context class (`acr`) and the time of the sign-in
  # (`auth_time`), and the requirements on them.
  #
  # The context comes from the host (`c:Sake.Auth.Subject.authentication/1`)
  # when the person approves a request, rides on the code or the device
  # grant into the tokens, and is kept by a refresh, which is no new
  # sign-in. An external server's token carries it in its `acr` and
  # `auth_time` claims.
  #
  # A requirement is `%{acr_values: [acr], max_age: seconds | nil}`: the
  # `acr` must be one of `acr_values` (none listed, any `acr` will do, a
  # missing one too), and the sign-in no older than `max_age` seconds
  # (nil, any sign-in, a missing `auth_time` too). The same shape serves
  # both ends: an authorization request's `acr_values` and `max_age`
  # (kept in its `extra`), and what a tool, resource, prompt or server
  # declares with `authentication: [acr: [...], max_age: seconds]`.
  #
  # `max_age: 0` (OpenID Connect's "sign in again now") cannot be met to
  # the second: the person signs in, comes back, and the token is used,
  # all some seconds later. It means a sign-in within the last 60
  # seconds instead.
  #
  # Core: plain data in and out; it never sees the conn.

  @typedoc "How and when the person signed in; either may be unknown."
  @type context :: %{acr: String.t() | nil, auth_time: DateTime.t() | nil}

  @typedoc "What a request or a component asks of the sign-in."
  @type requirement :: %{acr_values: [String.t()], max_age: non_neg_integer() | nil}

  # What `max_age: 0` takes as a fresh sign-in, in seconds.
  @fresh 60

  @doc "The context when nothing is known."
  @spec none() :: context()
  def none, do: %{acr: nil, auth_time: nil}

  @doc """
  A context as a host or a record gives it, normalized: an `acr` that is
  not a non-empty string and an `auth_time` that is not a `DateTime` (or
  Unix seconds) count as unknown.
  """
  @spec context(term()) :: context()
  def context(%{} = context) do
    %{
      acr: acr(Map.get(context, :acr)),
      auth_time: auth_time(Map.get(context, :auth_time))
    }
  end

  def context(_other), do: none()

  defp acr(acr) when is_binary(acr) and acr != "", do: acr
  defp acr(_acr), do: nil

  defp auth_time(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp auth_time(at) when is_integer(at), do: DateTime.from_unix!(at)
  defp auth_time(_at), do: nil

  @doc """
  The requirement an authorization request's `extra` carries
  (`"acr_values"`, `"max_age"`), or nil when it asks for nothing.
  """
  @spec requested(map() | nil) :: requirement() | nil
  def requested(extra) when is_map(extra) do
    case {Map.get(extra, "acr_values", []), Map.get(extra, "max_age")} do
      {[], nil} -> nil
      {acr_values, max_age} -> %{acr_values: acr_values, max_age: max_age}
    end
  end

  def requested(_extra), do: nil

  @doc """
  The `acr_values` and `max_age` parameters of an authorization request,
  validated, as the entries of its `extra`. `acr_values` is a
  space-separated list; with `supported` (the `acr_values:` of the auth
  config), the values it does not list are dropped, and a request left
  with none of the values it named is refused: the server could only
  issue a token that does not do what the client asked for. `max_age` is
  a non-negative integer, in seconds.
  """
  @spec params(map(), [String.t()] | nil) :: {:ok, map()} | {:error, String.t(), String.t()}
  def params(p, supported) do
    with {:ok, acr_values} <- acr_values(p["acr_values"], supported),
         {:ok, max_age} <- max_age(p["max_age"]) do
      {:ok,
       %{}
       |> then(&if(acr_values == [], do: &1, else: Map.put(&1, "acr_values", acr_values)))
       |> then(&if(max_age == nil, do: &1, else: Map.put(&1, "max_age", max_age)))}
    end
  end

  defp acr_values(nil, _supported), do: {:ok, []}

  defp acr_values(value, supported) when is_binary(value) do
    requested = value |> String.split(" ", trim: true) |> Enum.uniq()
    kept = if supported, do: Enum.filter(requested, &(&1 in supported)), else: requested

    if kept == [] and requested != [],
      do:
        {:error, "invalid_request",
         "None of the acr_values is supported: #{Enum.join(requested, " ")}"},
      else: {:ok, kept}
  end

  defp acr_values(_value, _supported),
    do: {:error, "invalid_request", "acr_values must be a space-separated string"}

  defp max_age(nil), do: {:ok, nil}
  defp max_age(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp max_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> bad_max_age()
    end
  end

  defp max_age(_value), do: bad_max_age()

  defp bad_max_age, do: {:error, "invalid_request", "max_age must be a non-negative integer"}

  @doc """
  Whether `context` meets `requirement` at `now`: `:ok`, or
  `{:error, :acr}` when the `acr` is not one asked for (or unknown), and
  `{:error, :max_age}` when the sign-in is too old (or its time
  unknown). A nil requirement asks for nothing.
  """
  @spec check(context(), requirement() | nil, DateTime.t()) :: :ok | {:error, :acr | :max_age}
  def check(context, requirement, now \\ DateTime.utc_now())
  def check(_context, nil, _now), do: :ok

  def check(context, requirement, now) do
    cond do
      requirement.acr_values != [] and context.acr not in requirement.acr_values ->
        {:error, :acr}

      requirement.max_age != nil and not recent?(context.auth_time, requirement.max_age, now) ->
        {:error, :max_age}

      true ->
        :ok
    end
  end

  defp recent?(nil, _max_age, _now), do: false

  defp recent?(auth_time, max_age, now),
    do: DateTime.diff(now, auth_time) <= if(max_age == 0, do: @fresh, else: max_age)

  @doc """
  A requirement as a component or a server declares it:
  `[acr: "mfa" | ["mfa", ...], max_age: seconds]`, either one optional.
  nil for none. Raises (`ArgumentError`, naming `where`) for anything else.
  """
  @spec requirement!(term(), String.t()) :: requirement() | nil
  def requirement!(nil, _where), do: nil
  def requirement!([], _where), do: nil

  def requirement!(opts, where) when is_list(opts) do
    acr = opts |> Keyword.get(:acr, []) |> List.wrap()
    max_age = Keyword.get(opts, :max_age)

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:acr, :max_age] == [] and
             Enum.all?(acr, &(is_binary(&1) and &1 != "")) and
             (max_age == nil or (is_integer(max_age) and max_age >= 0)),
           do: bad_requirement!(opts, where)

    %{acr_values: Enum.uniq(acr), max_age: max_age}
  end

  def requirement!(opts, where), do: bad_requirement!(opts, where)

  defp bad_requirement!(opts, where) do
    raise ArgumentError,
          "#{where}: authentication: takes [acr: [String.t()], max_age: non-negative seconds], " <>
            "got #{inspect(opts)}"
  end

  @doc """
  Two requirements that must both be met, as one: the `acr` among both
  lists, and the shorter `max_age`. When the lists have no `acr` in
  common, `inner`'s is kept (the more specific declaration); `merge!/3`
  refuses that at compile time.
  """
  @spec merge(requirement() | nil, requirement() | nil) :: requirement() | nil
  def merge(nil, outer), do: outer
  def merge(inner, nil), do: inner

  def merge(inner, outer) do
    %{
      acr_values: acr_values_of(inner.acr_values, outer.acr_values),
      max_age: min_age(inner.max_age, outer.max_age)
    }
  end

  defp acr_values_of([], outer), do: outer
  defp acr_values_of(inner, []), do: inner

  defp acr_values_of(inner, outer) do
    case Enum.filter(inner, &(&1 in outer)) do
      [] -> inner
      both -> both
    end
  end

  defp min_age(nil, b), do: b
  defp min_age(a, nil), do: a
  defp min_age(a, b), do: min(a, b)

  @doc "As `merge/2`, raising (`ArgumentError`, naming `where`) when no `acr` meets both."
  @spec merge!(requirement() | nil, requirement() | nil, String.t()) :: requirement() | nil
  def merge!(inner, outer, where) do
    if inner && outer && inner.acr_values != [] && outer.acr_values != [] &&
         not Enum.any?(inner.acr_values, &(&1 in outer.acr_values)),
       do:
         raise(
           ArgumentError,
           "#{where}: authentication: acr #{inspect(inner.acr_values)} has none of " <>
             "the server's #{inspect(outer.acr_values)}"
         )

    merge(inner, outer)
  end
end
