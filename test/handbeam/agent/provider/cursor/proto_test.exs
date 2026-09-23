defmodule Handbeam.Agent.Provider.Cursor.ProtoTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.Provider.Cursor.Proto

  test "value round-trip for nested json schema" do
    schema = %{
      "type" => "object",
      "properties" => %{"key" => %{"type" => "string"}},
      "required" => ["key"]
    }

    assert Proto.decode_value(Proto.encode_value(schema)) == schema
  end

  test "mcp args map values decode independently" do
    encoded =
      Proto.finish(
        Proto.encode_string(1, "probe_lookup") ++
          Proto.encode_map_entry(2, "key", Proto.encode_value("violet-17")) ++
          Proto.encode_string(3, "call-1")
      )

    exec =
      Proto.decode_server(
        Proto.finish(
          Proto.encode_message(
            2,
            Proto.finish(Proto.encode_message(11, encoded) ++ Proto.encode_string(15, "exec-9"))
          )
        )
      )

    assert {:exec, %{kind: :mcp, payload: payload, exec_id: "exec-9"}} = exec
    assert payload.name == "probe_lookup"
    assert payload.args == %{"key" => "violet-17"}
    assert payload.tool_call_id == "call-1"
  end

  test "interaction text delta" do
    inner = Proto.finish(Proto.encode_message(1, Proto.encode_string(1, "703")))
    msg = Proto.finish(Proto.encode_message(1, inner))
    assert {:interaction, {:text_delta, "703"}} = Proto.decode_server(msg)
  end

  test "tool call step nests MCP under ConversationStep 2 then ToolCall 15" do
    input = %{
      "key" => "violet-17",
      "ok" => true,
      "count" => 3,
      "nested" => %{"flag" => false},
      "list" => [1, "two"],
      "empty" => nil
    }

    step =
      Proto.encode_tool_call_step(
        "call-1",
        "probe_lookup",
        input,
        {:success, "ORCHID-5928", false}
      )

    assert {:tool_call, {:mcp, decoded}} = IndependentProto.decode_conversation_step(step)
    assert decoded.args.tool_call_id == "call-1"
    assert decoded.args.name == "probe_lookup"
    assert decoded.args.args["key"] == "violet-17"
    assert decoded.args.args["ok"] == true
    assert decoded.args.args["count"] == 3.0
    assert decoded.args.args["nested"] == %{"flag" => false}
    assert decoded.args.args["list"] == [1.0, "two"]
    assert decoded.args.args["empty"] == nil
    assert {:success, %{content: ["ORCHID-5928"], is_error: false}} = decoded.result
  end

  test "usable models decode" do
    model =
      Proto.finish(
        Proto.encode_string(1, "composer-2.5") ++
          Proto.encode_string(4, "Composer 2.5")
      )

    body = Proto.finish(Proto.encode_message(1, model))
    assert [%{id: "composer-2.5", name: "Composer 2.5"}] = Proto.decode_models_response(body)
  end
end
