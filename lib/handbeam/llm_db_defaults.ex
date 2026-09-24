defmodule Handbeam.LlmDbDefaults do
  @moduledoc """
  Adapter layer for pulling provider and model defaults from `llm_db`.

  The settings UI uses this to prefill provider/model metadata when the user
  enters IDs that exist in the catalog.
  """

  @type provider_defaults :: %{
          optional(:provider_name) => String.t(),
          optional(:base_url) => String.t(),
          optional(:api) => String.t(),
          optional(:provider_runtime) => String.t()
        }

  @type model_defaults :: %{
          optional(:model_name) => String.t(),
          optional(:context_window) => integer(),
          optional(:max_tokens) => integer(),
          optional(:price_input) => number(),
          optional(:price_output) => number(),
          optional(:price_cache_read) => number(),
          optional(:price_cache_write) => number(),
          optional(:price_reasoning) => number()
        }

  @spec defaults_for(String.t() | nil, String.t() | nil) :: %{
          provider: provider_defaults(),
          model: model_defaults()
        }
  def defaults_for(provider_id, model_id) do
    with :ok <- ensure_loaded() do
      %{
        provider: provider_defaults(provider_id),
        model: model_defaults(provider_id, model_id)
      }
    else
      _ -> %{provider: %{}, model: %{}}
    end
  end

  @spec provider_defaults(String.t() | nil) :: provider_defaults()
  def provider_defaults(provider_id) do
    with {:ok, provider_atom} <- normalize_provider(provider_id),
         {:ok, provider} <- LLMDB.provider(provider_atom) do
      %{}
      |> maybe_put(:provider_name, provider.name)
      |> maybe_put(:base_url, provider_base_url(provider))
      |> maybe_put(:api, api_type_for(provider.id))
      |> maybe_put(:provider_runtime, runtime_provider_for(provider.id))
    else
      _ -> %{}
    end
  end

  @spec model_defaults(String.t() | nil, String.t() | nil) :: model_defaults()
  def model_defaults(provider_id, model_id) do
    with {:ok, provider_atom} <- normalize_provider(provider_id),
         {:ok, model_id} <- normalize_model_id(model_id),
         {:ok, model} <- LLMDB.model(provider_atom, model_id) do
      model_defaults_from(model)
    else
      _ -> %{}
    end
  end

  @doc """
  Official upstream price for a model id.

  Cursor is not an llm_db provider. Its catalog ids are upstream models plus
  effort suffixes (`gpt-5.3-codex-low-fast`, `claude-opus-4-6`). Strip the
  suffix and read the vendor catalog (OpenAI / Anthropic), not a reseller:
  reseller prices disagree. Missing prices stay absent — never invent 0.
  """
  @spec price_for_model_id(String.t() | nil) :: map() | nil
  def price_for_model_id(model_id) do
    with :ok <- ensure_loaded(),
         {:ok, model_id} <- normalize_model_id(model_id),
         cost when is_map(cost) <- lookup_cost(model_id) do
      cost
    else
      _ -> nil
    end
  end

  defp model_defaults_from(model) do
    cost = Map.get(model, :cost) || %{}
    limits = Map.get(model, :limits) || %{}

    %{}
    |> maybe_put(:model_name, Map.get(model, :name))
    |> maybe_put(:context_window, Map.get(limits, :context))
    |> maybe_put(:max_tokens, Map.get(limits, :output))
    |> maybe_put(:price_input, numeric_cost(cost, :input))
    |> maybe_put(:price_output, numeric_cost(cost, :output))
    |> maybe_put(:price_cache_read, numeric_cost(cost, :cache_read))
    |> maybe_put(:price_cache_write, numeric_cost(cost, :cache_write))
    |> maybe_put(:price_reasoning, numeric_cost(cost, :reasoning))
  end

  @effort_suffixes ["-xhigh", "-high", "-medium", "-low", "-fast", "-thinking"]
  @openai_prefixes ["gpt-", "o1", "o3", "o4", "chatgpt-"]
  @anthropic_prefixes ["claude-"]

  defp lookup_cost(model_id) do
    case vendor_cost(model_id) do
      %{} = cost ->
        cost

      nil ->
        case strip_effort(model_id) do
          ^model_id -> nil
          base -> vendor_cost(base)
        end
    end
  end

  defp vendor_cost(model_id) do
    model_id
    |> vendor_provider()
    |> case do
      nil ->
        nil

      provider ->
        case LLMDB.model(provider, vendor_model_id(provider, model_id)) do
          {:ok, model} -> catalog_cost(model)
          _ -> nil
        end
    end
  end

  defp vendor_model_id(:anthropic, model_id), do: String.replace(model_id, ".", "-")
  defp vendor_model_id(_provider, model_id), do: model_id

  defp vendor_provider(model_id) do
    cond do
      String.starts_with?(model_id, @openai_prefixes) -> :openai
      String.starts_with?(model_id, @anthropic_prefixes) -> :anthropic
      true -> nil
    end
  end

  defp catalog_cost(model) do
    cost = Map.get(model, :cost) || %{}

    %{}
    |> maybe_put("input", numeric_cost(cost, :input))
    |> maybe_put("output", numeric_cost(cost, :output))
    |> maybe_put("cache_read", numeric_cost(cost, :cache_read))
    |> maybe_put("cache_write", numeric_cost(cost, :cache_write))
    |> maybe_put("reasoning", numeric_cost(cost, :reasoning))
    |> case do
      cost when map_size(cost) == 0 -> nil
      cost -> cost
    end
  end

  defp strip_effort(model_id) do
    Enum.reduce(@effort_suffixes, model_id, fn suffix, id ->
      String.replace(id, suffix, "")
    end)
  end

  defp ensure_loaded do
    case Code.ensure_loaded(LLMDB) do
      {:module, LLMDB} ->
        case LLMDB.load() do
          {:ok, _snapshot} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :llm_db_unavailable}
    end
  end

  defp normalize_provider(provider_id) when is_binary(provider_id) do
    case String.trim(provider_id) do
      "" ->
        {:error, :blank_provider}

      value ->
        LLMDB.providers()
        |> Enum.find(fn provider -> Atom.to_string(provider.id) == value end)
        |> case do
          nil -> {:error, :unknown_provider}
          provider -> {:ok, provider.id}
        end
    end
  end

  defp normalize_provider(_), do: {:error, :invalid_provider}

  defp normalize_model_id(model_id) when is_binary(model_id) do
    model_id
    |> String.trim()
    |> case do
      "" -> {:error, :blank_model}
      value -> {:ok, value}
    end
  end

  defp normalize_model_id(_), do: {:error, :invalid_model}

  defp provider_base_url(%{runtime: %{base_url: base_url}})
       when is_binary(base_url) and base_url != "",
       do: base_url

  defp provider_base_url(%{base_url: base_url}) when is_binary(base_url) and base_url != "",
    do: base_url

  defp provider_base_url(%{id: :stepfun}), do: "https://api.stepfun.com/step_plan/v1"
  defp provider_base_url(_provider), do: nil

  defp api_type_for(:openai), do: "openai"
  defp api_type_for(:anthropic), do: "anthropic-messages"
  defp api_type_for(:stepfun), do: "stepfun-step-plan"
  defp api_type_for(_provider), do: "openai-compatible"

  defp runtime_provider_for(:openai), do: "openai"
  defp runtime_provider_for(:anthropic), do: "anthropic"
  defp runtime_provider_for(:stepfun), do: "stepfun"
  defp runtime_provider_for(:zenmux), do: "zenmux"
  defp runtime_provider_for(:openrouter), do: "openrouter"
  defp runtime_provider_for(:deepseek), do: "deepseek"
  defp runtime_provider_for(_provider), do: "openai-compat"

  defp numeric_cost(cost, key) do
    case Map.get(cost, key) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
