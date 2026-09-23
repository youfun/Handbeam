defmodule Handbeam.Settings.ModelAIOverride do
  @moduledoc """
  Model/AI layer helpers on top of `Handbeam.Settings`.

  Answers "which layer does each field come from", saves a full
  `Handbeam.Settings.ModelAISettings` form to the global file or as a workspace
  override (diffed against global), and clears workspace overrides so a field
  inherits the global value again. No UI dependency; the native settings
  screen and LiveView can both sit on top of it.
  """

  alias Handbeam.Settings
  alias Handbeam.Settings.ModelAISettings

  @type target :: :global | {:workspace, Path.t()}
  @type source :: :workspace | :global

  @doc """
  Per-field origin of the effective Model/AI settings for a workspace.

  A field is `:workspace` when the workspace `.handbeam/settings.jsonc` overrides
  it, otherwise `:global`. An unreadable workspace file is treated as "no
  overrides" (every field `:global`); callers that need the error use
  `Handbeam.Settings.fetch_effective_model_ai/1`.
  """
  @spec sources(Path.t()) :: %{atom() => source()}
  def sources(workspace_root) do
    override =
      case Settings.load_workspace_model_ai(workspace_root) do
        {:ok, raw} -> ModelAISettings.normalize_override(raw)
        {:error, _reason} -> %{}
      end

    Map.new(ModelAISettings.fields(), fn field ->
      {field, if(Map.has_key?(override, field), do: :workspace, else: :global)}
    end)
  end

  @doc """
  Save a full settings form.

  `:global` writes the form as the global `model_ai` section. `{:workspace, path}`
  stores only the fields that differ from the current global settings, so the
  workspace file never freezes copies of global values.
  """
  @spec save(target(), ModelAISettings.t()) :: :ok | {:error, term()}
  def save(:global, %ModelAISettings{} = form) do
    form
    |> ModelAISettings.to_json_map()
    |> Settings.save_global()
  end

  def save({:workspace, path}, %ModelAISettings{} = form) do
    Settings.global_model_ai()
    |> ModelAISettings.diff(form)
    |> ModelAISettings.override_to_json_map()
    |> then(&Settings.save_workspace_model_ai(path, &1))
  end

  @doc """
  Make `fields` inherit the global value again in the workspace override.

  Other workspace overrides are preserved.
  """
  @spec inherit(Path.t(), [atom()]) :: :ok | {:error, term()}
  def inherit(path, fields) when is_list(fields) do
    effective = Settings.effective_model_ai(path)
    global = Settings.global_model_ai()

    updated =
      Enum.reduce(fields, effective, fn field, acc ->
        Map.put(acc, field, Map.get(global, field))
      end)

    save({:workspace, path}, updated)
  end

  @doc "Remove every workspace Model/AI override."
  @spec inherit_all(Path.t()) :: :ok | {:error, term()}
  def inherit_all(path), do: Settings.save_workspace_model_ai(path, %{})
end
