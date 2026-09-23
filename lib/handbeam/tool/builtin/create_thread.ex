defmodule Handbeam.Tool.Builtin.CreateThread do
  use Handbeam.Tool.ThreadTool,
    name: "create_thread",
    module: Handbeam.Threads.Collaboration,
    action: :create,
    description:
      "Delegate a bounded persistent task in this workspace. Read-only tools enforced at execution; shared directory is NOT an isolated checkout. At most 3 children, 3 turns and 2048 output tokens per request, 8 handoffs per root. Thread wakeup cannot be disabled. May incur provider charges. Reuse request_id on retry.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["title", "message", "request_id"],
      properties: %{
        title: %{type: "string", maxLength: 200},
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128}
      }
    }
end
