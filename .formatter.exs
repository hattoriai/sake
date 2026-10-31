locals_without_parens = [
  arg: 2,
  arg: 3,
  scope: 2,
  tools: 1,
  resources: 1,
  prompts: 1,
  skills: 1,
  middleware: 2,
  mount: 1,
  mount: 2,
  output: 1,
  # Sake.Test
  assert_notification: 1,
  assert_notification: 2,
  refute_notification: 1,
  refute_notification: 2,
  assert_asked: 1,
  assert_asked: 2,
  refute_asked: 1,
  refute_asked: 2,
  assert_list_changed: 1,
  refute_list_changed: 1,
  assert_resource_updated: 1,
  refute_resource_updated: 1
]

[
  import_deps: [:plug],
  locals_without_parens: locals_without_parens,
  inputs: ["{mix,.formatter,dev}.exs", "{config,lib,test,dev,bench}/**/*.{ex,exs}"],
  export: [locals_without_parens: locals_without_parens]
]
