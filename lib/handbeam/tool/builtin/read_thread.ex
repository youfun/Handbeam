defmodule Handbeam.Tool.Builtin.ReadThread do
  use Handbeam.Tool.ThreadTool,
    name: "read_thread",
    module: Handbeam.Threads,
    action: :read,
    description:
      "Read authorized transcript messages, with stable IDs and Unicode character offsets. Zero-based inclusive message range. Follow next_cursor with identical inputs to read long messages fully. Any snapshot change requires restarting.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["thread"],
      properties: %{
        thread: %{
          type: "string",
          description: "Conversation id in the same workspace. Not a title."
        },
        start_message: %{type: "integer", minimum: 0},
        end_message: %{type: "integer", minimum: 0},
        max_chars: %{type: "integer", minimum: 1, maximum: 16000},
        cursor: %{type: "string"}
      }
    }
end
