defmodule Sake.Auth.Challenge do
  @moduledoc """
  An authorization challenge: what a `WWW-Authenticate` header says, on
  either side of a request.

  A client reads it from a response with `parse/1` (`Sake.Client` hands
  it back in `{:error, {:unauthorized, challenge}}` and
  `{:error, {:insufficient_scope, challenge}}`): the `scheme`, the
  `resource_metadata` URL (RFC 9728), the `error`, its
  `error_description`, the `realm` and the `scope`. `nonce` is the
  response's `DPoP-Nonce` header (RFC 9449 §9), which a `use_dpop_nonce`
  error asks the next proof to carry.

  A resource refuses a request with one: `status` is the HTTP status
  (401, or 403 for `insufficient_scope`), `www_authenticate` the header
  values to send, in order, and `nonce` the `DPoP-Nonce` to send with
  them, if any. `Sake.Plug` turns it into the response.
  """
  @type t :: %__MODULE__{
          scheme: String.t() | nil,
          resource_metadata: String.t() | nil,
          error: String.t() | nil,
          error_description: String.t() | nil,
          realm: String.t() | nil,
          nonce: String.t() | nil,
          scope: [String.t()],
          status: 401 | 403 | nil,
          www_authenticate: [String.t()]
        }
  defstruct [
    :scheme,
    :resource_metadata,
    :error,
    :error_description,
    :realm,
    :nonce,
    :status,
    scope: [],
    www_authenticate: []
  ]

  @spec parse(String.t()) :: t()
  def parse(header) do
    {scheme, rest} =
      case String.split(String.trim(header), " ", parts: 2) do
        [scheme] -> {scheme, ""}
        [scheme, rest] -> {scheme, rest}
      end

    params =
      ~r/(\w+)="([^"]*)"|(\w+)=([^,\s]+)/
      |> Regex.scan(rest)
      |> Map.new(fn
        [_, k, v] -> {k, v}
        [_, "", "", k, v] -> {k, v}
      end)

    %__MODULE__{
      scheme: scheme,
      resource_metadata: params["resource_metadata"],
      error: params["error"],
      error_description: params["error_description"],
      realm: params["realm"],
      scope: params |> Map.get("scope", "") |> String.split(" ", trim: true)
    }
  end
end
