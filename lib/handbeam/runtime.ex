defmodule Handbeam.Runtime do
  @moduledoc """
  Host-facing hooks into the existing Runner / Transcript owners.

  The host's Stop action (e.g. the Android notification) calls
  `cancel_all_runs/0` from its own process. No extra process here, and no
  named host process is assumed.
  """

  alias Handbeam.Agent.Runner

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

  defp running_conversation_ids do
    Registry.select(Handbeam.AgentRunRegistry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
  catch
    :error, :badarg -> []
  end
end
