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
  @max_page_bytes 48_000
  @max_line_bytes 2_000
  @max_context 3
  @scan_budget_ms 2_000

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search file contents for a regex or literal pattern. " <>
      "Omit pattern and pass glob to list matching files. " <>
      "Use file_search for fuzzy name search. " <>
      "path should be workspace-relative; an absolute path is accepted only inside the current workspace. " <>
      "Results are grouped by file; pass next_cursor as cursor to continue."
  end

  @impl true
  def hint do
    "A failed search is not an empty result. Add a content pattern, or pass glob to list files. " <>
      "If path is outside the workspace, omit it or use a workspace-relative path. " <>
      "Do not invent another user's absolute path, and do not repeat the same arguments unchanged."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description: "Required content pattern (regex by default)"
        },
        path: %{
          type: "string",
          description:
            "Workspace-relative file or directory. Absolute paths must stay inside the current workspace"
        },
        glob: %{
          type: "string",
          description: "Optional file filter such as *.{ex,exs}; not a search pattern"
        },
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
    with {:ok, workspace, prefix, note} <- resolve_scope(input, context) do
      case fetch_pattern(input) do
        {:ok, pattern} ->
          input
          |> search_pattern(pattern, workspace, prefix)
          |> with_note(note)

        :missing ->
          if glob_present?(input) do
            list_by_glob(input, workspace, prefix, note)
          else
            {:error, missing_pattern_error(workspace)}
          end
      end
    end
  rescue
    error -> {:error, "grep failed: #{Exception.message(error)}"}
  catch
    {:invalid_cursor, reason} ->
      {:error, reason, %{code: :cursor_invalid, side_effect: :not_started, status: :failed}}
  end

  def execute(_input, _context), do: {:error, "pattern is required"}

  defp inventory(index, workspace, prefix, input) do
    excludes = Handbeam.Utils.SafeMap.get_first_truthy(input, "exclude", :exclude) || []
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
    cursor = decode_cursor(Handbeam.Utils.SafeMap.get_first_truthy(input, "cursor", :cursor), input, workspace)
    wanted = limit(input) + 1

    if cursor == :invalid do
      throw({:invalid_cursor, "cursor does not match this query and workspace"})
    end

    files =
      inventory.paths
      |> Enum.filter(&glob_match?(&1, Handbeam.Utils.SafeMap.get_first_truthy(input, "glob", :glob)))
      |> Enum.sort()

    {matcher, hits, partial?} =
      case System.find_executable("rg") do
        nil ->
          {hits, partial?} = elixir_hits(files, workspace, regex, cursor, wanted)
          {:elixir, hits, partial?}

        rg ->
          case rg_hits(
                 rg,
                 files,
                 workspace,
                 inventory.prefix,
                 pattern,
                 input,
                 cursor,
                 wanted
               ) do
            {:ok, hits, partial?} ->
              {:ripgrep, hits, partial?}

            {:error, _code} ->
              {hits, partial?} = elixir_hits(files, workspace, regex, cursor, wanted)
              {:elixir, hits, partial?}
          end
      end

    safe_hits = take_safe_hits(hits, workspace, wanted)
    page = safe_hits |> Enum.take(limit(input)) |> fit_page_bytes()

    next_cursor =
      if page != [] and (length(safe_hits) > length(page) or partial?) do
        encode_cursor(Enum.max_by(page, &{&1.path, &1.line}), input, workspace)
      end

    emit_telemetry(started_at, length(files), length(page), matcher, inventory.status)

    if partial? and page == [] do
      {:error, "grep scan timed out before completion; narrow path or glob and retry",
       %{code: :scan_timeout, status: :failed, side_effect: :not_started}}
    else
      {:ok,
       format_results(page, next_cursor, Map.put(inventory, :partial, partial?), workspace, input)}
    end
  end

  defp elixir_hits(files, workspace, regex, cursor, wanted) do
    validation = new_validation(workspace)
    deadline = System.monotonic_time(:millisecond) + @scan_budget_ms

    {hits, _validation, partial?} =
      Enum.reduce_while(files, {[], validation, false}, fn relative,
                                                           {acc, validation, _partial?} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, {acc, validation, true}}
        else
          remaining = max(wanted - length(acc), 0)

          {hits, validation} =
            file_hits(relative, workspace, regex, cursor, validation, remaining)

          next = acc ++ hits

          if length(next) >= wanted,
            do: {:halt, {next, validation, false}},
            else: {:cont, {next, validation, false}}
        end
      end)

    {hits, partial?}
  end

  defp file_hits(relative, workspace, regex, cursor, validation, wanted) do
    with {:ok, content, validation} <- read_search_file(workspace, relative, validation),
         true <- String.valid?(content) do
      hits =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce_while([], fn {line, number}, acc ->
          hit = bound_hit(%{path: relative, line: number, text: line})

          if byte_size(line) <= @max_line_bytes and Regex.match?(regex, line) and
               after_cursor?(hit, cursor) do
            next = [hit | acc]
            if length(next) >= wanted, do: {:halt, next}, else: {:cont, next}
          else
            {:cont, acc}
          end
        end)
        |> Enum.reverse()

      {hits, validation}
    else
      {:error, validation} -> {[], validation}
      false -> {[], validation}
    end
  end

  defp rg_hits(rg, files, workspace, prefix, pattern, input, cursor, wanted) do
    inventory = MapSet.new(files)
    target = if prefix in [nil, "", "."], do: ".", else: prefix
    args = rg_args(input) ++ rg_sensitive_globs() ++ ["--", pattern, target]

    case stream_rg(rg, args, workspace, inventory, input, cursor, wanted) do
      {:ok, hits, partial?} ->
        {:ok, hits, partial?}

      {:error, code} ->
        {:error, code}
    end
  end

  defp stream_rg(rg, args, workspace, inventory, input, cursor, wanted) do
    port =
      Port.open(
        {:spawn_executable, rg},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, workspace},
          {:args, args},
          {:line, @max_line_bytes}
        ]
      )

    collect_rg(
      port,
      inventory,
      input,
      cursor,
      wanted,
      [],
      System.monotonic_time(:millisecond) + @scan_budget_ms,
      false
    )
  end

  defp collect_rg(port, inventory, input, cursor, wanted, acc, deadline, partial?) do
    overtime? = System.monotonic_time(:millisecond) > deadline

    cond do
      length(acc) >= wanted or overtime? ->
        close_rg(port)
        {:ok, Enum.reverse(acc), true}

      true ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            acc = maybe_add_rg_hit(acc, line_text(line), inventory, input, cursor)

            collect_rg(
              port,
              inventory,
              input,
              cursor,
              wanted,
              acc,
              deadline,
              partial?
            )

          {^port, {:data, {:noeol, _line}}} ->
            collect_rg(port, inventory, input, cursor, wanted, acc, deadline, true)

          {^port, {:data, data}} when is_binary(data) ->
            acc = maybe_add_rg_hit(acc, line_text(data), inventory, input, cursor)
            collect_rg(port, inventory, input, cursor, wanted, acc, deadline, true)

          {^port, {:exit_status, code}} when code in [0, 1] ->
            {:ok, Enum.reverse(acc), partial?}

          {^port, {:exit_status, code}} ->
            {:error, code}
        after
          200 ->
            if System.monotonic_time(:millisecond) > deadline do
              close_rg(port)
              {:ok, Enum.reverse(acc), true}
            else
              collect_rg(port, inventory, input, cursor, wanted, acc, deadline, partial?)
            end
        end
    end
  end

  defp maybe_add_rg_hit(acc, line, inventory, input, cursor) do
    case parse_rg_line(line) do
      nil ->
        acc

      hit ->
        hit = hit |> normalize_rg_hit() |> bound_hit()

        if MapSet.member?(inventory, hit.path) and
             glob_match?(hit.path, Handbeam.Utils.SafeMap.get_first_truthy(input, "glob", :glob)) and
             after_cursor?(hit, cursor) do
          [hit | acc]
        else
          acc
        end
    end
  end

  defp line_text(line) when is_binary(line), do: String.slice(line, 0, @max_line_bytes)
  defp line_text(line) when is_list(line), do: line |> IO.iodata_to_binary() |> line_text()
  defp line_text(line), do: line |> to_string() |> line_text()

  defp close_rg(port) do
    if Port.info(port), do: Port.close(port)
  catch
    _, _ -> :ok
  end

  defp rg_args(input) do
    # ripgrep omits the filename when only one path is searched unless this is
    # explicit. The parser and cursor contract always require path:line:text.
    base = [
      "--line-number",
      "--color=never",
      "--no-heading",
      "--with-filename",
      "--sort",
      "path",
      "--hidden",
      "--max-filesize",
      Integer.to_string(@max_file_bytes)
    ]

    base = if truthy?(Handbeam.Utils.SafeMap.get_first_truthy(input, "ignore_case", :ignore_case)), do: base ++ ["-i"], else: base
    if truthy?(Handbeam.Utils.SafeMap.get_first_truthy(input, "literal", :literal)), do: base ++ ["-F"], else: base
  end

  defp rg_sensitive_globs do
    globs =
      Handbeam.Security.PathValidator.rg_exclude_globs() ++ ExFff.Config.rg_exclude_globs()

    Enum.flat_map(globs, &["--glob", &1])
  end

  defp parse_rg_line(line) when is_binary(line) do
    case Regex.run(~r/^(.+?):(\d+):(.*)$/u, line) do
      [_, path, number, text] -> %{path: path, line: String.to_integer(number), text: text}
      _ -> nil
    end
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

  defp indexing_suffix(%{partial: true}) do
    "\n[partial: scan budget reached; continue with next_cursor or narrow path/glob]"
  end

  defp indexing_suffix(_inventory), do: ""

  defp after_cursor?(_hit, nil), do: true

  defp after_cursor?(hit, {path, line, _query, _workspace}),
    do: {hit.path, hit.line} > {path, line}

  defp after_cursor?(_hit, :invalid), do: false

  defp encode_cursor(%{path: path, line: line}, input, workspace) do
    payload = {1, path, line, query_key(input), workspace_key(workspace)}
    Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  defp decode_cursor(nil, _input, _workspace), do: nil

  defp decode_cursor(cursor, input, workspace) when is_binary(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false),
         {1, path, line, query, workspace_key} when is_binary(path) and is_integer(line) <-
           :erlang.binary_to_term(binary, [:safe]) do
      if query == query_key(input) and workspace_key == workspace_key(workspace) do
        {path, line, query, workspace_key}
      else
        :invalid
      end
    else
      _ -> :invalid
    end
  rescue
    _ -> :invalid
  end

  defp query_key(input) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        input["pattern"] || input[:pattern],
        Handbeam.Utils.SafeMap.get_first_truthy(input, "path", :path),
        Handbeam.Utils.SafeMap.get_first_truthy(input, "glob", :glob),
        Handbeam.Utils.SafeMap.get_first_truthy(input, "literal", :literal),
        Handbeam.Utils.SafeMap.get_first_truthy(input, "ignore_case", :ignore_case)
      })
    )
    |> Base.encode16(case: :lower)
  end

  defp workspace_key(workspace), do: Path.expand(workspace || "")

  defp bound_hit(hit), do: %{hit | text: String.slice(hit.text || "", 0, @max_line_bytes)}

  defp fit_page_bytes(hits) do
    {kept, _bytes} =
      Enum.reduce_while(hits, {[], 0}, fn hit, {acc, bytes} ->
        next = bytes + byte_size(hit.text || "") + byte_size(hit.path || "") + 16

        if acc != [] and next > @max_page_bytes do
          {:halt, {acc, bytes}}
        else
          {:cont, {[hit | acc], next}}
        end
      end)

    Enum.reverse(kept)
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

  defp search_pattern(input, pattern, workspace, prefix) do
    with {:ok, regex} <- compile_pattern(pattern, input),
         {:ok, index} <- Handbeam.Search.ensure_started(workspace),
         {:ok, inventory} <- inventory(index, workspace, prefix, input) do
      search(pattern, regex, inventory, workspace, input)
    end
  end

  defp list_by_glob(input, workspace, prefix, note) do
    with {:ok, index} <- Handbeam.Search.ensure_started(workspace),
         {:ok, inventory} <- inventory(index, workspace, prefix, input) do
      glob = input["glob"] || input[:glob]

      files =
        inventory.paths
        |> Enum.filter(&(glob_match?(&1, glob) and safe_search_file?(workspace, &1)))
        |> Enum.sort()
        |> Enum.take(limit(input))

      body =
        case files do
          [] -> "No matches found"
          paths -> Enum.join(paths, "\n")
        end

      {:ok, body <> indexing_suffix(inventory)}
      |> with_note(note)
    end
  end

  defp fetch_pattern(input) do
    pattern = input["pattern"] || input[:pattern] || input["query"] || input[:query]

    if is_binary(pattern) and String.trim(pattern) != "",
      do: {:ok, pattern},
      else: :missing
  end

  defp glob_present?(input) do
    case input["glob"] || input[:glob] do
      glob when is_binary(glob) -> String.trim(glob) != ""
      _ -> false
    end
  end

  defp missing_pattern_error(workspace) do
    "pattern is required to search contents. Pass glob to list files, or use file_search. " <>
      "Omit path or use a workspace-relative path under #{workspace}. " <>
      "Do not invent another user's absolute path."
  end

  defp resolve_scope(input, context) do
    workspace = context[:working_directory] || context["working_directory"] || File.cwd!()
    workspace = Path.expand(workspace)
    raw_path = Handbeam.Utils.SafeMap.get_first_truthy(input, "path", :path) || Handbeam.Utils.SafeMap.get_first_truthy(input, "file_path", :file_path) || "."
    raw_path = Handbeam.Agent.Tool.Helpers.expand_tilde(raw_path)

    requested =
      if Path.type(raw_path) == :absolute, do: raw_path, else: Path.expand(raw_path, workspace)

    {path, note} =
      case reroot_foreign_workspace(requested, workspace) do
        {:ok, rerooted} ->
          relative = Path.relative_to(rerooted, workspace)

          {rerooted,
           "path rewritten into workspace #{workspace} as #{relative}; do not invent another user's absolute path"}

        :error ->
          {requested, nil}
      end

    with :ok <- Handbeam.Security.PathValidator.validate_within_workspace(path, workspace),
         :ok <- Handbeam.Security.PathValidator.reject_resolved(path),
         true <- File.exists?(path) do
      {:ok, workspace, Path.relative_to(path, workspace), note}
    else
      false ->
        {:error, path_not_found(path, note)}

      {:error, "Path traversal blocked: " <> _} ->
        {:error, outside_workspace_error(requested, workspace)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Cursor native Grep often sends an absolute path. A path that merely repeats this
  # workspace's directory name is the same project with a hallucinated home, not a
  # request to read another user's tree.
  defp reroot_foreign_workspace(path, workspace) do
    cond do
      Handbeam.Security.PathValidator.validate_within_workspace(path, workspace) == :ok ->
        :error

      true ->
        base = workspace |> Path.basename() |> String.downcase()
        parts = path |> Path.split() |> Enum.reject(&(&1 in ["/", "\\"]))

        case Enum.with_index(parts)
             |> Enum.filter(fn {part, _index} -> String.downcase(part) == base end) do
          [] ->
            :error

          matches ->
            {_part, index} = List.last(matches)

            relative =
              case Enum.drop(parts, index + 1) do
                [] -> "."
                rest -> Path.join(rest)
              end

            rerooted = Path.expand(relative, workspace)

            case Handbeam.Security.PathValidator.validate_within_workspace(rerooted, workspace) do
              :ok -> {:ok, rerooted}
              {:error, _} -> :error
            end
        end
    end
  end

  defp path_not_found(path, nil), do: "Path not found: #{path}"

  defp path_not_found(path, note), do: "Path not found: #{path}. #{note}"

  defp outside_workspace_error(path, workspace) do
    "Path traversal blocked: #{path} is outside workspace. " <>
      "Current workspace is #{workspace}. Omit path or pass a workspace-relative path. " <>
      "Do not invent another user's home directory."
  end

  defp with_note({:ok, output}, note) when is_binary(output) and is_binary(note) do
    {:ok, output <> "\n[" <> note <> "]"}
  end

  defp with_note(result, _note), do: result

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
    min(if(context > 0, do: context, else: before), @max_context)
  end

  defp context_after(input) do
    context = int_value(input, ["context", :context, "-C"])
    after_context = int_value(input, ["after_context", :after_context, "-A"])
    min(if(context > 0, do: context, else: after_context), @max_context)
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
