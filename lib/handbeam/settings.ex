defmodule Handbeam.Settings do
  @moduledoc """
  Global settings persistence — read/write `~/.handbeam/settings.json`.

  Works with `Handbeam.WorkspaceSettings` for per-workspace overrides and
  `Handbeam.Settings.ModelAISettings` for schema/validation/merge.
  """

  alias Handbeam.Settings.ModelAISettings

  @global_filename "settings.json"

  @doc """
  Default global settings directory (`~/.handbeam`).
  """
  def default_global_dir do
    Path.join(Handbeam.Home.path(), ".handbeam")
  end

  @doc """
  Return the global settings file path.

  Respects `HANDBEAM_GLOBAL_SETTINGS_FILE` env var override.
  """
  def global_settings_path(opts \\ []) do
    case System.get_env("HANDBEAM_GLOBAL_SETTINGS_FILE") do
      nil ->
        dir = Keyword.get(opts, :global_dir, default_global_dir())
        Path.join(dir, @global_filename)

      path ->
        path
    end
  end

  # ── Global settings ──────────────────────────────────────────

  @doc """
  Load global settings from `~/.handbeam/settings.json`.

  Returns `{:ok, %{}}` when the file doesn't exist.
  Returns `{:ok, %{}}` on parse error (non-fatal).
  """
  @spec load_global(keyword()) :: {:ok, map()}
  def load_global(opts \\ []) do
    path = global_settings_path(opts)

    case File.read(path) do
      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          _ -> {:ok, %{}}
        end

      {:error, _reason} ->
        {:ok, %{}}
    end
  end

  @doc """
  Save the `model_ai` section to global settings.

  Preserves existing non-`model_ai` top-level keys.
  """
  @spec save_global(map(), keyword()) :: :ok | {:error, term()}
  def save_global(model_ai_map, opts \\ []) do
    path = global_settings_path(opts)

    with {:ok, existing} <- load_global(opts),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      updated = Map.put(existing, "model_ai", model_ai_map)

      case File.write(path, Handbeam.JSON.encode!(updated)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
      end
    end
  end

  # ── Workspace model_ai override ─────────────────────────────

  @doc """
  Load the `model_ai` section from a workspace's `.handbeam/settings.jsonc`.

  Returns `{:ok, %{}}` when there is no `model_ai` section or the file doesn't exist.
  """
  @spec load_workspace_model_ai(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_workspace_model_ai(workspace_root) do
    with {:ok, settings} <- load_workspace(workspace_root) do
      model_ai = Map.get(settings, "model_ai", %{})
      {:ok, if(is_map(model_ai), do: model_ai, else: %{})}
    end
  end

  @doc """
  Load the full workspace settings from `.handbeam/settings.jsonc`.

  Delegates to `Handbeam.WorkspaceSettings.load/1`.
  """
  @spec load_workspace(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_workspace(workspace_root) do
    Handbeam.WorkspaceSettings.load(workspace_root)
  end

  @doc """
  Save the `model_ai` section to workspace `.handbeam/settings.jsonc`.

  Preserves existing non-`model_ai` top-level keys.
  Creates `.handbeam/` directory if missing.
  """
  @spec save_workspace_model_ai(Path.t(), map()) :: :ok | {:error, term()}
  def save_workspace_model_ai(workspace_root, model_ai_map) do
    sigil_dir = Path.join(workspace_root, ".handbeam")
    settings_path = Path.join(sigil_dir, "settings.jsonc")

    with {:ok, existing} <- load_workspace(workspace_root),
         :ok <- File.mkdir_p(sigil_dir) do
      updated = Map.put(existing, "model_ai", model_ai_map)

      case File.write(settings_path, Handbeam.JSON.encode!(updated)) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write #{settings_path}: #{inspect(reason)}"}
      end
    end
  end

  # ── Effective settings ──────────────────────────────────────

  @doc """
  Compute effective Model/AI settings by merging:

  1. Application defaults (`ModelAISettings.defaults/0`)
  2. Global settings (`~/.handbeam/settings.json` → `model_ai`)
  3. Workspace override (`.handbeam/settings.jsonc` → `model_ai`)

  Each layer overrides the one before it.
  """
  @spec effective_model_ai(Path.t(), keyword()) :: ModelAISettings.t()
  def effective_model_ai(workspace_root, opts \\ []) do
    case fetch_effective_model_ai(workspace_root, opts) do
      {:ok, settings} -> settings
      {:error, _reason} -> ModelAISettings.defaults()
    end
  end

  @doc "Fetch effective Model/AI settings, preserving load errors for UI display."
  @spec fetch_effective_model_ai(Path.t(), keyword()) ::
          {:ok, ModelAISettings.t()} | {:error, term()}
  def fetch_effective_model_ai(workspace_root, opts \\ []) do
    with {:ok, global} <- load_global(opts),
         {:ok, workspace} <- load_workspace_model_ai(workspace_root) do
      global_model_ai = Map.get(global, "model_ai", %{})

      settings =
        ModelAISettings.defaults()
        |> ModelAISettings.merge(ModelAISettings.normalize_override(global_model_ai))
        |> ModelAISettings.merge(ModelAISettings.normalize_override(workspace))

      {:ok, settings}
    end
  end

  @doc "Return effective global Model/AI settings before workspace overrides."
  @spec global_model_ai(keyword()) :: ModelAISettings.t()
  def global_model_ai(opts \\ []) do
    {:ok, global} = load_global(opts)

    ModelAISettings.defaults()
    |> ModelAISettings.merge(ModelAISettings.normalize_override(Map.get(global, "model_ai", %{})))
  end
end
