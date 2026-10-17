defmodule Sake.Auth.Consent.Default do
  @moduledoc "The consent, code entry and error pages that ship with Sake."
  @behaviour Sake.Auth.Consent

  require EEx

  EEx.function_from_file(
    :def,
    :render,
    Path.join(:code.priv_dir(:sake), "templates/consent.html.eex"),
    [:assigns],
    engine: EEx.SmartEngine
  )

  EEx.function_from_file(
    :def,
    :render_error,
    Path.join(:code.priv_dir(:sake), "templates/error.html.eex"),
    [:assigns],
    engine: EEx.SmartEngine
  )

  EEx.function_from_file(
    :def,
    :render_user_code,
    Path.join(:code.priv_dir(:sake), "templates/user_code.html.eex"),
    [:assigns],
    engine: EEx.SmartEngine
  )
end
