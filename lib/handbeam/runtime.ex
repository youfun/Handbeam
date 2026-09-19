defmodule Handbeam.Runtime do
  @moduledoc """
  Host-facing hooks into the existing Runner / Transcript owners.

  The host's Stop action (e.g. the Android notification) calls
  `cancel_all_runs/0` from its own process. No extra process here, and no
  named host process is assumed.
  """

  alias Handbeam.Agent.Runner
  alias Handbeam.PubSub.Session

  @spec configure_notify_adapter() :: :ok
  def configure_notify_adapter do
    if Handbeam.Host.configured?() and not Handbeam.Host.shell?() do
      Application.put_env(:handbeam, :runtime_notify_adapter, Handbeam.Runtime.AndroidNotify)
    end

    :ok
  end

  @spec cancel_all_runs() :: :ok
  def cancel_all_runs do
    Enum.each(running_conversation_ids(), &Runner.cancel/1)
    :ok
  end

  @spec mark_interrupted_runs() :: :ok
  def mark_interrupted_runs do
    Enum.each(stale_running_ids(), fn id ->
      Session.broadcast_event(id, :run_end, %{status: "interrupted", turns: 0})
      Session.mark_run_finished(id)
    end)

    :ok
  end

  defp running_conversation_ids do
    Registry.select(Handbeam.AgentRunRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
  catch
    :error, :badarg -> []
  end

  defp stale_running_ids do
    case Process.whereis(Handbeam.SessionRegistry) do
      nil ->
        []

      _pid ->
        Registry.select(Handbeam.SessionRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
        |> Enum.filter(fn id ->
          case Session.snapshot(id) do
            %{"meta" => %{"running?" => true}} -> true
            %{meta: %{running?: true}} -> true
            _ -> false
          end
        end)
    end
  catch
    :error, :badarg -> []
  end
end
