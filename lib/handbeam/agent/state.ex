defmodule Handbeam.Agent.State do
  @moduledoc """
  Agent state — holds messages, turn counter, and execution status.

  Immutable struct passed through the agent loop as a pure data value.
  """

  alias Handbeam.Agent.Config
  alias Handbeam.Agent.Message

  defstruct [
    :config,
    :messages,
    :turn,
    :status,
    :error,
    :usage,
    :tool_calls,
    :provider_state,
    :response_metadata,
    :run_metadata,
    :provider_response_metadata,
    :tool_guard_overrides,
    :interrupt_data,
    :tool_guard_denied_calls,
    :tool_guard_result_blocks
  ]

  @type status ::
          :running | :completed | :error | :max_turns | :budget_exceeded | :halted | :interrupted

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: [Message.t()],
          turn: non_neg_integer(),
          status: status(),
          error: String.t() | nil,
          usage: map(),
          tool_calls: [map()],
          provider_state: map(),
          response_metadata: map(),
          run_metadata: map(),
          provider_response_metadata: map(),
          tool_guard_overrides: map(),
          interrupt_data: map() | nil,
          tool_guard_denied_calls: [map()],
          tool_guard_result_blocks: [map()]
        }

  @doc "Create initial state from config and user prompt."
  @spec init(Config.t(), String.t() | Message.t()) :: t()
  def init(%Config{} = config, %Message{} = prompt) do
    new(config, [prompt])
  end

  def init(%Config{} = config, prompt) when is_binary(prompt) do
    new(config, [Message.user(prompt)])
  end

  def init(%Config{} = config, prompts) when is_list(prompts) do
    new(config, prompts)
  end

  defp new(%Config{} = config, messages) do
    %__MODULE__{
      config: config,
      messages: messages,
      turn: 0,
      status: :running,
      error: nil,
      usage: %{input_tokens: 0, output_tokens: 0},
      tool_calls: [],
      provider_state: %{},
      response_metadata: %{},
      run_metadata: %{},
      provider_response_metadata: %{},
      tool_guard_overrides: %{},
      interrupt_data: nil,
      tool_guard_denied_calls: [],
      tool_guard_result_blocks: []
    }
  end

  @doc "Append messages to the conversation history."
  @spec append_messages(t(), [Message.t()]) :: t()
  def append_messages(%__MODULE__{} = state, messages) do
    %{state | messages: state.messages ++ List.wrap(messages)}
  end

  @doc "Increment the turn counter."
  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{} = state) do
    %{state | turn: state.turn + 1}
  end

  @doc "Merge usage stats into cumulative totals."
  @spec merge_usage(t(), map()) :: t()
  def merge_usage(%__MODULE__{} = state, usage) when is_map(usage) do
    merged = %{
      input_tokens: (state.usage[:input_tokens] || 0) + (usage[:input_tokens] || 0),
      output_tokens: (state.usage[:output_tokens] || 0) + (usage[:output_tokens] || 0),
      cache_read_input_tokens:
        (state.usage[:cache_read_input_tokens] || 0) +
          (usage[:cache_read_input_tokens] || 0),
      cache_creation_input_tokens:
        (state.usage[:cache_creation_input_tokens] || 0) +
          (usage[:cache_creation_input_tokens] || 0)
    }

    %{state | usage: Map.merge(state.usage, merged)}
  end

  @doc "Merge provider state for the next turn."
  @spec merge_provider_state(t(), map()) :: t()
  def merge_provider_state(%__MODULE__{} = state, provider_state) when is_map(provider_state) do
    %{state | provider_state: Map.merge(state.provider_state, provider_state)}
  end

  @doc "Store provider response metadata."
  @spec put_provider_response_metadata(t(), map()) :: t()
  def put_provider_response_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | provider_response_metadata: metadata}
  end

  @doc "Append tool call metadata."
  @spec append_tool_calls(t(), [map()]) :: t()
  def append_tool_calls(%__MODULE__{} = state, calls) do
    %{state | tool_calls: state.tool_calls ++ calls}
  end

  @doc "Merge run metadata."
  @spec merge_run_metadata(t(), map()) :: t()
  def merge_run_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | run_metadata: Map.merge(state.run_metadata, metadata)}
  end

  @doc "Return all messages in the conversation."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{} = state), do: state.messages

  @doc "Materialize final state — freeze for external consumption."
  @spec materialize(t()) :: t()
  def materialize(%__MODULE__{} = state), do: state
end
