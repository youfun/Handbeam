defmodule Handbeam.Tool.Builtin.JobStatus do
  @moduledoc "Scoped job queries and bounded recovery of handles whose launch reply was lost."
  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "job_status"
  @impl true
  def description do
    "Query a Bash or BEAM job's state and bounded output using its byte cursor. Omit job_id to " <>
      "recover up to 32 handles in this conversation/workspace. Wait is capped at 5s and " <>
      "half the tool timeout. Query completion before ending the run; unfinished jobs are " <>
      "cancelled at run end. Later runs can inspect retained results, not resume execution. " <>
      "cancelling with cleanup_error means termination is not yet confirmed."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        job_id: %{type: "string"},
        cursor: %{type: "integer", minimum: 0, default: 0},
        wait_ms: %{type: "integer", minimum: 0, default: 1_000}
      }
    }
  end

  @impl true
  def concurrent?, do: true
  @impl true
  def max_result_chars, do: 105_000
  @impl true
  def execute(input, context) do
    Handbeam.Jobs.status(
      input["job_id"],
      Map.get(input, "cursor", 0),
      Map.get(input, "wait_ms", 1_000),
      context
    )
    |> Handbeam.Jobs.format()
  end
end
