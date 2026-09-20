defmodule Handbeam.Tool.Builtin.Task do
  @moduledoc "Synchronous, bounded, read-only delegation."
  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "task"
  @impl true
  def description do
    "Delegate a short read-only investigation with independent context. Supply task context and completion criteria; parent history is not copied. Uses at most min(45s, tool timeout / 2), including startup. Returns an unverified report with evidence and usage, or explicit partial/failure status. No writing, recursion, approvals, or background continuation."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{task: %{type: "string"}, criteria: %{type: "string"}},
      required: ["task", "criteria"],
      additionalProperties: false
    }
  end

  @impl true
  def concurrent?, do: false
  @impl true
  def max_result_chars, do: 24_000
  @impl true
  def execute(%{"task" => task, "criteria" => criteria} = input, context)
      when is_binary(task) and is_binary(criteria) and byte_size(task) <= 16_000 and
             byte_size(criteria) <= 4_000 do
    if String.trim(task) == "" or String.trim(criteria) == "" do
      {:error, "task and criteria must be non-empty"}
    else
      Handbeam.Agent.Delegation.run(input, context)
    end
  end

  def execute(_, _),
    do: {:error, "task (max 16000 bytes) and criteria (max 4000 bytes) are required"}
end
