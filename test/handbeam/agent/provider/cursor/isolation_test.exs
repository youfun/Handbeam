defmodule Handbeam.Agent.Provider.Cursor.IsolationTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.Config
  alias Handbeam.Agent.Provider.Cursor

  test "config maps cursor provider to the Cursor module" do
    assert Config.resolve_provider_from_api(:cursor_agent, "composer-2.5", "cursor") == Cursor

    assert Config.resolve_provider_from_api(:openai_responses, "grok-4.6", "openai") ==
             Handbeam.Agent.Provider.OpenAI
  end

  test "xAI oauth still resolves independently from Cursor" do
    assert Config.resolve_provider_from_api(:openai_responses, "grok-4.6", "xai") ==
             Handbeam.Agent.Provider.OpenAI
  end
end
