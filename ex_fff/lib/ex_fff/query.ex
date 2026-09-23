defmodule ExFff.Query do
  @moduledoc """
  Query parser for ExFff search expressions.

  Supports a compact search syntax:

  - `"schema"` — fuzzy match terms (AND semantics)
  - `"*.ex"` — include patterns (glob-style extension filter)
  - `"!test/"` — exclude patterns (paths containing substring)
  - `"user controller"` — multi-term AND search
  """

  defstruct terms: [],
            include_patterns: [],
            exclude_patterns: [],
            limit: 20

  @type t :: %__MODULE__{
          terms: [String.t()],
          include_patterns: [String.t()],
          exclude_patterns: [String.t()],
          limit: pos_integer()
        }

  @doc """
  Parse a raw query string into a structured `ExFff.Query`.

  ## Examples

      iex> ExFff.Query.parse("schema")
      %ExFff.Query{terms: ["schema"], include_patterns: [], exclude_patterns: []}

      iex> ExFff.Query.parse("*.ex")
      %ExFff.Query{terms: [], include_patterns: [".ex"], exclude_patterns: []}

      iex> ExFff.Query.parse("user !test/")
      %ExFff.Query{terms: ["user"], include_patterns: [], exclude_patterns: ["test/"]}

      iex> ExFff.Query.parse("user controller *.ex !test/")
      %ExFff.Query{terms: ["user", "controller"], include_patterns: [".ex"], exclude_patterns: ["test/"]}

  """
  @spec parse(String.t()) :: t()
  def parse(string) when is_binary(string) do
    trimmed = String.trim(string)

    if trimmed == "" do
      %__MODULE__{limit: 0}
    else
      tokens = String.split(trimmed, ~r/\s+/)
      classify(tokens, %__MODULE__{})
    end
  end

  defp classify([], acc), do: acc

  defp classify([token | rest], acc) do
    acc =
      cond do
        String.starts_with?(token, "!") ->
          %{acc | exclude_patterns: acc.exclude_patterns ++ [String.trim_leading(token, "!")]}

        String.starts_with?(token, "*.") ->
          ext = String.trim_leading(token, "*")
          %{acc | include_patterns: acc.include_patterns ++ [ext]}

        String.starts_with?(token, "*") ->
          %{acc | include_patterns: acc.include_patterns ++ [String.trim_leading(token, "*")]}

        true ->
          %{acc | terms: acc.terms ++ [token]}
      end

    classify(rest, acc)
  end
end
