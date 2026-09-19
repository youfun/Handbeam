defmodule Handbeam.Agent.Middleware.ToolGuard do
  @moduledoc """
  Workspace permission guard for tool requests.
  """

  @behaviour Handbeam.Agent.Middleware

  alias Handbeam.Agent.{Message, State}
  alias Handbeam.Permissions.{InterruptData, ToolPolicy}

  @impl true
  def call(:after_tool_request, %State{} = state) do
    tool_calls = last_tool_calls(state)

    policy =
      state.config.working_directory
      |> ToolPolicy.from_workspace(state.tool_guard_overrides || %{})

    {denied, rest} = Enum.split_with(tool_calls, &(ToolPolicy.decision(policy, &1) == :deny))

    {pending, auto_approved} =
      Enum.split_with(rest, &(ToolPolicy.decision(policy, &1) == :prompt))

    cond do
      pending != [] ->
        data = InterruptData.build(pending, auto_approved, state.config.working_directory)
        interrupted = %{state | status: :interrupted, interrupt_data: data}
        {:interrupt, interrupted, data}

      denied != [] ->
        guarded = %{
          state
          | tool_guard_denied_calls: denied,
            tool_guard_result_blocks: Enum.map(denied, &denied_result_block/1)
        }

        {:tool_guard_denied, guarded}

      true ->
        state
    end
  end

  def call(_hook, %State{} = state), do: state

  defp last_tool_calls(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %Message{role: :assistant} = message ->
        case Message.tool_calls(message) do
          [] -> nil
          calls -> calls
        end

      _ ->
        nil
    end)
  end

  defp denied_result_block(call) do
    Message.tool_result_block(
      call[:id] || call["id"],
      "Tool call denied by workspace permissions",
      true,
      %{permission: :denied, tool: call[:name] || call["name"]}
    )
  end
end
