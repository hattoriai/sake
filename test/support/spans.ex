defmodule SakeTest.Spans do
  @moduledoc false
  # The OpenTelemetry spans of a test. The SDK runs for the whole suite
  # (config/test.exs) but samples a new trace only while a test captures,
  # and exports to this module, which hands each span to the capturing
  # test as `{:span, span}`. Tests that capture are `async: false`, so at
  # most one captures at a time, and the rest of the suite records nothing.

  @behaviour :otel_exporter_traces

  require Record

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :link,
    Record.extract(:link, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @to {__MODULE__, :to}

  @doc "Sends the spans of every trace sampled from now to the end of the test to it."
  def capture do
    send_to(self())
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase(@to) end)
  end

  @doc "Sends every span from now on to `pid` (outside a test: a stdio server's script)."
  def send_to(pid) do
    :persistent_term.put(@to, pid)
    :ok
  end

  @doc "Whether a test captures."
  def capturing?, do: :persistent_term.get(@to, nil) != nil

  @doc """
  Waits for the spans named `names` (all of them, in any order) and
  returns them by name; a name that appears more than once is a list.
  """
  def await(names, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(names, %{}, deadline)
  end

  defp collect([], acc, _deadline), do: acc

  defp collect(names, acc, deadline) do
    receive do
      {:span, span} ->
        if span.name in names do
          collect(List.delete(names, span.name), put(acc, span), deadline)
        else
          collect(names, acc, deadline)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise ExUnit.AssertionError,
          message: "spans not seen: #{inspect(names)}, seen: #{inspect(Map.keys(acc))}"
    end
  end

  defp put(acc, span) do
    Map.update(acc, span.name, span, fn
      list when is_list(list) -> list ++ [span]
      first -> [first, span]
    end)
  end

  @doc "No span ends within `timeout`."
  def refute_spans(timeout \\ 200) do
    receive do
      {:span, span} -> raise ExUnit.AssertionError, message: "unexpected span #{span.name}"
    after
      timeout -> :ok
    end
  end

  @doc "A test's own span around `fun`, the root of the trace; returns `{result, span_ctx}`."
  def root(name, fun) do
    tracer = :opentelemetry.get_tracer(:sake_test)

    :otel_tracer.with_span(tracer, name, %{}, fn span_ctx ->
      {fun.(), span_ctx}
    end)
  end

  @doc "The `traceparent` of a span context, as a client would send it."
  def traceparent(span_ctx) do
    [{"traceparent", value} | _] =
      :otel_propagator_text_map.inject_from(
        :otel_tracer.set_current_span(:otel_ctx.new(), span_ctx),
        :otel_propagator_trace_context,
        []
      )

    value
  end

  @doc "A random, sampled span context that came from elsewhere."
  def remote do
    trace_id = :rand.uniform(2 ** 128 - 1)
    span_id = :rand.uniform(2 ** 64 - 1)
    :otel_tracer.from_remote_span(trace_id, span_id, 1)
  end

  def trace_id(span_ctx), do: :otel_span.trace_id(span_ctx)
  def span_id(span_ctx), do: :otel_span.span_id(span_ctx)

  # ---- the exporter

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def export(spans, _resource, _config) do
    case :persistent_term.get(@to, nil) do
      nil -> :ok
      test -> :ets.foldl(fn span, _ -> send(test, {:span, to_map(span)}) end, nil, spans)
    end

    :ok
  end

  @impl true
  def shutdown(_config), do: :ok

  @doc "A span record as a map, attributes and links included."
  def to_map(record) do
    status =
      case span(record, :status) do
        status(code: code, message: message) -> {code, message}
        _ -> :unset
      end

    %{
      name: span(record, :name),
      kind: span(record, :kind),
      trace_id: span(record, :trace_id),
      span_id: span(record, :span_id),
      parent_span_id: span(record, :parent_span_id),
      attributes: :otel_attributes.map(span(record, :attributes)),
      links: Enum.map(:otel_links.list(span(record, :links)), &link_to_map/1),
      events: span(record, :events),
      status: status
    }
  end

  defp link_to_map(link(trace_id: trace_id, span_id: span_id)),
    do: %{trace_id: trace_id, span_id: span_id}

  defmodule Sampler do
    @moduledoc false
    # Samples a new trace only while a test captures; a child follows its
    # parent (the SDK's parent-based sampler, around this one).
    @behaviour :otel_sampler

    @impl true
    def setup(_opts), do: []

    @impl true
    def description(_config), do: "SakeTest.Spans.Sampler"

    @impl true
    def should_sample(_ctx, _trace_id, _links, _name, _kind, _attributes, _config) do
      if SakeTest.Spans.capturing?(),
        do: {:record_and_sample, [], []},
        else: {:drop, [], []}
    end
  end
end
