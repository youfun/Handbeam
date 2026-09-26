defmodule Handbeam.ProjectTrust do
  @moduledoc """
  Controls whether project-local configuration may execute code.

  User-level extensions and MCP configuration remain available. Project-local
  `.handbeam/extensions`, `.mcp.json`, and `.handbeam/mcp.json` are disabled by
  default and require an explicit opt-in.
  """

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get_lazy(opts, :trusted_project?, fn ->
      Application.get_env(:handbeam, :trust_project_code, false)
    end) == true
  end
end
