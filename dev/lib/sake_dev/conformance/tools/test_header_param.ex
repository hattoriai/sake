defmodule SakeDev.Conformance.Tools.TestHeaderParam do
  @moduledoc false
  # http-custom-header-server-validation: a string argument mirrored into
  # the `Mcp-Param-Region` header, for the suite to send valid, invalid and
  # missing header values against.
  use Sake.Tool,
    name: "test_header_param",
    description: "Echoes a region that travels in the Mcp-Param-Region header too"

  arg :region, :string, header: "Region"

  @impl true
  def execute(%{region: region}, _ctx), do: {:ok, "Region: #{region}"}
end
