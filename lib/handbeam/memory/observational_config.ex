defmodule Handbeam.Memory.ObservationalConfig do
  @moduledoc """
  Observational Memory configuration.

  Reads from `Application.get_env(:handbeam, :observational_memory)` and
  provides a validated struct for use by middleware and the future Engine.

  ## Config Structure

      config :handbeam, :observational_memory,
        enabled: false,

        # P0 — zero-LLM automatic observations via middleware
        observation: [
          max_recent_context: 5
        ],

        # P1 — LLM Observer (extracts structured observations)
        observer: [
          model: "claude-haiku-4-5-20251001",
          provider: nil,               # nil = reuse agent provider
          model_settings: [
            temperature: 0.3,
            max_output_tokens: 4000
          ],
          message_tokens: 30_000,      # trigger threshold
          buffer_tokens: 10_000,        # async buffer interval
          instruction: ""               # custom observer prompt
        ],

        # P2 — LLM Reflector (compresses observations → engrams)
        reflector: [
          model: "claude-haiku-4-5-20251001",
          provider: nil,
          model_settings: [
            temperature: 0,
            max_output_tokens: 8000
          ],
          observation_tokens: 40_000    # trigger threshold
        ]
  """

  @type model_settings :: %{
          optional(:temperature) => float(),
          optional(:max_output_tokens) => pos_integer(),
          optional(:top_p) => float()
        }

  @type t :: %__MODULE__{
          enabled: boolean(),
          max_recent_context: non_neg_integer(),
          observer_model: String.t() | nil,
          observer_provider: module() | nil,
          observer_model_settings: model_settings(),
          observer_message_tokens: pos_integer(),
          observer_buffer_tokens: pos_integer(),
          observer_instruction: String.t() | nil,
          reflector_model: String.t() | nil,
          reflector_provider: module() | nil,
          reflector_model_settings: model_settings(),
          reflector_observation_tokens: pos_integer()
        }

  defstruct [
    :enabled,
    max_recent_context: 5,
    # Observer (P1)
    observer_model: "claude-haiku-4-5-20251001",
    observer_provider: nil,
    observer_model_settings: %{temperature: 0.3, max_output_tokens: 4000},
    observer_message_tokens: 30_000,
    observer_buffer_tokens: 10_000,
    observer_instruction: nil,
    # Reflector (P2)
    reflector_model: "claude-haiku-4-5-20251001",
    reflector_provider: nil,
    reflector_model_settings: %{temperature: 0, max_output_tokens: 8000},
    reflector_observation_tokens: 40_000
  ]

  @doc """
  Load the observational memory configuration from application env.

  Returns `%Handbeam.Memory.ObservationalConfig{enabled: false}` when not configured.
  """
  @spec load() :: t()
  def load do
    raw = Application.get_env(:handbeam, :observational_memory, [])
    from_kw(raw)
  end

  @doc """
  Build a Config struct from a keyword list or map.

  ## Examples

      iex> Config.from_kw(enabled: true, observation: [max_recent_context: 10])
      %Config{enabled: true, max_recent_context: 10}

      iex> Config.from_kw(enabled: true, observer: [model: "claude-opus"])
      %Config{enabled: true, observer_model: "claude-opus"}
  """
  @spec from_kw(keyword() | map()) :: t()
  def from_kw(kw) when is_list(kw) do
    obs_cfg = Keyword.get(kw, :observation, [])
    observer_cfg = Keyword.get(kw, :observer, [])
    reflector_cfg = Keyword.get(kw, :reflector, [])

    %__MODULE__{
      enabled: Keyword.get(kw, :enabled, false),
      max_recent_context: get_max_recent_context(obs_cfg),
      # Observer
      observer_model: maybe_get(observer_cfg, [:model], "claude-haiku-4-5-20251001"),
      observer_provider: maybe_get(observer_cfg, [:provider]),
      observer_model_settings:
        maybe_get(observer_cfg, [:model_settings], %{temperature: 0.3, max_output_tokens: 4000}),
      observer_message_tokens: maybe_get(observer_cfg, [:message_tokens], 30_000),
      observer_buffer_tokens: maybe_get(observer_cfg, [:buffer_tokens], 10_000),
      observer_instruction: maybe_get(observer_cfg, [:instruction]),
      # Reflector
      reflector_model: maybe_get(reflector_cfg, [:model], "claude-haiku-4-5-20251001"),
      reflector_provider: maybe_get(reflector_cfg, [:provider]),
      reflector_model_settings:
        maybe_get(reflector_cfg, [:model_settings], %{temperature: 0, max_output_tokens: 8000}),
      reflector_observation_tokens: maybe_get(reflector_cfg, [:observation_tokens], 40_000)
    }
  end

  def from_kw(kw) when is_map(kw) do
    enabled = Map.get(kw, :enabled, Map.get(kw, "enabled", false))
    obs = Map.get(kw, :observation, Map.get(kw, "observation", []))
    observer = Map.get(kw, :observer, Map.get(kw, "observer", []))
    reflector = Map.get(kw, :reflector, Map.get(kw, "reflector", []))

    from_kw(
      enabled: enabled,
      observation: normalize_nested(obs),
      observer: normalize_nested(observer),
      reflector: normalize_nested(reflector)
    )
  end

  @doc """
  Return true if observational memory is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    load().enabled
  end

  @doc """
  Return true for a specific config struct.
  """
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{enabled: true}), do: true
  def enabled?(_), do: false

  @doc """
  Runtime settings win over the application env.

  `om` is the map produced by `ModelAISettings.to_runtime_opts/1`. A missing
  map keeps `load/0`. This is what a production release uses: `config/prod.exs`
  does not set `:observational_memory`.
  """
  @spec from_runtime(map() | nil) :: t()
  def from_runtime(om) when is_map(om) do
    base = load()

    %{
      base
      | enabled: enabled_value(om, base.enabled),
        max_recent_context: non_neg_or(om, :max_recent_context, base.max_recent_context),
        observer_model: string_or(om, :observer_model, base.observer_model),
        observer_message_tokens: pos_or(om, :message_tokens, base.observer_message_tokens),
        observer_buffer_tokens: pos_or(om, :buffer_tokens, base.observer_buffer_tokens),
        reflector_model: string_or(om, :reflector_model, base.reflector_model),
        reflector_observation_tokens:
          pos_or(om, :observation_tokens, base.reflector_observation_tokens)
    }
  end

  def from_runtime(_), do: load()

  @doc "Config for this run, or the application env when the run did not carry one."
  @spec for_state(map()) :: t()
  def for_state(%{config: %{context: %{observational: %__MODULE__{} = config}}}), do: config
  def for_state(_), do: load()

  @doc """
  Return the list of middleware modules that should be active.

  Used by the Agent Config builder to wire up observational middleware.
  """
  @spec middleware_modules() :: [module()]
  def middleware_modules, do: middleware_modules(load())

  @spec middleware_modules(t()) :: [module()]
  def middleware_modules(%__MODULE__{enabled: true}) do
    [
      Handbeam.Agent.Middleware.ObservationalSessionStart,
      Handbeam.Agent.Middleware.ObservationalAfterCompletion,
      Handbeam.Agent.Middleware.ObservationalAfterToolExec
    ]
  end

  def middleware_modules(%__MODULE__{}), do: []

  @doc """
  Resolve the provider module for the Observer.

  Falls back to the agent's provider if `observer_provider` is not set.
  """
  @spec observer_provider(t(), module()) :: module()
  def observer_provider(%__MODULE__{observer_provider: nil}, agent_provider),
    do: agent_provider

  def observer_provider(%__MODULE__{observer_provider: provider}, _agent_provider),
    do: provider

  @doc """
  Resolve the provider module for the Reflector.

  Falls back to the agent's provider if `reflector_provider` is not set.
  """
  @spec reflector_provider(t(), module()) :: module()
  def reflector_provider(%__MODULE__{reflector_provider: nil}, agent_provider),
    do: agent_provider

  def reflector_provider(%__MODULE__{reflector_provider: provider}, _agent_provider),
    do: provider

  # ── Private ──

  defp get_max_recent_context(obs) when is_list(obs) do
    Keyword.get(obs, :max_recent_context, 5)
  end

  defp get_max_recent_context(obs) when is_map(obs) do
    Map.get(obs, :max_recent_context) || Map.get(obs, "max_recent_context", 5)
  end

  defp get_max_recent_context(_), do: 5

  defp maybe_get(data, keys, default \\ nil)

  defp maybe_get(kw, keys, default) when is_list(kw) do
    case keys do
      [key] -> Keyword.get(kw, key, default)
      [key | rest] -> kw |> Keyword.get(key, []) |> maybe_get(rest, default)
    end
  end

  defp maybe_get(kw, keys, default) when is_map(kw) do
    case keys do
      [key] ->
        Map.get(kw, key) || Map.get(kw, to_string(key)) || default

      [key | rest] ->
        inner = Map.get(kw, key) || Map.get(kw, to_string(key)) || %{}
        maybe_get(inner, rest, default)
    end
  end

  # Keep map keys unchanged to avoid creating atoms from external config.
  # Access helpers support both atom and string keys.
  defp normalize_nested(kw) when is_list(kw), do: kw
  defp normalize_nested(kw) when is_map(kw), do: kw

  defp enabled_value(om, default) do
    case value(om, :enabled) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp non_neg_or(om, key, default) do
    case value(om, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end

  defp pos_or(om, key, default) do
    case value(om, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp string_or(om, key, default) do
    case value(om, key) do
      text when is_binary(text) and text != "" -> text
      _ -> default
    end
  end

  defp value(om, key), do: Map.get(om, key, Map.get(om, Atom.to_string(key)))
end
