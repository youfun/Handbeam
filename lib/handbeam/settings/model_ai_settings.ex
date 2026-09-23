defmodule Handbeam.Settings.ModelAISettings do
  @moduledoc """
  Model / AI settings schema — defaults, validation, serialisation.

  Stored in global `~/.handbeam/settings.json` and/or workspace
  `.handbeam/settings.jsonc` under the `model_ai` key.

  This module is backend configuration, not LiveView UI logic.
  """

  @fields ~w(
    default_model reasoning om_enabled om_observer_model om_reflector_model
    om_memory_scope om_privacy_mode om_max_recent_context
    om_message_tokens om_buffer_tokens om_observation_tokens
  )a

  @atom_keys Map.new(@fields, &{Atom.to_string(&1), &1})

  defstruct [
    :default_model,
    reasoning: "medium",
    om_enabled: false,
    om_observer_model: nil,
    om_reflector_model: nil,
    om_memory_scope: "workspace",
    om_privacy_mode: "standard",
    om_max_recent_context: 5,
    om_message_tokens: 30_000,
    om_buffer_tokens: 10_000,
    om_observation_tokens: 40_000
  ]

  @type t :: %__MODULE__{
          default_model: String.t() | nil,
          reasoning: String.t(),
          om_enabled: boolean(),
          om_observer_model: String.t() | nil,
          om_reflector_model: String.t() | nil,
          om_memory_scope: String.t(),
          om_privacy_mode: String.t(),
          om_max_recent_context: non_neg_integer(),
          om_message_tokens: pos_integer(),
          om_buffer_tokens: pos_integer(),
          om_observation_tokens: pos_integer()
        }

  @doc "Return the default settings struct."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc "Build full effective settings from a JSON-decoded map."
  @spec new(map()) :: t()
  def new(nil), do: defaults()

  def new(%{} = map) do
    base = defaults()
    override = normalize_override(map)

    merge_map =
      for field <- @fields, into: %{} do
        {field, Map.get(override, field, Map.get(base, field))}
      end

    struct!(__MODULE__, merge_map)
  end

  @doc "Normalize a partial settings map without filling defaults."
  @spec normalize_override(map()) :: map()
  def normalize_override(%{} = map) do
    om_map = get_key(map, "observational_memory") || %{}

    %{}
    |> maybe_put(:default_model, raw_string(map, "default_model"))
    |> maybe_put(:reasoning, raw_string(map, "reasoning"))
    |> maybe_put(:om_enabled, raw_bool_present(om_map, "enabled", map, "om_enabled"))
    |> maybe_put(
      :om_observer_model,
      raw_string(om_map, "observer_model") || raw_string(map, "om_observer_model")
    )
    |> maybe_put(
      :om_reflector_model,
      raw_string(om_map, "reflector_model") || raw_string(map, "om_reflector_model")
    )
    |> maybe_put(
      :om_memory_scope,
      raw_string(om_map, "memory_scope") || raw_string(map, "om_memory_scope")
    )
    |> maybe_put(
      :om_privacy_mode,
      raw_string(om_map, "privacy_mode") || raw_string(map, "om_privacy_mode")
    )
    |> maybe_put(
      :om_max_recent_context,
      raw_int(om_map, "max_recent_context") || raw_int(map, "om_max_recent_context")
    )
    |> maybe_put(
      :om_message_tokens,
      raw_int(om_map, "message_tokens") || raw_int(map, "om_message_tokens")
    )
    |> maybe_put(
      :om_buffer_tokens,
      raw_int(om_map, "buffer_tokens") || raw_int(map, "om_buffer_tokens")
    )
    |> maybe_put(
      :om_observation_tokens,
      raw_int(om_map, "observation_tokens") || raw_int(map, "om_observation_tokens")
    )
  end

  @doc "Convert settings into the keyword opts expected by Coordinator.add_message/3."
  @spec to_runtime_opts(t()) :: keyword()
  def to_runtime_opts(%__MODULE__{} = settings) do
    opts = []

    opts =
      if settings.default_model, do: Keyword.put(opts, :model, settings.default_model), else: opts

    opts =
      if settings.reasoning,
        do: Keyword.put(opts, :reasoning_level, settings.reasoning),
        else: opts

    om_map = %{
      enabled: settings.om_enabled,
      observer_model: settings.om_observer_model || settings.default_model,
      reflector_model: settings.om_reflector_model,
      memory_scope: settings.om_memory_scope,
      privacy_mode: settings.om_privacy_mode,
      max_recent_context: settings.om_max_recent_context,
      message_tokens: settings.om_message_tokens,
      buffer_tokens: settings.om_buffer_tokens,
      observation_tokens: settings.om_observation_tokens
    }

    Keyword.put(opts, :om, om_map)
  end

  @doc "Serialise to a JSON-safe map (string keys, canonical nested OM structure)."
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = settings) do
    defaults()
    |> diff(settings)
    |> override_to_json_map()
  end

  @doc "Convert a partial override map with atom keys to JSON-safe storage shape."
  @spec override_to_json_map(map()) :: map()
  def override_to_json_map(%{} = override) do
    map = %{}

    map = put_if_present(map, override, :default_model, "default_model")
    map = put_if_present(map, override, :reasoning, "reasoning")

    om_map = %{}
    om_map = put_if_present(om_map, override, :om_enabled, "enabled")
    om_map = put_if_present(om_map, override, :om_observer_model, "observer_model")
    om_map = put_if_present(om_map, override, :om_reflector_model, "reflector_model")
    om_map = put_if_present(om_map, override, :om_memory_scope, "memory_scope")
    om_map = put_if_present(om_map, override, :om_privacy_mode, "privacy_mode")
    om_map = put_if_present(om_map, override, :om_max_recent_context, "max_recent_context")
    om_map = put_if_present(om_map, override, :om_message_tokens, "message_tokens")
    om_map = put_if_present(om_map, override, :om_buffer_tokens, "buffer_tokens")
    om_map = put_if_present(om_map, override, :om_observation_tokens, "observation_tokens")

    if map_size(om_map) > 0, do: Map.put(map, "observational_memory", om_map), else: map
  end

  @doc "Return atom-keyed fields in `override` that differ from `base`."
  @spec diff(t(), t()) :: map()
  def diff(%__MODULE__{} = base, %__MODULE__{} = override) do
    @fields
    |> Enum.reduce(%{}, fn field, acc ->
      base_val = Map.get(base, field)
      override_val = Map.get(override, field)

      if override_val != base_val, do: Map.put(acc, field, override_val), else: acc
    end)
  end

  @doc "Merge a base settings struct with an atom-keyed partial override map."
  @spec merge(t(), map() | t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override),
    do: merge(base, Map.from_struct(override))

  def merge(%__MODULE__{} = base, %{} = override) do
    merge_map =
      for field <- @fields, into: %{} do
        {field, Map.get(override, field, Map.get(base, field))}
      end

    struct!(__MODULE__, merge_map)
  end

  @doc "Validate a map of settings changes (partial form input)."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{} = map) do
    with :ok <- validate_privacy_mode(map),
         :ok <- validate_memory_scope(map),
         :ok <- validate_max_recent_context(map),
         :ok <- validate_token_thresholds(map) do
      :ok
    end
  end

  def fields, do: @fields

  # ── Private helpers ──

  defp get_key(map, key) do
    Map.get(map, key) || Map.get(map, Map.get(@atom_keys, key))
  end

  defp raw_string(map, key) do
    case get_key(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp raw_bool_present(primary, primary_key, fallback, fallback_key) do
    case get_key(primary, primary_key) do
      v when is_boolean(v) ->
        v

      _ ->
        case get_key(fallback, fallback_key) do
          v when is_boolean(v) -> v
          _ -> :not_present
        end
    end
  end

  defp raw_int(map, key) do
    case get_key(map, key) do
      v when is_integer(v) -> v
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, :not_present), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_if_present(json, override, atom_key, json_key) do
    if Map.has_key?(override, atom_key),
      do: Map.put(json, json_key, Map.get(override, atom_key)),
      else: json
  end

  defp validate_privacy_mode(map) do
    val = get_key(map, "om_privacy_mode") || nested_om_value(map, "privacy_mode")

    if is_nil(val) || val in ~w(standard local_only),
      do: :ok,
      else: {:error, "om_privacy_mode must be 'standard' or 'local_only'"}
  end

  defp validate_memory_scope(map) do
    val = get_key(map, "om_memory_scope") || nested_om_value(map, "memory_scope")

    if is_nil(val) || val in ~w(workspace global both),
      do: :ok,
      else: {:error, "om_memory_scope must be 'workspace', 'global', or 'both'"}
  end

  defp validate_max_recent_context(map) do
    val = get_key(map, "om_max_recent_context") || nested_om_value(map, "max_recent_context")

    if is_nil(val) || (is_integer(val) && val >= 0),
      do: :ok,
      else: {:error, "om_max_recent_context must be >= 0"}
  end

  defp validate_token_thresholds(map) do
    for {flat_key, nested_key, label} <- [
          {"om_message_tokens", "message_tokens", "om_message_tokens"},
          {"om_buffer_tokens", "buffer_tokens", "om_buffer_tokens"},
          {"om_observation_tokens", "observation_tokens", "om_observation_tokens"}
        ] do
      val = get_key(map, flat_key) || nested_om_value(map, nested_key)

      if not is_nil(val) and (not is_integer(val) || val <= 0),
        do: throw({:error, "#{label} must be > 0"})
    end

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end

  defp nested_om_value(map, key) do
    case get_key(map, "observational_memory") do
      %{} = om -> Map.get(om, key) || Map.get(om, String.to_existing_atom(key))
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
