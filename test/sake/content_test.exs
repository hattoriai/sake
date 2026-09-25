defmodule Sake.ContentTest do
  use ExUnit.Case, async: true

  alias Sake.Content

  test "text, image, audio, resource link, embedded resource to wire" do
    assert Content.to_wire(Content.text("hi")) == %{"type" => "text", "text" => "hi"}

    assert Content.to_wire(Content.image(<<1, 2>>, "image/png")) ==
             %{"type" => "image", "data" => Base.encode64(<<1, 2>>), "mimeType" => "image/png"}

    assert Content.to_wire(Content.audio(<<3>>, "audio/wav")) ==
             %{"type" => "audio", "data" => Base.encode64(<<3>>), "mimeType" => "audio/wav"}

    assert Content.to_wire(
             Content.resource_link("issue://1", name: "issue 1", mime_type: "application/json")
           ) ==
             %{
               "type" => "resource_link",
               "uri" => "issue://1",
               "name" => "issue 1",
               "mimeType" => "application/json"
             }

    assert Content.to_wire(Content.resource("issue://1", "{}", mime_type: "application/json")) ==
             %{
               "type" => "resource",
               "resource" => %{
                 "uri" => "issue://1",
                 "text" => "{}",
                 "mimeType" => "application/json"
               }
             }

    assert Content.to_wire(
             Content.resource("f://b", {:blob, <<9>>}, mime_type: "application/octet-stream")
           ) ==
             %{
               "type" => "resource",
               "resource" => %{
                 "uri" => "f://b",
                 "blob" => Base.encode64(<<9>>),
                 "mimeType" => "application/octet-stream"
               }
             }
  end

  test "annotations and meta are optional and pass through" do
    wire =
      Content.to_wire(
        Content.text("x", annotations: %{audience: [:user], priority: 0.5}, meta: %{"k" => 1})
      )

    assert wire["annotations"] == %{"audience" => ["user"], "priority" => 0.5}
    assert wire["_meta"] == %{"k" => 1}
  end

  test "from wire round-trips" do
    for c <- [
          Content.text("a"),
          Content.image(<<1>>, "image/png"),
          Content.resource_link("u://1"),
          Content.resource("u://1", "t")
        ] do
      assert c |> Content.to_wire() |> Content.from_wire() == c
    end

    assert Content.from_wire(%{"type" => "weird"}) == {:error, :unknown_content}
  end

  test "from_wire handles malformed data gracefully" do
    assert Content.from_wire(%{"type" => "image", "data" => "***", "mimeType" => "image/png"}) ==
             {:error, :unknown_content}

    assert Content.from_wire(%{
             "type" => "resource",
             "resource" => %{"uri" => "u://1", "blob" => "***"}
           }) == {:error, :unknown_content}
  end

  test "annotations with unknown audience values pass through as strings" do
    c =
      Content.from_wire(%{
        "type" => "text",
        "text" => "x",
        "annotations" => %{"audience" => ["user", "robot"]}
      })

    assert c.annotations == %{audience: [:user, "robot"]}
  end

  test "empty annotations are not wired" do
    refute Map.has_key?(Content.to_wire(Content.text("x", annotations: %{})), "annotations")
  end
end
