defmodule Handbeam.Tool.Builtin.CreateThread do
  @moduledoc "Create a persistent delegated thread in the current workspace."

  use Handbeam.Tool.ThreadTool,
    name: "create_thread",
    module: Handbeam.Threads.Collaboration,
    action: :create,
    description:
      "Delegate a persistent task in this workspace. Shared directory is NOT an isolated checkout. mode read_only (default) can only read; mode write may edit this workspace. Write does not raise a separate approval: approval defaults to auto_review (smart review) and may be yolo. yolo skips prompts for that child only and does not change workspace settings; sensitive-path denies still apply. Optional provider and model must be a workspace-allowed catalog pair; omit both to inherit this turn. A selected model resolves its own provider config. May incur provider charges. Reuse request_id on retry; a different mode, approval, or model under the same request_id conflicts.",
    schema: %{
      type: "object",
      additionalProperties: false,
      required: ["title", "message", "request_id"],
      properties: %{
        title: %{type: "string", maxLength: 200},
        message: %{type: "string", maxLength: 8000},
        request_id: %{type: "string", maxLength: 128},
        provider: %{
          type: "string",
          maxLength: 128,
          description: "Catalog provider id. Required together with model. Omit both to inherit."
        },
        model: %{
          type: "string",
          maxLength: 128,
          description: "Catalog model id for that provider, not a provider/model composite."
        },
        mode: %{
          type: "string",
          enum: ["read_only", "write"],
          description: "read_only (default) or write. write edits the shared workspace."
        },
        approval: %{
          type: "string",
          enum: ["auto_review", "yolo"],
          description:
            "Write threads only. Default auto_review. yolo skips prompts except built-in sensitive-path denies."
        }
      }
    }
end
