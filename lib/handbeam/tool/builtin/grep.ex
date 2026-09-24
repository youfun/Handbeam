defmodule Handbeam.Tool.Builtin.Grep do
  @moduledoc """
  Search file contents in the workspace.

  Desktop uses ripgrep when `rg` is on PATH. On-device Mob (and any host
  without `rg`) falls back to a pure-Elixir walk so grep still works.

  Accepts both Handbeam-style arguments (`pattern`, `path`, `context`) and common
  Claude-style grep arguments (`-n`, `-A`, `output_mode`).
  """

  @behaviour Handbeam.Agent.Tool

  @default_limit 100
  @max_result_chars 20_000
  @max_fallback_file_bytes 5_000_000
  @fallback_ignored_dirs MapSet.new(
                           ~w(.cxx .git .gradle .handbeam .local-archive .zig-cache _build artifacts build cover deps doc mix_toolchain node_modules tmp zig-out)
                         )

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search file contents for a pattern. " <>
      "Use this to locate symbols or text before reading/editing files. " <>
      "Supports pattern, path, glob, ignore_case, literal, context, before_context, " <>
      "after_context, limit, and Claude-style -n/-A/-B/-C arguments."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Search pattern (regex by default)"},
        path: %{type: "string", description: "Directory or file to search, defaults to workspace"},
        glob: %{type: "string", description: "Optional glob filter such as *.ex"},
        ignore_case: %{type: "boolean", description: "Case-insensitive search", default: false},
        literal: %{
          type: "boolean",
          description: "Treat pattern as a literal string",
          default: false
        },
        context: %{type: "integer", description: "Lines before and after each match", default: 0},
        before_context: %{type: "integer", description: "Lines before each match", default: 0},
        after_context: %{type: "integer", description: "Lines after each match", default: 0},
        limit: %{type: "integer", description: "Maximum matching lines", default: @default_limit},
        output_mode: %{
          type: "string",
          description: "Accepted for compatibility; content is returned"
        },
        "-n": %{type: "boolean", description: "Show line numbers; accepted for compatibility"},
        "-A": %{type: "integer", description: "Lines after each match"},
        "-B": %{type: "integer", description: "Lines before each match"},
        "-C": %{type: "integer", description: "Context lines around each match"}
      },
      required: ["pattern"]
    }
  end

  @impl true
  def max_result_chars, do: @max_result_chars

  @impl true
  def concurrent?, do: true

  @impl true
  def execute(input, context) when is_map(input) do
    with {:ok, pattern} <- fetch_pattern(input),
         {:ok, root} <- resolve_search_root(input, context),
         :ok <- validate_readable(root) do
      search_contents(pattern, root, input)
    end
  rescue
    e -> {:error, "grep failed: #{Exception.message(e)}"}
  end

  def execute(_input, _context), do: {:error, "pattern is required"}

  defp search_contents(pattern, root, input) do
    if System.find_executable("rg") do
      args = build_rg_args(pattern, root, input)

      case System.cmd("rg", args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, normalize_output(output)}
        {"", 1} -> {:ok, "No matches found"}
        {output, 1} -> {:ok, normalize_output(output)}
        {output, code} -> {:error, "rg exited with #{code}: #{String.trim(output)}"}
      end
    else
      elixir_search(pattern, root, input)
    end
  end

  defp elixir_search(pattern, root, input) do
    with {:ok, regex} <- compile_pattern(pattern, input),
         {:ok, files} <- grep_files(root, input["glob"] || input[:glob]) do
      before_n = context_before(input)
      after_n = context_after(input)
      max_hits = limit(input)

      {lines, _count} =
        Enum.reduce_while(files, {[], 0}, fn path, {acc, count} ->
          if count >= max_hits do
            {:halt, {acc, count}}
          else
            {chunk, added} = search_file(path, root, regex, before_n, after_n, max_hits - count)
            {:cont, {acc ++ chunk, count + added}}
          end
        end)

      {:ok, normalize_output(Enum.join(lines, "\n"))}
    end
  end

  defp compile_pattern(pattern, input) do
    source =
      if truthy?(input["literal"] || input[:literal]),
        do: Regex.escape(pattern),
        else: pattern

    opts = if truthy?(input["ignore_case"] || input[:ignore_case]), do: "i", else: ""

    case Regex.compile(source, opts) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "invalid pattern: #{reason}"}
    end
  end

  defp grep_files(root, glob) do
    cond do
      File.regular?(root) ->
        if safe_regular_file?(root, root) and glob_match?(root, root, glob),
          do: {:ok, [root]},
          else: {:ok, []}

      File.dir?(root) ->
        files = walk_files(root, root, glob)

        {:ok, files}

      true ->
        {:ok, []}
    end
  end

  defp glob_match?(_path, _root, glob) when glob in [nil, ""], do: true

  defp glob_match?(path, root, glob) when is_binary(glob) do
    relative = Path.relative_to(path, root) |> String.replace("\\", "/")
    basename = Path.basename(path)
    patterns = expand_braces(glob |> String.replace("\\", "/") |> String.trim_leading("/"))

    Enum.any?(patterns, fn pattern ->
      match_glob?(relative, pattern) or match_glob?(basename, pattern) or
        match_glob?(relative, "**/" <> pattern)
    end)
  end

  defp glob_match?(_path, _root, _glob), do: true

  defp match_glob?(path, pattern) do
    regex =
      pattern
      |> String.split("/")
      |> Enum.map(&glob_segment_to_regex/1)
      |> Enum.join("/")
      |> then(&("^" <> &1 <> "$"))
      |> Regex.compile!()

    Regex.match?(regex, path)
  end

  defp glob_segment_to_regex("**"), do: ".*"
  defp glob_segment_to_regex("*"), do: "[^/]*"
  defp glob_segment_to_regex("?"), do: "[^/]"

  defp glob_segment_to_regex(segment) do
    segment
    |> String.graphemes()
    |> Enum.map(fn
      "*" -> "[^/]*"
      "?" -> "[^/]"
      char -> Regex.escape(char)
    end)
    |> IO.iodata_to_binary()
  end

  defp expand_braces(pattern) do
    case Regex.run(~r/\{([^{}]+)\}/, pattern, return: :index) do
      [{start, length}, {content_start, content_length}] ->
        prefix = binary_part(pattern, 0, start)
        suffix_start = start + length
        suffix = binary_part(pattern, suffix_start, byte_size(pattern) - suffix_start)

        pattern
        |> binary_part(content_start, content_length)
        |> String.split(",", trim: true)
        |> Enum.flat_map(&expand_braces(prefix <> &1 <> suffix))

      nil ->
        [pattern]
    end
  end

  defp walk_files(dir, root, glob) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %{type: :directory}} ->
              if MapSet.member?(@fallback_ignored_dirs, name),
                do: [],
                else: walk_files(path, root, glob)

            {:ok, %{type: :regular}} ->
              if safe_regular_file?(path, root) and glob_match?(path, root, glob),
                do: [path],
                else: []

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp safe_regular_file?(path, root) do
    inside_workspace?(path, root) and
      match?({:ok, %{type: :regular}}, File.lstat(path))
  end

  defp search_file(path, root, regex, before_n, after_n, remaining) do
    if not inside_workspace?(path, root) do
      {[], 0}
    else
      read_and_search(path, root, regex, before_n, after_n, remaining)
    end
  end

  defp read_and_search(path, root, regex, before_n, after_n, remaining) do
    with {:ok, %{size: size}} when size <= @max_fallback_file_bytes <- File.stat(path),
         {:ok, content} <- File.read(path) do
      if String.valid?(content) do
        lines = String.split(content, "\n")
        rel = Path.relative_to(path, root)
        hits = matching_indexes(lines, regex)

        formatted =
          hits
          |> Enum.take(remaining)
          |> Enum.flat_map(&format_hit(rel, lines, &1, before_n, after_n))

        {formatted, min(length(hits), remaining)}
      else
        {[], 0}
      end
    else
      _ -> {[], 0}
    end
  end

  defp inside_workspace?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    expanded_path == expanded_root or
      String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp inside_workspace_resolved?(path, root) do
    resolved_root = root |> Path.expand() |> Handbeam.Security.PathValidator.resolve_symlink()
    resolved_path = path |> Path.expand() |> Handbeam.Security.PathValidator.resolve_symlink()

    resolved_path == resolved_root or
      String.starts_with?(resolved_path, resolved_root <> "/")
  end

  defp matching_indexes(lines, regex) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp format_hit(rel, lines, index, before_n, after_n) do
    start_i = max(1, index - before_n)
    end_i = min(length(lines), index + after_n)

    for i <- start_i..end_i do
      line = Enum.at(lines, i - 1) || ""

      if i == index do
        "#{rel}:#{i}:#{line}"
      else
        "#{rel}-#{i}-#{line}"
      end
    end
  end

  defp context_before(input) do
    context = int_value(input, ["context", :context, "-C"])
    before_context = int_value(input, ["before_context", :before_context, "-B"])
    if context > 0, do: context, else: before_context
  end

  defp context_after(input) do
    context = int_value(input, ["context", :context, "-C"])
    after_context = int_value(input, ["after_context", :after_context, "-A"])
    if context > 0, do: context, else: after_context
  end

  defp fetch_pattern(input) do
    pattern = input["pattern"] || input[:pattern] || input["query"] || input[:query]

    if is_binary(pattern) and String.trim(pattern) != "" do
      {:ok, pattern}
    else
      {:error, "pattern is required"}
    end
  end

  defp resolve_search_root(input, context) do
    raw_path = input["path"] || input[:path] || input["file_path"] || input[:file_path] || "."

    working_directory =
      Map.get(context, :working_directory) || Map.get(context, "working_directory") || File.cwd!()

    path =
      if Path.type(raw_path) == :absolute do
        raw_path
      else
        Path.expand(raw_path, working_directory)
      end

    with :ok <- ensure_inside_workspace(path, working_directory) do
      {:ok, path}
    end
  end

  defp ensure_inside_workspace(path, working_directory) do
    if inside_workspace_resolved?(path, working_directory) do
      :ok
    else
      {:error, "Path outside workspace: #{path}"}
    end
  end

  defp validate_readable(path) do
    if not File.exists?(path) do
      {:error, "Path not found: #{path}"}
    else
      :ok
    end
  end

  defp build_rg_args(pattern, root, input) do
    args = ["--line-number", "--color=never", "--hidden", "--max-count", to_string(limit(input))]

    args =
      if truthy?(input["ignore_case"] || input[:ignore_case]),
        do: args ++ ["--ignore-case"],
        else: args

    args =
      if truthy?(input["literal"] || input[:literal]), do: args ++ ["--fixed-strings"], else: args

    args =
      case input["glob"] || input[:glob] do
        glob when is_binary(glob) and glob != "" -> args ++ ["--glob", glob]
        _ -> args
      end

    args = add_context_args(args, input)
    args ++ ["--", pattern, root]
  end

  defp add_context_args(args, input) do
    context = int_value(input, ["context", :context, "-C"])
    before_context = int_value(input, ["before_context", :before_context, "-B"])
    after_context = int_value(input, ["after_context", :after_context, "-A"])

    cond do
      context > 0 ->
        args ++ ["-C", to_string(context)]

      before_context > 0 or after_context > 0 ->
        args
        |> maybe_add_context("-B", before_context)
        |> maybe_add_context("-A", after_context)

      true ->
        args
    end
  end

  defp maybe_add_context(args, _flag, value) when value <= 0, do: args
  defp maybe_add_context(args, flag, value), do: args ++ [flag, to_string(value)]

  defp limit(input) do
    case int_value(input, ["limit", :limit]) do
      n when n > 0 -> n
      _ -> @default_limit
    end
  end

  defp int_value(input, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(input, key) do
        n when is_integer(n) -> n
        s when is_binary(s) -> parse_int(s)
        _ -> nil
      end
    end)
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp normalize_output(output) do
    output = String.trim_trailing(output)
    if output == "", do: "No matches found", else: output
  end
end
