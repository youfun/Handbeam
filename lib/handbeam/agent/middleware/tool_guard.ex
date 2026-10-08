defmodule Handbeam.Agent.Middleware.ToolGuard do
  @moduledoc """
  Workspace permission guard for tool requests.
  """

  @behaviour Handbeam.Agent.Middleware

  alias Handbeam.Agent.{Message, State}
  alias Handbeam.Permissions.{AutoReview, InterruptData, ToolPolicy}

  @impl true
  def call(:after_tool_request, %State{} = state) do
    state = %{state | tool_guard_denied_calls: [], tool_guard_result_blocks: []}
    tool_calls = last_tool_calls(state)

    policy =
      state.config.working_directory
      |> ToolPolicy.from_workspace(
        state.tool_guard_overrides || %{},
        state.tool_guard_session_allow || []
      )
      |> delegated_policy(state)

    {denied, rest} = Enum.split_with(tool_calls, &(ToolPolicy.decision(policy, &1) == :deny))

    {pending, auto_approved} =
      Enum.split_with(rest, &(ToolPolicy.decision(policy, &1) == :prompt))

    cond do
      pending != [] ->
        review_or_interrupt(state, pending, auto_approved)

      denied != [] ->
        guarded = %{
          state
          | tool_guard_denied_calls: denied,
            tool_guard_result_blocks: Enum.map(denied, &denied_result_block(&1, policy))
        }

        {:tool_guard_denied, guarded}

      true ->
        state
    end
  end

  def call(_hook, %State{} = state), do: state

  # Review runs only after ToolPolicy has already returned :prompt. It never
  # rewrites allow rules or session overrides, and a failed review is the
  # existing human interrupt — not a deny.
  defp review_or_interrupt(state, pending, auto_approved) do
    if auto_review?(state) and not Enum.any?(pending, &(&1[:name] == "computer")) do
      case AutoReview.review(state, pending) do
        {:ok, %State{status: :halted} = reviewed} ->
          {:tool_guard_denied, reviewed}

        {:ok, %State{tool_guard_result_blocks: []} = reviewed} ->
          reviewed

        {:ok, %State{} = reviewed} ->
          {:tool_guard_denied, reviewed}

        {:fallback, %State{} = reviewed, _reason} ->
          interrupt(reviewed, pending, auto_approved)
      end
    else
      interrupt(state, pending, auto_approved)
    end
  end

  defp delegated_policy(policy, %State{} = state) do
    if state.config.context[:delegated_approval] == :yolo,
      do: %{policy | default_mode: :yolo},
      else: policy
  end

  defp auto_review?(%State{} = state) do
    AutoReview.enabled?(state.config.working_directory) or
      state.config.context[:delegated_approval] == :auto_review
  end

  defp interrupt(%{config: %{source: :schedule}} = state, pending, _auto_approved) do
    tool =
      pending
      |> List.first()
      |> then(&Handbeam.Utils.SafeMap.get_first_truthy(&1 || %{}, :name, "name"))
      |> case do
        name when is_binary(name) and name != "" -> name
        _ -> "tool"
      end

    halted = %{state | status: :halted, error: "定时运行不能等待人工批准：#{tool}"}
    {:tool_guard_denied, halted}
  end

  defp interrupt(state, pending, auto_approved) do
    data = InterruptData.build(pending, auto_approved, state.config.working_directory)
    interrupted = %{state | status: :interrupted, interrupt_data: data}
    {:interrupt, interrupted, data}
  end

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

  defp denied_result_block(call, policy) do
    reason =
      if ToolPolicy.sensitive_call?(policy, call) do
        Handbeam.Security.PathValidator.sensitive_reason()
      else
        "Tool call denied by workspace permissions"
      end

    Message.tool_result_block(
      Handbeam.Utils.SafeMap.get_first_truthy(call, :id, "id"),
      reason,
      true,
      %{permission: :denied, tool: Handbeam.Utils.SafeMap.get_first_truthy(call, :name, "name")}
    )
  end
end
