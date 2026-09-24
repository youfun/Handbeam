defmodule Handbeam.Tool.Builtin.TaskStatus do
  @moduledoc "Inspect and steer subagents started by the current conversation."
  @behaviour Handbeam.Agent.Tool

  alias Handbeam.Agent.Delegation

  @actions ~w(list get cancel message apply discard)

  @impl true
  def name, do: "task_status"

  @impl true
  def description do
    "Manage subagents started with task in this conversation. " <>
      "list: all subagents and their status. get: one subagent's status and latest report. " <>
      "cancel: stop a running subagent. message: send the subagent a message; a running " <>
      "subagent receives it as a steer, a finished one starts a follow-up run and its reply " <>
      "arrives later as a follow-up message. apply / discard: take or drop a write " <>
      "subagent's worktree diff (apply needs approval). child_conversation_id may also be a " <>
      "subagent_type, meaning the most recent subagent of that type."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        action: %{type: "string", enum: @actions},
        child_conversation_id: %{type: "string"},
        message: %{type: "string"}
      },
      required: ["action"],
      additionalProperties: false
    }
  end

  @impl true
  def concurrent?, do: true
  @impl true
  def max_result_chars, do: 24_000

  @impl true
  def execute(%{"action" => action} = input, context) when action in @actions do
    parent = context[:conversation_id]
    child = input["child_conversation_id"]

    cond do
      not is_binary(parent) ->
        {:error, "task_status requires a conversation"}

      action != "list" and not is_binary(child) ->
        {:error, "child_conversation_id is required for #{action}"}

      true ->
        dispatch(action, parent, child, input) |> render()
    end
  end

  def execute(_, _), do: {:error, "action must be one of #{Enum.join(@actions, ", ")}"}

  defp dispatch("list", parent, _child, _input), do: Delegation.status(parent, :list)
  defp dispatch("get", parent, child, _input), do: Delegation.status(parent, :get, child)
  defp dispatch("cancel", parent, child, _input), do: Delegation.status(parent, :cancel, child)
  defp dispatch("apply", parent, child, _input), do: Delegation.worktree(parent, :apply, child)

  defp dispatch("discard", parent, child, _input),
    do: Delegation.worktree(parent, :discard, child)

  defp dispatch("message", parent, child, %{"message" => text})
       when is_binary(text) and byte_size(text) <= 16_000 do
    Delegation.message(parent, child, text, forward_to_parent: true, source: :delegation)
  end

  defp dispatch("message", _parent, _child, _input),
    do: {:error, "message (max 16000 bytes) is required"}

  defp render(:ok), do: {:ok, "ok"}
  defp render({:ok, stat}) when is_binary(stat), do: {:ok, "Applied worktree diff:\n" <> stat}
  defp render({:ok, data}), do: {:ok, Handbeam.JSON.encode!(data), %{subagents: data}}
  defp render({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp render({:error, reason}), do: {:error, inspect(reason)}
end
