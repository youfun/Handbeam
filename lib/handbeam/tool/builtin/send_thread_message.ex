defmodule Handbeam.Tool.Builtin.SendThreadMessage do
  use Handbeam.Tool.ThreadTool,
    name: "send_thread_message",
    module: Handbeam.Threads.Collaboration,
    action: :send_message,
    description:
      "Send an asynchronous report to an authorized thread. Omit handoff_id for a new task; pass an existing receipt/read_thread handoff_id to continue that exchange with the same peer. Defaults to follow_up; steer must be explicit. Idle wakeups stay inside the bounded budget and cannot be disabled. Reuse request_id on retry; do not retry delivery_unknown with a new ID. No automatic acknowledgment loops.",
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
