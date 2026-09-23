defmodule Handbeam.Agent.Tool do
  @moduledoc """
  Behaviour for tools that agents can call.

  ## Required Callbacks

  Every tool must implement `name/0`, `description/0`, `input_schema/0`,
  and `execute/2`.

  ## Optional Callbacks

  - `max_result_chars/0` — max output length before truncation (default: unlimited)
  - `concurrent?/0` — can this tool run in parallel? (default: true)
  """

  @doc "Unique tool name (used in API calls)."
  @callback name() :: String.t()

  @doc "Human-readable description of what the tool does."
  @callback description() :: String.t()

  @doc "JSON Schema defining the tool's input parameters."
  @callback input_schema() :: map()

  @doc """
  Execute the tool with the given input and context.

  Context is a map that may contain:
  - `:working_directory` - base path for file operations
  - `:session_id` - current session identifier
  - any custom keys added by middleware

  Returns `{:ok, String.t()}` or `{:ok, String.t(), map()}` on success,
  `{:error, String.t()}` or `{:error, String.t(), map()}` on failure.
  """
  @callback execute(input :: map(), context :: map()) ::
              {:ok, String.t()}
              | {:ok, String.t(), map()}
              | {:error, String.t()}
              | {:error, String.t(), map()}

  @callback max_result_chars() :: pos_integer() | :unlimited
  @callback concurrent?() :: boolean()

  @optional_callbacks [max_result_chars: 0, concurrent?: 0]

  @doc """
  Resolve a file path against the working directory from context.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec resolve_path(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(file_path, context) do
    working_directory = Map.get(context, :working_directory)

    resolved =
      if Path.type(file_path) == :absolute do
        Path.expand(file_path)
      else
        case working_directory do
          nil -> Path.expand(file_path)
          wd -> Path.expand(Path.join(wd, file_path))
        end
      end

    case working_directory do
      nil ->
        {:ok, resolved}

      wd ->
        case Handbeam.Security.PathValidator.validate_within_workspace(resolved, wd) do
          :ok -> {:ok, resolved}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
