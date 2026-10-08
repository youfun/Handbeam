defmodule Handbeam.Agent.RunOpts do
  @moduledoc """
  Workspace run options shared by LiveView and scheduled dispatch.

  Model resolution stays here so a schedule trigger does not depend on a
  connected page, and does not silently substitute another model.
  """

  alias Handbeam.Agent.{ModelConfig, Reasoning}
  alias Handbeam.Settings
  alias Handbeam.Settings.ModelAISettings

  @spec for_selection(String.t() | nil, String.t() | nil, term(), term()) ::
          {:ok, keyword()} | {:error, term()}
  def for_selection(workspace_path, composite_id, reasoning_level, effective_settings) do
    with {:ok, provider_config, model_id} <- resolve_model(workspace_path, composite_id) do
      entry = model_entry(workspace_path, composite_id)

      provider_config =
        Reasoning.apply_provider_options(provider_config, entry, reasoning_level)

      {:ok,
       [
         provider_config: provider_config,
         model: model_id,
         reasoning_level: reasoning_level,
         workspace_path: blank_to_nil(workspace_path),
         om: om_from_effective(effective_settings)
       ]}
    end
  end

  @spec for_workspace(String.t(), String.t(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def for_workspace(workspace_path, composite_id, opts \\ [])
      when is_binary(workspace_path) and is_binary(composite_id) do
    effective = Settings.effective_model_ai(workspace_path)
    reasoning = Keyword.get(opts, :reasoning_level) || effective.reasoning
    for_selection(workspace_path, composite_id, reasoning, effective)
  end

  @spec resolve_model(String.t() | nil, String.t() | nil) ::
          {:ok, map(), String.t()} | {:error, term()}
  def resolve_model(workspace_path, composite_id) do
    if is_binary(workspace_path) and workspace_path != "" do
      ModelConfig.resolve_model_for_workspace(workspace_path, composite_id)
    else
      resolve_global(composite_id)
    end
  end

  defp resolve_global(nil), do: {:error, "Configure models before sending"}

  defp resolve_global(composite_id) do
    model_entry = Enum.find(ModelConfig.all_global_models(), &(&1.id == composite_id))

    if model_entry do
      case ModelConfig.provider_config_for(
             File.cwd!(),
             model_entry.provider_id,
             model_entry.model_id
           ) do
        {:ok, provider_config} -> {:ok, provider_config, model_entry.model_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Model #{composite_id} is not configured"}
    end
  end

  defp model_entry(workspace_path, composite_id) do
    available =
      if is_binary(workspace_path) and workspace_path != "" do
        ModelConfig.available_models_for_workspace(workspace_path)
      else
        ModelConfig.all_global_models()
      end

    Enum.find(available, %{}, &(&1.id == composite_id))
  end

  defp om_from_effective(nil), do: %{enabled: false}

  defp om_from_effective(effective) do
    effective
    |> ModelAISettings.to_runtime_opts()
    |> Keyword.get(:om, %{enabled: false})
  end

  defp blank_to_nil(path) when is_binary(path) and path != "", do: path
  defp blank_to_nil(_), do: nil
end
