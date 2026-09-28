defmodule Handbeam.Agent.CliAgentTest.FakeBackend do
  @moduledoc false
  @behaviour Handbeam.Agent.CliAgent

  alias Handbeam.Agent.CliAgent.Session

  @impl true
  def id, do: "fake-cli"

  @impl true
  def available?, do: true

  @impl true
  def list_models(_opts) do
    {:ok, [%{id: "fake-model", display_name: "Fake", reasoning_levels: ["low"]}]}
  end

  @impl true
  def start_session(opts) do
    session_id = Keyword.get(opts, :session_id) || "fake-new"

    {:ok,
     %Session{
       backend: id(),
       cwd: Keyword.get(opts, :cwd, "."),
       session_id: session_id,
       private: %{resumed: Keyword.get(opts, :session_id)}
     }}
  end

  @impl true
  def send_message(session, text, on_event) do
    if pid = Application.get_env(:handbeam, :fake_cli_notify),
      do: send(pid, {:fake_cli_turn, text, session})

    if String.contains?(text, "need-permission") and is_nil(session.private[:decision]) do
      request =
        {:permission_request,
         %{
           id: "perm-1",
           tools: [%{name: "Edit", id: "t1"}],
           options: [
             %{"label" => "Once", "value" => "proceed_once"},
             %{"label" => "Cancel", "value" => "cancel"}
           ]
         }}

      on_event.(request)
      {:ok, session, [request]}
    else
      send_text(session, on_event)
    end
  end

  defp send_text(session, on_event) do
    event = {:text_delta, "fake"}
    on_event.(event)
    done = {:turn_end, %{stop_reason: :end_turn, session_id: session.session_id}}
    on_event.(done)
    {:ok, session, [event, done]}
  end

  @impl true
  def interrupt(%Session{}), do: :ok

  @impl true
  def update_model(session, _opts), do: {:ok, session}

  @impl true
  def stop_session(%Session{}), do: :ok
end
