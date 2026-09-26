defmodule Handbeam.MCP.ServerConfig do
  @moduledoc """
  Normalized configuration for a single MCP server.

  Holds raw configuration fields and the runtime-resolved environment.
  """
  defstruct [
    :name,
    :command,
    args: [],
    env: %{},
    runtime_env: %{},
    disabled: false,
    cwd: nil,
    transport: "stdio",
    type: nil,
    url: nil,
    headers: %{},
    runtime_headers: %{},
    source: nil,
    raw: %{}
  ]

  @type t :: %__MODULE__{
          name: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          env: %{String.t() => String.t()},
          runtime_env: %{String.t() => String.t()},
          disabled: boolean(),
          cwd: String.t() | nil,
          transport: String.t(),
          type: String.t() | nil,
          url: String.t() | nil,
          headers: %{String.t() => String.t()},
          runtime_headers: %{String.t() => String.t()},
          source: String.t() | nil,
          raw: map()
        }
end
