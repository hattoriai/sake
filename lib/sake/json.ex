defmodule Sake.JSON do
  @moduledoc false
  # The JSON encoder for the host's data: tool results and
  # `structuredContent`, resource and prompt payloads, elicitation
  # requests, notifications, and every message Sake writes to a transport
  # (HTTP, SSE, stdio, `Sake.Test`, the client's requests). It is
  # `config :sake, :json_library, JSON` (the default) or `Jason`, or any
  # module with `encode!/1` and `encode_to_iodata!/1`, the way Phoenix
  # takes `:json_library`: Elixir's `JSON` encodes only structs that
  # implement `JSON.Encoder`, and a Phoenix application's structs often
  # derive `Jason.Encoder` instead.
  #
  # Only encoding goes through here. Sake decodes with `JSON` always:
  # both libraries give the same terms (string keys, integers and floats
  # alike), so a choice there would buy the host nothing, and one fixed
  # parser for what peers send keeps the behaviour on duplicate keys,
  # large numbers and invalid UTF-8 the same in every host. For the same
  # reason the protocol and crypto paths stay on `JSON` for encoding too:
  # JWS headers and claims, the RFC 7638 thumbprint (which must be exact
  # canonical JSON), the OAuth documents and responses Sake builds, and
  # the credentials the client stores. They hold only Sake's own data,
  # and their bytes must not change with the host's choice.
  #
  # The library is read from the application environment once, checked,
  # and kept in a persistent term: when `Sake` starts, or else on first
  # use (a server under `Sake.Plug` or `Sake.Stdio` alone). Reading it at
  # runtime rather than with `compile_env` means changing it does not
  # recompile Sake.

  @key {__MODULE__, :library}

  @doc "Encodes `term` to a binary with the configured library."
  @spec encode!(term()) :: String.t()
  def encode!(term) do
    library().encode!(term)
  rescue
    error in Protocol.UndefinedError -> reraise hint(error), __STACKTRACE__
  end

  @doc "Encodes `term` to iodata with the configured library."
  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term) do
    library().encode_to_iodata!(term)
  rescue
    error in Protocol.UndefinedError -> reraise hint(error), __STACKTRACE__
  end

  @doc "The configured library."
  @spec library() :: module()
  def library do
    case :persistent_term.get(@key, nil) do
      nil -> configure!()
      library -> library
    end
  end

  @doc """
  Reads `config :sake, :json_library`, checks it and keeps it; raises
  `ArgumentError` for a module that is not there or lacks a function Sake
  calls.
  """
  @spec configure!() :: module()
  def configure! do
    library = Application.get_env(:sake, :json_library, JSON)

    unless is_atom(library) and Code.ensure_loaded?(library) and
             function_exported?(library, :encode!, 1) and
             function_exported?(library, :encode_to_iodata!, 1) do
      raise ArgumentError,
            "config :sake, :json_library must be a module with encode!/1 and encode_to_iodata!/1 " <>
              "(JSON or Jason), got: #{inspect(library)}"
    end

    :persistent_term.put(@key, library)
    library
  end

  # A struct the library cannot encode is most often one that implements
  # the other library's protocol (an Ecto schema with `@derive
  # Jason.Encoder`), so the error says which library Sake used and where
  # that is set.
  defp hint(%Protocol.UndefinedError{protocol: protocol} = error)
       when protocol in [JSON.Encoder, Jason.Encoder] do
    hint =
      "Sake encoded it with #{inspect(library())}, set by config :sake, :json_library " <>
        "(JSON or Jason, for a struct that derives Jason.Encoder)"

    description =
      if error.description in [nil, ""], do: hint, else: hint <> ". " <> error.description

    %{error | description: description}
  end

  defp hint(error), do: error
end
