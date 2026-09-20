defmodule Handbeam.Tool.Builtin.FindThread do
  use Handbeam.Tool.ThreadTool,
    name: "find_thread",
    module: Handbeam.Threads,
    action: :find,
    description:
      "Find durable threads in your workspace by title/update time, excluding internal tasks. Summary is title-only. Cursors expire on snapshot changes; restart the query.",
    schema: %{
      type: "object",
      additionalProperties: false,
      properties: %{
        query: %{type: "string", maxLength: 200},
        updated_after: %{type: "string"},
        include_archived: %{type: "boolean"},
        limit: %{type: "integer", minimum: 1, maximum: 20},
        cursor: %{type: "string"}
      }
    }
end
