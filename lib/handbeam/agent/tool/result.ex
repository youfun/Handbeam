defmodule Handbeam.Agent.Tool.Result do
  @moduledoc """
  Dual-channel tool result — separates LLM-facing content from UI rendering data.

  - `content` — concise text sent to the provider (LLM)
  - `details` — optional structured data for UI rendering / metadata
  - `is_error` — whether this result represents an error

  Ported from `Gong.ToolResult`.
  """

  @type t :: %__MODULE__{
          content: String.t(),
          details: map() | nil,
          is_error: boolean()
        }

  defstruct [:content, :details, is_error: false]

  @doc """
  Construct a full result with content, optional details, and error flag.
  """
  @spec new(String.t(), map() | nil, boolean()) :: t()
  def new(content, details \\ nil, is_error \\ false) do
    %__MODULE__{content: content, details: details, is_error: is_error}
  end

  @doc """
  Construct a result from a plain text string.

  Backward-compatible with tools that return only a string.
  """
  @spec from_text(String.t()) :: t()
  def from_text(text) when is_binary(text) do
    %__MODULE__{content: text, details: nil, is_error: false}
  end

  @doc """
  Construct an error result.
  """
  @spec error(String.t(), map() | nil) :: t()
  def error(content, details \\ nil) do
    %__MODULE__{content: content, details: details, is_error: true}
  end

  @doc """
  Get the LLM-facing content string.
  """
  @spec llm_content(t()) :: String.t()
  def llm_content(%__MODULE__{content: content}), do: content

  @doc """
  Get the UI/details metadata map.
  """
  @spec ui_details(t()) :: map() | nil
  def ui_details(%__MODULE__{details: details}), do: details

  @doc """
  Check if this is an error result.
  """
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{is_error: is_error}), do: is_error

  @doc """
  Check if this result has UI details (non-nil).
  """
  @spec has_details?(t()) :: boolean()
  def has_details?(%__MODULE__{details: nil}), do: false
  def has_details?(%__MODULE__{}), do: true
end
