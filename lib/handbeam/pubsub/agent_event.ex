defmodule Handbeam.PubSub.AgentEvent do
  @moduledoc """
  Agent event struct — emitted during the agent loop.

  All events carry a monotonically increasing `seq` number for ordering.
  Single topic per session prevents cross-topic ordering issues.
  """

  defstruct [:seq, :topic, :kind, :payload, :ts_ms]

  @type kind ::
          :message_delta
          | :thinking_delta
          | :usage_updated
          | :tool_start
          | :tool_end
          | :session_state
          | :run_start
          | :run_end

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          topic: String.t(),
          kind: kind(),
          payload: map(),
          ts_ms: integer()
        }

  @doc """
  Create a new event with auto-incrementing sequence.
  """
  @spec new(String.t(), kind(), map(), non_neg_integer()) :: t()
  def new(topic, kind, payload, seq) do
    %__MODULE__{
      topic: topic,
      kind: kind,
      payload: payload,
      seq: seq,
      ts_ms: System.os_time(:millisecond)
    }
  end

  @doc "Create a message delta event (streaming chunk)."
  def message_delta(topic, chunk, seq) do
    new(topic, :message_delta, %{chunk: chunk}, seq)
  end

  @doc "Create a tool start event."
  def tool_start(topic, tool_name, input, seq) do
    new(topic, :tool_start, %{tool: tool_name, input: input}, seq)
  end

  @doc "Create a tool end event."
  def tool_end(topic, tool_name, duration_ms, error, seq) do
    new(topic, :tool_end, %{tool: tool_name, duration_ms: duration_ms, error: error}, seq)
  end

  @doc "Create a run start event."
  def run_start(topic, model, prompt, seq) do
    new(topic, :run_start, %{model: model, prompt: prompt}, seq)
  end

  @doc "Create a run end event."
  def run_end(topic, status, turns, seq) do
    new(topic, :run_end, %{status: status, turns: turns}, seq)
  end
end
