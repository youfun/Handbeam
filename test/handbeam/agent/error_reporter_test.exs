defmodule Handbeam.Agent.ErrorReporterTest do
  use Handbeam.DataCase, async: false

  alias ErrorTracker.{Error, Occurrence}
  alias Handbeam.Agent.ErrorReporter

  setup do
    previous = Application.get_env(:error_tracker, :enabled)
    Application.put_env(:error_tracker, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:error_tracker, :enabled),
        else: Application.put_env(:error_tracker, :enabled, previous)
    end)

    :ok
  end

  test "separates gateway failures and strips configured credentials" do
    context = %{
      "source" => "agent_runner",
      "conversation_id" => "conversation-1",
      "run_id" => "run-1",
      "model" => "model-1"
    }

    assert :ok =
             ErrorReporter.report(
               {:server_is_overloaded, "Bearer bearer-secret", "api-key-secret"},
               context,
               provider_config: %{
                 provider: "gateway-a",
                 base_url: "https://a.gateway.test/v1?token=query-secret",
                 api_key: "api-key-secret"
               }
             )

    assert :ok =
             ErrorReporter.report(:server_is_overloaded, context,
               provider_config: %{
                 provider: "gateway-b",
                 base_url: "https://b.gateway.test/v1"
               }
             )

    errors = Repo.all(from(error in Error, order_by: error.source_line))

    assert Enum.map(errors, & &1.source_line) == [
             "agent://a.gateway.test:0",
             "agent://b.gateway.test:0"
           ]

    assert Enum.all?(errors, &String.ends_with?(&1.kind, "Agent.ErrorReporter.AgentRunError"))

    occurrences = Repo.all(from(occurrence in Occurrence, order_by: occurrence.id))

    assert Enum.map(occurrences, & &1.context["gateway_host"]) == [
             "a.gateway.test",
             "b.gateway.test"
           ]

    assert Enum.all?(occurrences, &(&1.context["failure_class"] == "provider_overloaded"))

    recorded = inspect({errors, occurrences})
    refute recorded =~ "bearer-secret"
    refute recorded =~ "api-key-secret"
    refute recorded =~ "query-secret"
  end
end
