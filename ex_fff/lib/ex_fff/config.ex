defmodule ExFff.Config do
  @moduledoc """
  Configuration struct for ExFff file indexing.

  ## Fields

  - `:root_path` — project root directory to scan
  - `:max_files` — max files to index (default 50_000)
  - `:ignore_patterns` — regex patterns for paths to exclude (default:
    `_build/`, `deps/`, `.git/`, `node_modules/`, `cover/`)
  """

  defstruct root_path: nil,
            max_files: 50_000,
            ignore_patterns: nil

  @type t :: %__MODULE__{
          root_path: String.t() | nil,
          max_files: pos_integer(),
          ignore_patterns: [Regex.t()]
        }

  @default_ignore_patterns [
    ~r{_build/},
    ~r{deps/},
    ~r{\.git/},
    ~r{node_modules/},
    ~r{cover/}
  ]

  @doc """
  Build a Config struct from a keyword list.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    merged = Keyword.merge([ignore_patterns: @default_ignore_patterns], opts)
    struct!(__MODULE__, merged)
  end

  @doc """
  Returns true if the given path matches any ignore pattern.
  """
  @spec ignored?(t(), String.t()) :: boolean()
  def ignored?(%__MODULE__{ignore_patterns: patterns}, path) do
    Enum.any?(patterns, &String.match?(path, &1))
  end
end
