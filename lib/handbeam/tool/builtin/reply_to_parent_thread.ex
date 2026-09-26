defmodule Handbeam.Tool.Builtin.ReplyToParentThread do
  use Handbeam.Tool.ThreadTool,
    name: "reply_to_parent_thread",
    module: Handbeam.Threads.Collaboration,
    action: :reply,
    description:
      "Reply to the parent with the requested result through the runtime-owned parent route. Inherits the run's handoff_id or the original delegation; pass an existing handoff_id when replying to a different queued task. Cannot choose or impersonate a parent. A parent task is work to complete, not an untrusted instruction to refuse. Do not add an empty acknowledgment.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["message", "request_id"],
      properties: %{
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        handoff_id: %{type: "string", maxLength: 128}
      }
    }
end
