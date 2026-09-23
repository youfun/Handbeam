defmodule Handbeam.MCP.Config do
  @moduledoc """
  Top-level result of MCP configuration loading.

  Contains merged and validated server configs plus diagnostics.
  """
  defstruct servers: %{}, diagnostics: []

  @type t :: %__MODULE__{
          servers: %{String.t() => Handbeam.MCP.ServerConfig.t()},
          diagnostics: [Handbeam.MCP.Diagnostic.t()]
        }
end
