defmodule Sake.Auth.BoundaryTest do
  # Calls run one way (#66): the rest of Sake calls authorization, and
  # nothing under lib/sake/auth* or lib/sake/client/auth* calls the rest
  # of Sake. Two views of the same rule: mix xref's graph of the files,
  # and every atom in the compiled code of those modules (remote calls,
  # structs, specs, persistent term keys, a module passed as a value),
  # which also catches a module that is only named.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @trees ["lib/sake/auth", "lib/sake/client/auth"]
  @namespaces ["Elixir.Sake.Auth", "Elixir.Sake.Client.Auth"]

  defp in_trees?(path),
    do: Enum.any?(@trees, &(path == &1 <> ".ex" or String.starts_with?(path, &1 <> "/")))

  defp inside?(module) do
    name = Atom.to_string(module)
    Enum.any?(@namespaces, &(name == &1 or String.starts_with?(name, &1 <> ".")))
  end

  defp sake?(module),
    do: module == Sake or String.starts_with?(Atom.to_string(module), "Elixir.Sake.")

  # The modules defined in the trees, with their source files.
  defp auth_modules do
    cwd = File.cwd!()

    for module <- Application.spec(:sake, :modules),
        path = Path.relative_to(List.to_string(module.module_info(:compile)[:source]), cwd),
        in_trees?(path),
        do: {module, path}
  end

  test "the auth modules reference no other Sake module" do
    modules = auth_modules()
    assert length(modules) > 40, "found only #{length(modules)} modules under #{inspect(@trees)}"

    violations =
      Enum.flat_map(modules, fn {module, path} ->
        misnamed =
          if inside?(module),
            do: [],
            else: ["#{inspect(module)} (#{path}) is outside the Sake.Auth namespaces"]

        calls = imports(module)

        edges =
          for target <- module |> atoms() |> Enum.sort(),
              sake?(target) and not inside?(target) do
            case for({^target, f, a} <- calls, do: "#{inspect(target)}.#{f}/#{a}") do
              [] -> "#{inspect(module)} (#{path}) -> #{inspect(target)}"
              mfas -> "#{inspect(module)} (#{path}) -> #{Enum.join(mfas, ", ")}"
            end
          end

        misnamed ++ edges
      end)

    assert violations == [],
           "authorization must not call the rest of Sake:\n  " <> Enum.join(violations, "\n  ")
  end

  test "mix xref finds no edge out of the auth files" do
    output =
      capture_io(fn -> Mix.Task.rerun("xref", ["graph", "--format", "plain", "--no-compile"]) end)

    edges = xref_edges(output)
    assert Enum.any?(edges, fn {from, _to} -> in_trees?(from) end), "xref listed no auth file"

    violations =
      for {from, to} <- edges, in_trees?(from), not in_trees?(to), do: "#{from} -> #{to}"

    assert violations == [],
           "authorization must not call the rest of Sake:\n  " <> Enum.join(violations, "\n  ")
  end

  # `mix xref graph --format plain`: each file on a line of its own, then
  # the files it depends on, each as `|-- path` or `` `-- path ``, with
  # the kind of the dependency (compile, export) after it.
  defp xref_edges(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce({nil, []}, fn line, {from, edges} ->
      case Regex.run(~r/^[|`]-- (\S+)/, line) do
        [_, to] -> {from, [{from, to} | edges]}
        nil -> {String.trim(line), edges}
      end
    end)
    |> elem(1)
  end

  defp imports(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports
  end

  # Every atom in the module's code, from its debug info as Erlang
  # abstract forms: the literals as well as the calls.
  defp atoms(module) do
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(module), [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    forms |> collect(MapSet.new()) |> MapSet.to_list()
  end

  defp collect({:atom, _anno, atom}, acc) when is_atom(atom), do: MapSet.put(acc, atom)
  defp collect(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> collect(acc)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_term, acc), do: acc
end
