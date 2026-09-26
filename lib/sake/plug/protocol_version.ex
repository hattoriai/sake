defmodule Sake.Plug.ProtocolVersion do
  @moduledoc false

  alias Sake.Protocol

  @doc "What the `MCP-Protocol-Version` header says: modern, legacy (with the named revision or nil when absent), or unsupported."
  @spec detect(Plug.Conn.t()) ::
          {:modern, String.t()} | {:legacy, String.t() | nil} | {:unsupported, String.t()}
  def detect(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
      [] ->
        {:legacy, nil}

      [v | _] ->
        case Protocol.era(v) do
          :modern -> {:modern, v}
          :legacy -> {:legacy, v}
          :unknown -> {:unsupported, v}
        end
    end
  end
end
