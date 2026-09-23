defmodule Handbeam.Permissions.Matcher do
  @moduledoc """
  Glob matcher for workspace tool permission patterns.

  Supports plain tool globs (`read`, `mem_*`) and scoped argument patterns such
  as `bash(rm:*)`, `edit(.env)`, and `write(config/*.json)`.
  """

  @spec match?(String.t(), map()) :: boolean()
  def match?(pattern, call) when is_binary(pattern) and is_map(call) do
    {tool_pattern, arg_pattern} = split_pattern(pattern)
    tool_name = normalize_name(call[:name] || call["name"])

    glob_match?(tool_pattern, tool_name) and
      arg_match?(tool_name, arg_pattern, call[:input] || call["input"] || %{})
  end

  def match?(_pattern, _call), do: false

  defp split_pattern(pattern) do
    case Regex.run(~r/^([^()]+)\((.*)\)$/, pattern) do
      [_, tool, arg] -> {String.trim(tool), String.trim(arg)}
      _ -> {String.trim(pattern), nil}
    end
  end

  defp arg_match?(_tool_name, nil, _input), do: true

  defp arg_match?("bash", arg_pattern, input) do
    glob_match?(arg_pattern, input_value(input, ["command", :command]))
  end

  defp arg_match?("browser", arg_pattern, input) do
    command_pattern =
      case String.split(arg_pattern, ":", parts: 2) do
        [command, _rest] -> command
        [command] -> command
      end

    glob_match?(command_pattern, Handbeam.Browser.Policy.command_token(input))
  end

  defp arg_match?(tool, arg_pattern, input) when tool in ["edit", "write", "read"] do
    glob_match?(arg_pattern, input_value(input, ["file_path", :file_path, "path", :path]))
  end

  defp arg_match?(_tool, arg_pattern, input) do
    Enum.any?(
      input,
      fn {_k, value} -> is_binary(value) and glob_match?(arg_pattern, value) end
    )
  end

  defp input_value(input, keys) when is_map(input) do
    Enum.find_value(keys, "", &Map.get(input, &1))
    |> to_string()
  end

  defp input_value(_input, _keys), do: ""

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
  defp normalize_name(_name), do: ""

  defp glob_match?(nil, _value), do: false

  defp glob_match?(pattern, value) when is_binary(pattern) and is_binary(value) do
    regex = pattern |> String.replace(":", " ") |> glob_regex()
    Regex.match?(regex, value)
  end

  defp glob_regex(pattern) do
    source =
      pattern
      |> String.graphemes()
      |> Enum.map_join(fn
        "*" -> ".*"
        "?" -> "."
        " " -> "\\s+"
        char -> Regex.escape(char)
      end)

    Regex.compile!("^" <> source <> "$")
  end
end
