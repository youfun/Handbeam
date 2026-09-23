defmodule Handbeam.Tool.Builtin.Advisor do
  @moduledoc """
  On-demand consult tool. It cannot choose a provider, raise the budget, or
  grant tools. Review itself is an internal Delegation request, not this tool.
  """

  @behaviour Handbeam.Agent.Tool

  alias Handbeam.Agent.Advisor, as: Runtime

  @impl true
  def name, do: "advisor"

  @impl true
  def description do
    "Ask the configured read-only Advisor for a judgment. Provide the question, necessary context, relevant files, and the decision you need. The advisor cannot modify files, browse, delegate, or authorize actions."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        question: %{type: "string"},
        context: %{type: "string"},
        paths: %{type: "array", items: %{type: "string"}},
        decision: %{type: "string"}
      },
      required: ["question"],
      additionalProperties: false
    }
  end

  @impl true
  def concurrent?, do: false
  @impl true
  def max_result_chars, do: 24_000
  @impl true
  def timeout_ms, do: Runtime.consult_timeout_ms()

  @impl true
  def execute(%{"question" => question} = input, context)
      when is_binary(question) and byte_size(question) <= 8_000 do
    advisor = context.delegation_config.advisor

    if Runtime.tool_visible?(advisor) do
      consult(input, context, advisor)
    else
      {:error, "Advisor is not configured for this run"}
    end
  end

  def execute(_, _), do: {:error, "question (max 8000 bytes) is required"}

  defp consult(input, context, _advisor) do
    prompt = """
    Question:
    #{input["question"]}

    Context:
    #{input["context"]}

    Paths:
    #{Enum.join(List.wrap(input["paths"]), "\n")}

    Decision requested:
    #{input["decision"]}
    """

    request_id = "advisor-consult-" <> Ecto.UUID.generate()

    delegation_context =
      Map.merge(context, %{
        profile: :advisor,
        advisor_kind: :consult,
        advisor_request_id: request_id,
        tool_call_id: context[:tool_call_id]
      })

    case Handbeam.Agent.Delegation.run(%{"prompt" => prompt}, delegation_context, :advisor) do
      {:ok, text, data} ->
        {:ok, text, Map.put(data, :profile, :advisor)}

      {:error, reason, data} ->
        {:error, inspect(reason), Map.put(data || %{}, :profile, :advisor)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
