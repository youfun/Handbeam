defmodule Handbeam.Extension.ToolSpec do
  @moduledoc """
  Extension-declared tool data structure.

  Namespaced handbeam_name: `ext__<extension>__<tool>`.
  Does NOT register into Handbeam.Tool.Registry.
  """

  alias Handbeam.Extension.Manifest
  alias Handbeam.Extension.Diagnostic

  defstruct [
    :extension,
    :name,
    :handbeam_name,
    :description,
    input_schema: %{},
    permissions: %{}
  ]

  @type t :: %__MODULE__{
          extension: String.t(),
          name: String.t(),
          handbeam_name: String.t(),
          description: String.t() | nil,
          input_schema: map(),
          permissions: map()
        }

  @valid_tool_name_re ~r/\A[a-z][a-z0-9_]*\z/

  @builtin_tool_names ~w(read edit write bash mem_learn mem_recall mem_reinforce mem_associate)

  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(extension, tool_name, opts \\ %{}) do
    with :ok <- Manifest.validate_name(extension),
         :ok <- validate_name(tool_name) do
      handbeam_name = "ext__#{extension}__#{tool_name}"

      spec = %__MODULE__{
        extension: extension,
        name: tool_name,
        handbeam_name: handbeam_name,
        description: Map.get(opts, :description) || Map.get(opts, "description"),
        input_schema: Map.get(opts, :input_schema) || Map.get(opts, "input_schema") || %{},
        permissions: Map.get(opts, :permissions) || Map.get(opts, "permissions") || %{}
      }

      {:ok, spec}
    end
  end

  @spec to_provider_tool_def(t()) :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map()
        }
  def to_provider_tool_def(%__MODULE__{} = spec) do
    %{
      name: spec.handbeam_name,
      description: spec.description,
      input_schema: spec.input_schema
    }
  end

  @spec check_builtin_collision(t()) :: :ok | {:collision, String.t()}
  def check_builtin_collision(%__MODULE__{name: name}) do
    if name in @builtin_tool_names do
      {:collision, name}
    else
      :ok
    end
  end

  @spec validate_name(String.t() | nil) :: :ok | {:error, Diagnostic.t()}
  def validate_name(nil) do
    {:error, %Diagnostic{type: :validation_error, message: "tool name must not be nil"}}
  end

  def validate_name(name) when is_binary(name) do
    if String.match?(name, @valid_tool_name_re) do
      :ok
    else
      {:error,
       %Diagnostic{
         type: :validation_error,
         message:
           "invalid tool name: #{inspect(name)}. " <>
             "Name must start with a lowercase letter and contain only lowercase letters, numbers, and underscores."
       }}
    end
  end

  def validate_name(name) do
    {:error,
     %Diagnostic{
       type: :validation_error,
       message: "tool name must be a string, got: #{inspect(name)}"
     }}
  end
end
