defmodule Handbeam.WorkspaceSettings do
  @moduledoc """
  Workspace-local settings stored as `.handbeam/settings.jsonc`.

  The file is intentionally JSONC so users can keep inline notes next to
  workspace model restrictions and tool permissions.
  """

  @settings_relpath ".handbeam/settings.jsonc"

  @default_content """
  {
    // Workspace-local Handbeam settings.
    // Path: .handbeam/settings.jsonc
    //
    // `models` restricts which globally configured providers/models are available
    // in this workspace. An empty providers object means unrestricted.
    "models": {
      "allow": {
        "providers": {}
      }
    },

    // Tool permissions default to today's backward-compatible behavior.
    // Use default_mode/per_tool/allow/deny to control execution per workspace.
    // Example: "per_tool": { "bash": "prompt", "edit": "prompt" }
    "tools": {
      "default_mode": "auto",
      "allow": [],
      "deny": [],
      "per_tool": {},

      // BEAM tools can inspect a running Elixir project.
      // docs/source/sql are auto-registered for mix projects unless auto is false.
      // eval is powerful and is disabled by default; enable it explicitly per workspace.
      "beam": {
        "auto": true,
        "eval": false
      },
      "explicit": []
    }
  }
  """

  @doc """
  Return the workspace settings path.
  """
  @spec path(Path.t()) :: Path.t()
  def path(workspace_root) do
    Path.join(workspace_root, @settings_relpath)
  end

  @doc """
  Ensure `.handbeam/settings.jsonc` exists without overwriting existing settings.
  """
  @spec ensure_file(Path.t()) :: :ok | {:error, String.t()}
  def ensure_file(workspace_root) do
    settings_path = path(workspace_root)

    if File.exists?(settings_path) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(settings_path)),
           :ok <- File.write(settings_path, @default_content) do
        :ok
      else
        {:error, reason} ->
          {:error, "Failed to initialize workspace settings: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Append a Matcher pattern to `tools.allow` or `tools.deny`.

  Duplicate patterns are ignored. Missing settings files are created.
  """
  @spec append_tool_rule(Path.t(), :allow | :deny, String.t()) :: :ok | {:error, String.t()}
  def append_tool_rule(workspace_root, list, pattern)
      when list in [:allow, :deny] and is_binary(pattern) do
    pattern = String.trim(pattern)

    if pattern == "" do
      {:error, "pattern must not be empty"}
    else
      settings_path = path(workspace_root)

      with {:ok, existing} <- read_existing_for_write(settings_path),
           :ok <- File.mkdir_p(Path.dirname(settings_path)) do
        tools = existing |> Map.get("tools", %{}) |> ensure_map()
        current = tools |> Map.get(Atom.to_string(list), []) |> normalize_string_list()
        updated_list = if pattern in current, do: current, else: current ++ [pattern]
        updated_tools = Map.put(tools, Atom.to_string(list), updated_list)
        updated = Map.put(existing, "tools", updated_tools)

        case atomic_write(settings_path, Handbeam.JSON.encode!(updated, pretty: true)) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to write settings: #{inspect(reason)}"}
        end
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "Failed to prepare settings path: #{inspect(reason)}"}
      end
    end
  end

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp normalize_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_string_list(_), do: []

  @doc """
  Update default tool mode in workspace settings file.
  """
  @spec update_default_mode(Path.t(), :auto | :prompt | :deny) :: :ok | {:error, any()}
  def update_default_mode(workspace_root, mode) when mode in [:auto, :prompt, :deny] do
    mode_str = Atom.to_string(mode)
    settings_path = path(workspace_root)

    case File.read(settings_path) do
      {:ok, content} ->
        updated_content =
          if String.contains?(content, "default_mode") do
            Regex.replace(
              ~r/"default_mode"\s*:\s*"[^"]*"/,
              content,
              "\"default_mode\": \"#{mode_str}\""
            )
          else
            case decode_jsonc(content) do
              {:ok, settings} ->
                tools = Map.get(settings, "tools", %{})
                updated_tools = Map.put(tools, "default_mode", mode_str)
                updated_settings = Map.put(settings, "tools", updated_tools)
                Handbeam.JSON.encode!(updated_settings, pretty: true)

              {:error, _} ->
                content
            end
          end

        case File.write(settings_path, updated_content) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to write workspace settings: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        with :ok <- ensure_file(workspace_root) do
          update_default_mode(workspace_root, mode)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load and parse workspace settings.


  Missing settings are treated as an empty settings map.
  """
  @spec load(Path.t()) :: {:ok, map()} | {:error, String.t()}
  def load(workspace_root) do
    settings_path = path(workspace_root)

    case File.read(settings_path) do
      {:ok, content} ->
        case decode_jsonc(content) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          {:ok, _other} -> {:error, "Failed to parse #{settings_path}: expected a JSON object"}
          {:error, reason} -> {:error, "Failed to parse #{settings_path}: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "Failed to read #{settings_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Return the workspace model policy from settings.

  Missing settings or missing `models` means unrestricted.
  """
  @spec models_policy(Path.t()) :: :unrestricted | {:ok, map()} | {:error, String.t()}
  def models_policy(workspace_root) do
    case load(workspace_root) do
      {:ok, settings} ->
        case Map.get(settings, "models") do
          %{} = models -> {:ok, models}
          _ -> :unrestricted
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Return BEAM tool configuration with conservative defaults.
  """
  @spec beam_tools_config(Path.t()) :: %{
          required(:auto) => boolean(),
          required(:eval) => boolean(),
          required(:explicit) => [String.t()]
        }
  def beam_tools_config(workspace_root) do
    settings =
      case load(workspace_root) do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    beam = get_in(settings, ["tools", "beam"]) || %{}
    explicit = get_in(settings, ["tools", "explicit"]) || []

    %{
      auto: Map.get(beam, "auto", true) != false,
      eval: Map.get(beam, "eval", false) == true,
      explicit: if(is_list(explicit), do: Enum.filter(explicit, &is_binary/1), else: [])
    }
  end

  defp decode_jsonc(content) do
    content
    |> strip_jsonc_comments()
    |> strip_trailing_commas()
    |> Handbeam.JSON.decode()
  end

  defp strip_jsonc_comments(content) do
    content
    |> String.graphemes()
    |> strip_comments([], :normal, nil)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp strip_comments([], acc, _state, _quote), do: acc

  defp strip_comments(["/" | rest], acc, :normal, nil) do
    case rest do
      ["/" | tail] ->
        {_comment, tail} = Enum.split_while(tail, &(&1 not in ["\n", "\r"]))
        strip_comments(tail, acc, :normal, nil)

      ["*" | tail] ->
        strip_block_comment(tail, acc)

      _ ->
        strip_comments(rest, ["/" | acc], :normal, nil)
    end
  end

  defp strip_comments(["\"" = char | rest], acc, :normal, nil),
    do: strip_comments(rest, [char | acc], :string, "\"")

  defp strip_comments([char | rest], acc, :normal, nil),
    do: strip_comments(rest, [char | acc], :normal, nil)

  defp strip_comments(["\\" = char, escaped | rest], acc, :string, quote),
    do: strip_comments(rest, [escaped, char | acc], :string, quote)

  defp strip_comments([quote | rest], acc, :string, quote),
    do: strip_comments(rest, [quote | acc], :normal, nil)

  defp strip_comments([char | rest], acc, :string, quote),
    do: strip_comments(rest, [char | acc], :string, quote)

  defp strip_block_comment([], acc), do: acc

  defp strip_block_comment(["*" | rest], acc) do
    case rest do
      ["/" | tail] -> strip_comments(tail, acc, :normal, nil)
      _ -> strip_block_comment(rest, acc)
    end
  end

  defp strip_block_comment([_char | rest], acc), do: strip_block_comment(rest, acc)

  defp strip_trailing_commas(content) do
    Regex.replace(~r/,\s*([}\]])/, content, "\\1")
  end

  # ──────────────────────────────────────────────────────────────
  # Write methods
  # ──────────────────────────────────────────────────────────────

  @doc """
  Write or update the workspace model access policy.

  Reads the existing `.handbeam/settings.jsonc` (if present), replaces the
  `"models"` key with the given policy, and writes back as prettified JSON.

  Non-model settings (e.g. `"tools"`) are preserved. JSONC comments are
  **not** preserved in the output (this is a known limitation).

  Creates the settings file and its parent directory if they do not exist.
  """
  @spec write_policy(Path.t(), map()) :: :ok | {:error, String.t()}
  def write_policy(workspace_root, policy) when is_map(policy) do
    settings_path = path(workspace_root)

    with {:ok, existing} <- read_existing_for_write(settings_path),
         :ok <- File.mkdir_p(Path.dirname(settings_path)) do
      updated = Map.put(existing, "models", policy)

      case atomic_write(settings_path, Handbeam.JSON.encode!(updated, pretty: true)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write settings: #{inspect(reason)}"}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Failed to prepare settings path: #{inspect(reason)}"}
    end
  end

  def write_policy(_workspace_root, _policy) do
    {:error, "Policy must be a map"}
  end

  defp atomic_write(path, content) do
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp_path, content)
      File.rename!(tmp_path, path)
      :ok
    rescue
      e in File.Error ->
        File.rm(tmp_path)
        {:error, e}
    end
  end

  defp read_existing_for_write(settings_path) do
    case File.read(settings_path) do
      {:ok, content} ->
        case decode_jsonc(content) do
          {:ok, settings} when is_map(settings) ->
            {:ok, settings}

          {:ok, _other} ->
            {:error, "Failed to parse #{settings_path}: expected a JSON object"}

          {:error, reason} ->
            {:error, "Failed to parse #{settings_path}: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "Failed to read #{settings_path}: #{inspect(reason)}"}
    end
  end
end
