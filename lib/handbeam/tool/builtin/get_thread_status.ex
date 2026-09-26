defmodule Handbeam.Tool.Builtin.GetThreadStatus do
  use Handbeam.Tool.ThreadTool,
    name: "get_thread_status",
    module: Handbeam.Threads,
    action: :status,
    description:
      "Read a durable thread's runtime status, including historical threads without a Session. Idle does not mean success.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["thread"],
      properties: %{
        thread: %{
          type: "string",
          description: "Conversation id in the same workspace. Not a title."
        }
      }
    }
end
