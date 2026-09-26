defmodule Handbeam.Permissions.InterruptData do
  @moduledoc """
  Serializable interrupt payload for tool approval requests.
  """

  alias Handbeam.Permissions.Remember

  @spec build([map()], [map()], Path.t() | nil) :: map()
  def build(pending_calls, auto_approved_calls \\ [], workspace_path \\ nil) do
    %{
      type: :tool_approval,
      action_requests: Enum.map(pending_calls, &action_request/1),
      review_configs:
        Map.new(pending_calls, fn call ->
          {call_id(call), %{allowed_decisions: [:approve, :edit, :reject]}}
        end),
      hitl_tool_call_ids: Enum.map(pending_calls, &call_id/1),
      auto_approved_tool_call_ids: Enum.map(auto_approved_calls, &call_id/1),
      workspace_path: workspace_path
    }
  end

  defp action_request(call) do
    %{
      tool_call_id: call_id(call),
      tool_name: call_name(call),
      arguments: call[:input] || call["input"] || %{},
      suggested_pattern: Remember.pattern(call)
    }
  end

  defp call_id(call), do: call[:id] || call["id"]
  defp call_name(call), do: call[:name] || call["name"]
end
