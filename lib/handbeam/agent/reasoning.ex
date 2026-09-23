defmodule Handbeam.Agent.Reasoning do
  @moduledoc """
  Provider-neutral reasoning level helpers.

  Models opt in with `reasoning: true`. Optional `defaultReasoning` and
  `thinkingLevelMap` values from models.json refine the UI and provider
  request mapping.
  """

  @levels ["off", "minimal", "low", "medium", "high", "xhigh"]
  @reasoning_levels ["minimal", "low", "medium", "high", "xhigh"]
  @default_map %{
    "minimal" => "low",
    "low" => "low",
    "medium" => "medium",
    "high" => "high",
    "xhigh" => "high"
  }

  @type level :: String.t()
  @type model_entry :: map()

  @doc "All Handbeam reasoning levels."
  @spec levels() :: [level()]
  def levels, do: @levels

  @spec valid?(term()) :: boolean()
  def valid?(level), do: normalize(level) in @levels

  @spec normalize(term()) :: level()
  def normalize(level) when is_atom(level), do: level |> Atom.to_string() |> normalize()

  def normalize(level) when is_binary(level) do
    normalized = level |> String.trim() |> String.downcase()

    if normalized in @levels, do: normalized, else: "off"
  end

  def normalize(_level), do: "off"

  @doc """
  Returns visible reasoning levels for a model.

  `off` is always visible for reasoning-capable models. `thinkingLevelMap`
  entries set to `nil` hide that level.
  """
  @spec supported_levels(model_entry()) :: [level()]
  def supported_levels(model_entry) do
    if reasoning?(model_entry) do
      map = thinking_level_map(model_entry)

      ["off" | Enum.reject(@reasoning_levels, &(Map.get(map, &1, :supported) == nil))]
    else
      []
    end
  end

  @doc "Default selected level for a model."
  @spec default_level(model_entry()) :: level()
  def default_level(model_entry) do
    levels = supported_levels(model_entry)
    default = normalize(map_get(model_entry, :default_reasoning, "defaultReasoning"))

    cond do
      levels == [] -> "off"
      default in levels and default != "off" -> default
      "medium" in levels -> "medium"
      true -> List.first(levels) || "off"
    end
  end

  @doc """
  Resolves a Handbeam level to provider effort.

  Returns `:off` for disabled reasoning and `{:error, :unsupported}` when the
  selected level is hidden by the model map.
  """
  @spec resolve(model_entry(), term()) :: {:ok, String.t()} | :off | {:error, :unsupported}
  def resolve(model_entry, selected_level) do
    level = normalize(selected_level)

    cond do
      level == "off" ->
        :off

      not reasoning?(model_entry) ->
        :off

      level not in supported_levels(model_entry) ->
        {:error, :unsupported}

      true ->
        map = thinking_level_map(model_entry)
        {:ok, Map.get(map, level, Map.fetch!(@default_map, level))}
    end
  end

  @doc """
  Applies provider-specific request options for the selected reasoning level.
  """
  @spec apply_provider_options(map(), model_entry(), term()) :: map()
  def apply_provider_options(provider_config, model_entry, selected_level) do
    case resolve(model_entry, selected_level) do
      {:ok, effort} -> put_provider_effort(provider_config, effort)
      :off -> provider_config
      {:error, :unsupported} -> provider_config
    end
  end

  defp put_provider_effort(%{provider: "deepseek"} = config, effort) do
    config
    |> Map.put(:thinking, %{type: "enabled"})
    |> Map.put(:reasoning_effort, effort)
  end

  defp put_provider_effort(%{api: api} = config, effort)
       when api in [:openai_responses, :openai_codex_responses] do
    Map.put(config, :reasoning, %{effort: effort})
  end

  defp put_provider_effort(%{api: :anthropic} = config, effort) do
    config
    |> Map.put(:thinking, %{type: "adaptive"})
    |> Map.put(:output_config, %{effort: effort})
  end

  defp put_provider_effort(%{api: :stepfun} = config, effort) do
    config
    |> Map.put(:thinking, %{type: "adaptive"})
    |> Map.put(:output_config, %{effort: effort})
  end

  defp put_provider_effort(config, effort) do
    Map.put(config, :reasoning_effort, effort)
  end

  defp reasoning?(model_entry) do
    case map_get(model_entry, :reasoning, "reasoning") do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> infer_reasoning_support(model_entry)
    end
  end

  # Existing configs often omit `reasoning`. Infer for Step Router / StepFun /
  # Anthropic-compatible entries so the composer picker still appears.
  defp infer_reasoning_support(model_entry) do
    tokens =
      [
        map_get(model_entry, :id, "id"),
        map_get(model_entry, :model_id, "model_id"),
        map_get(model_entry, :name, "name"),
        map_get(model_entry, :provider_id, "provider_id"),
        map_get(model_entry, :provider, "provider"),
        map_get(model_entry, :api, "api")
      ]
      |> Enum.map(&to_string/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(tokens, "step-router") or
      String.contains?(tokens, "stepfun") or
      String.contains?(tokens, "anthropic")
  end

  defp thinking_level_map(model_entry) do
    case map_get(model_entry, :thinking_level_map, "thinkingLevelMap") do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp map_get(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key, Map.get(map, string_key))
  end

  defp map_get(_map, _atom_key, _string_key), do: nil
end
