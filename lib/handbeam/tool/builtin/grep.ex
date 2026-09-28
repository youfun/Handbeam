defmodule Handbeam.Tool.Builtin.Grep do
  @moduledoc """
  Search workspace file contents over the shared ExFff inventory.

  Results are grouped by file and paged with an opaque cursor. Ripgrep is used
  when available and its output is intersected with the shared inventory.
  Other hosts read that inventory directly with an Elixir matcher.
  """

  @behaviour Handbeam.Agent.Tool

  @default_limit 100
  @inventory_page 10_000
  @max_result_chars 20_000
  @max_file_bytes 5_000_000

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search indexed workspace files for a regex or literal pattern. " <>
      "Results are grouped by file; pass next_cursor as cursor to continue."
  end

  @impl true
  def hint do
    "Fix the pattern or narrow path/glob from the error. A failed search is not an empty " <>
      "result; do not repeat the same pattern unchanged."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        pattern: %{type: "string", description: "Search pattern (regex by default)"},
        path: %{type: "string", description: "Workspace-relative file or directory"},
        glob: %{type: "string", description: "Optional glob such as *.{ex,exs}"},
        exclude: %{
          type: "array",
          items: %{type: "string"},
          description: "Path substrings to exclude"
        },
        cursor: %{type: "string", description: "Opaque next_cursor from a previous result"},
        ignore_case: %{type: "boolean", default: false},
        literal: %{type: "boolean", default: false},
        context: %{type: "integer", default: 0},
        before_context: %{type: "integer", default: 0},
        after_context: %{type: "integer", default: 0},
        limit: %{type: "integer", description: "Maximum matching lines", default: @default_limit},
        output_mode: %{type: "string", description: "Accepted for compatibility"},
        "-n": %{type: "boolean", description: "Accepted for compatibility"},
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
         {:ok, workspace, prefix} <- resolve_scope(input, context),
         {:ok, regex} <- compile_pattern(pattern, input),
         {:ok, index} <- Handbeam.Search.ensure_started(workspace),
         {:ok, inventory} <- inventory(index, workspace, prefix, input) do
      search(pattern, regex, inventory, workspace, input)
    end
  rescue
    error -> {:error, "grep failed: #{Exception.message(error)}"}
  end

  def execute(_input, _context), do: {:error, "pattern is required"}

  defp inventory(index, workspace, prefix, input) do
    excludes = input["exclude"] || input[:exclude] || []
    collect_inventory(index, workspace, prefix, List.wrap(excludes), nil, [], nil)
  end

  defp collect_inventory(index, workspace, prefix, excludes, cursor, acc, status) do
    opts = [path: prefix, exclude: excludes, cursor: cursor, limit: @inventory_page]

    with {:ok, page} <- Handbeam.Search.files(index, opts) do
      next_acc = acc ++ page.paths

      if page.cursor do
        collect_inventory(index, workspace, prefix, excludes, page.cursor, next_acc, page.status)
      else
        {:ok,
         %{
           paths: next_acc,
           prefix: prefix,
           status: status || page.status,
           indexed_count: page.indexed_count
         }}
      end
    end
  end

  defp search(pattern, regex, inventory, workspace, input) do
    started_at = System.monotonic_time(:millisecond)
    cursor = decode_cursor(input["cursor"] || input[:cursor])
    wanted = limit(input) + 1
    files = Enum.filter(inventory.paths, &glob_match?(&1, input["glob"] || input[:glob]))

    {matcher, hits} =
      case System.find_executable("rg") do
        nil ->
          {:elixir, elixir_hits(files, workspace, regex, cursor, wanted)}

        rg ->
          case rg_hits(rg, files, workspace, inventory.prefix, pattern, input, cursor) do
            {:ok, hits} -> {:ripgrep, hits}
            {:error, _code} -> {:elixir, elixir_hits(files, workspace, regex, cursor, wanted)}
          end
      end

    safe_hits = take_safe_hits(hits, workspace, wanted)
    page = Enum.take(safe_hits, limit(input))

    next_cursor =
      if length(safe_hits) > length(page), do: encode_cursor(List.last(page)), else: nil

    emit_telemetry(started_at, length(files), length(page), matcher, inventory.status)

    {:ok, format_results(page, next_cursor, inventory, workspace, input)}
  end

  defp elixir_hits(files, workspace, regex, cursor, wanted) do
    validation = new_validation(workspace)

    {hits, _validation} =
      Enum.reduce_while(files, {[], validation}, fn relative, {acc, validation} ->
        {hits, validation} = file_hits(relative, workspace, regex, cursor, validation)
        next = acc ++ hits

        if length(next) >= wanted,
          do: {:halt, {next, validation}},
          else: {:cont, {next, validation}}
      end)

    hits
  end

  defp file_hits(relative, workspace, regex, cursor, validation) do
    with {:ok, content, validation} <- read_search_file(workspace, relative, validation),
         true <- String.valid?(content) do
      hits =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          hit = %{path: relative, line: number, text: line}
          if Regex.match?(regex, line) and after_cursor?(hit, cursor), do: [hit], else: []
        end)

      {hits, validation}
    else
      {:error, validation} -> {[], validation}
      false -> {[], validation}
    end
  end

  defp rg_hits(rg, files, workspace, prefix, pattern, input, cursor) do
    inventory = MapSet.new(files)
    target = if prefix in [nil, "", "."], do: ".", else: prefix
    args = rg_args(input) ++ rg_sensitive_globs() ++ ["--", pattern, target]
    {output, code} = System.cmd(rg, args, cd: workspace, stderr_to_stdout: true)

    if code in [0, 1] do
      hits =
        output
        |> parse_rg_output()
        |> Enum.map(&normalize_rg_hit/1)
        |> Enum.filter(fn hit ->
          MapSet.member?(inventory, hit.path) and
            glob_match?(hit.path, input["glob"] || input[:glob]) and
            after_cursor?(hit, cursor)
        end)
        |> Enum.sort_by(&{&1.path, &1.line})

      {:ok, hits}
    else
      {:error, code}
    end
  end

  defp rg_args(input) do
    # ripgrep omits the filename when only one path is searched unless this is
    # explicit. The parser and cursor contract always require path:line:text.
    base = [
      "--line-number",
      "--color=never",
      "--no-heading",
      "--with-filename",
      "--hidden",
      "--max-filesize",
      Integer.to_string(@max_file_bytes)
    ]

    base = if truthy?(input["ignore_case"] || input[:ignore_case]), do: base ++ ["-i"], else: base
    base = if truthy?(input["literal"] || input[:literal]), do: base ++ ["-F"], else: base
    base
  end

  defp rg_sensitive_globs do
    globs =
      Handbeam.Security.PathValidator.rg_exclude_globs() ++ ExFff.Config.rg_exclude_globs()

    Enum.flat_map(globs, &["--glob", &1])
  end

  defp parse_rg_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(.+?):(\d+):(.*)$/u, line) do
        [_, path, number, text] ->
          [%{path: path, line: String.to_integer(number), text: text}]

        _ ->
          []
      end
    end)
  end

  defp normalize_rg_hit(hit) do
    %{hit | path: hit.path |> String.replace("\\", "/") |> String.trim_leading("./")}
  end

  defp format_results([], _cursor, inventory, _workspace, _input) do
    "No matches found" <> indexing_suffix(inventory)
  end

  defp format_results(hits, next_cursor, inventory, workspace, input) do
    before_n = context_before(input)
    after_n = context_after(input)

    body =
      hits
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {path, file_hits} ->
        lines = read_lines(workspace, path)

        rendered =
          file_hits
          |> Enum.sort_by(& &1.line)
          |> Enum.flat_map(&format_hit(path, lines, &1.line, before_n, after_n))
          |> Enum.uniq()
          |> Enum.join("\n")

        "== #{path} ==\n" <> rendered
      end)

    continuation = if next_cursor, do: "next_cursor: #{next_cursor}\n", else: ""
    continuation <> body <> indexing_suffix(inventory)
  end

  defp read_lines(workspace, relative) do
    case read_search_file(workspace, relative) do
      {:ok, content} when is_binary(content) -> String.split(content, "\n")
      _ -> []
    end
  end

  defp take_safe_hits(hits, workspace, wanted) do
    {safe, _checked} =
      Enum.reduce_while(hits, {[], %{}}, fn hit, {acc, checked} ->
        path = hit.path

        {allowed?, checked} =
          case checked do
            %{^path => allowed?} ->
              {allowed?, checked}

            _ ->
              allowed? = safe_search_file?(workspace, path)
              {allowed?, Map.put(checked, path, allowed?)}
          end

        next = if allowed?, do: [hit | acc], else: acc

        if length(next) >= wanted,
          do: {:halt, {next, checked}},
          else: {:cont, {next, checked}}
      end)

    Enum.reverse(safe)
  end

  defp read_search_file(workspace, relative) do
    path = Path.join(workspace, relative)

    with true <- safe_search_file?(workspace, relative),
         {:ok, %{size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> {:error, :unsafe_or_unreadable}
    end
  end

  defp read_search_file(workspace, relative, validation) do
    path = Path.join(workspace, relative)
    {directory_allowed?, validation} = validate_directory(Path.dirname(path), validation)

    with true <- directory_allowed?,
         :ok <- Handbeam.Security.PathValidator.reject_sensitive(relative),
         {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content, validation}
    else
      _ -> {:error, validation}
    end
  end

  defp new_validation(workspace) do
    root =
      case Handbeam.Security.PathValidator.canonicalize(workspace) do
        {:ok, resolved} -> resolved
        {:error, _reason} -> Path.expand(workspace)
      end

    %{root: root, directories: %{}}
  end

  defp validate_directory(directory, validation) do
    case validation.directories do
      %{^directory => allowed?} ->
        {allowed?, validation}

      _ ->
        allowed? =
          case Handbeam.Security.PathValidator.canonicalize(directory) do
            {:ok, resolved} ->
              contained?(resolved, validation.root) and
                Handbeam.Security.PathValidator.reject_sensitive(resolved) == :ok

            {:error, _reason} ->
              false
          end

        {allowed?, put_in(validation.directories[directory], allowed?)}
    end
  end

  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp safe_search_file?(workspace, relative) do
    path = Path.join(workspace, relative)

    Handbeam.Security.PathValidator.reject_sensitive(relative) == :ok and
      Handbeam.Security.PathValidator.validate_within_workspace(path, workspace) == :ok and
      Handbeam.Security.PathValidator.reject_resolved(path) == :ok and
      regular_file?(path)
  end

  defp format_hit(path, lines, index, before_n, after_n) do
    start_i = max(1, index - before_n)
    end_i = min(length(lines), index + after_n)

    for i <- start_i..end_i do
      separator = if i == index, do: ":", else: "-"
      "#{path}#{separator}#{i}#{separator}#{Enum.at(lines, i - 1) || ""}"
    end
  end

  defp indexing_suffix(%{status: :indexing, indexed_count: count}) do
    "\n[indexing: #{count} files scanned so far]"
  end

  defp indexing_suffix(_inventory), do: ""

  defp after_cursor?(_hit, nil), do: true
  defp after_cursor?(hit, {path, line}), do: {hit.path, hit.line} > {path, line}

  defp encode_cursor(%{path: path, line: line}) do
    Base.url_encode64(:erlang.term_to_binary({path, line}), padding: false)
  end

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false),
         {path, line} when is_binary(path) and is_integer(line) <-
           :erlang.binary_to_term(binary, [:safe]) do
      {path, line}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp compile_pattern(pattern, input) do
    source =
      if truthy?(input["literal"] || input[:literal]), do: Regex.escape(pattern), else: pattern

    options = if truthy?(input["ignore_case"] || input[:ignore_case]), do: "i", else: ""

    case Regex.compile(source, options) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "invalid pattern: #{reason}"}
    end
  end

  defp fetch_pattern(input) do
    pattern = input["pattern"] || input[:pattern] || input["query"] || input[:query]

    if is_binary(pattern) and String.trim(pattern) != "",
      do: {:ok, pattern},
      else: {:error, "pattern is required"}
  end

  defp resolve_scope(input, context) do
    workspace = context[:working_directory] || context["working_directory"] || File.cwd!()
    raw_path = input["path"] || input[:path] || input["file_path"] || input[:file_path] || "."
    raw_path = Handbeam.Agent.Tool.Helpers.expand_tilde(raw_path)

    path =
      if Path.type(raw_path) == :absolute, do: raw_path, else: Path.expand(raw_path, workspace)

    with :ok <- Handbeam.Security.PathValidator.validate_within_workspace(path, workspace),
         :ok <- Handbeam.Security.PathValidator.reject_resolved(path),
         true <- File.exists?(path) do
      {:ok, Path.expand(workspace), Path.relative_to(path, workspace)}
    else
      false -> {:error, "Path not found: #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_file?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  defp glob_match?(_path, glob) when glob in [nil, ""], do: true

  defp glob_match?(path, glob) when is_binary(glob) do
    basename = Path.basename(path)

    glob
    |> expand_braces()
    |> Enum.any?(fn pattern ->
      regex = glob_regex(pattern)
      Regex.match?(regex, path) or Regex.match?(regex, basename)
    end)
  end

  defp glob_match?(_path, _glob), do: true

  defp glob_regex(pattern) do
    source =
      pattern
      |> String.replace("\\", "/")
      |> String.trim_leading("/")
      |> String.graphemes()
      |> Enum.map(fn
        "*" -> ".*"
        "?" -> "."
        char -> Regex.escape(char)
      end)
      |> IO.iodata_to_binary()

    Regex.compile!("^" <> source <> "$")
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

  defp context_before(input) do
    context = int_value(input, ["context", :context, "-C"])
    before = int_value(input, ["before_context", :before_context, "-B"])
    if context > 0, do: context, else: before
  end

  defp context_after(input) do
    context = int_value(input, ["context", :context, "-C"])
    after_context = int_value(input, ["after_context", :after_context, "-A"])
    if context > 0, do: context, else: after_context
  end

  defp limit(input) do
    case int_value(input, ["limit", :limit]) do
      value when value > 0 -> min(value, 1_000)
      _ -> @default_limit
    end
  end

  defp int_value(input, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(input, key) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_int(value)
        _ -> nil
      end
    end)
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> nil
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp emit_telemetry(started_at, file_count, result_count, matcher, status) do
    :telemetry.execute(
      [:handbeam, :search, :grep],
      %{
        duration_ms: System.monotonic_time(:millisecond) - started_at,
        file_count: file_count,
        result_count: result_count
      },
      %{matcher: matcher, status: status}
    )
  end
end
