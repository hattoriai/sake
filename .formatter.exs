locals_without_parens = [arg: 2, arg: 3, scope: 2, tools: 1, resources: 1, prompts: 1, output: 1]

[
  import_deps: [:plug],
  locals_without_parens: locals_without_parens,
  inputs: ["{mix,.formatter,dev}.exs", "{config,lib,test,dev}/**/*.{ex,exs}"],
  export: [locals_without_parens: locals_without_parens]
]
