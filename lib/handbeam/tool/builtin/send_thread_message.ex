defmodule Handbeam.Tool.Builtin.SendThreadMessage do
  use Handbeam.Tool.ThreadTool,
    name: "send_thread_message",
    module: Handbeam.Threads.Collaboration,
    action: :send_message,
    description:
      "Send a task or result to an authorized thread. A parent may message its children. A child may message its parent or a sibling under the same parent. Omit handoff_id for a new task; pass an existing receipt/read_thread handoff_id to continue that exchange with the same peer. Defaults to steer so a running recipient sees it before the next provider step; pass deliver_as follow_up only to wait until that run ends. An idle recipient is woken with a new run. Reuse request_id on retry; do not retry delivery_unknown with a new ID. Do not send an empty acknowledgment.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["thread", "message", "request_id"],
      properties: %{
        thread: %{type: "string"},
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        handoff_id: %{type: "string", maxLength: 128},
        deliver_as: %{type: "string", enum: ["follow_up", "steer"]}
      }
    }
end
