defmodule Handbeam.Agent.StateUsageTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.{Config, Message, State}

  test "unknown usage survives merge through Turn-shaped state" do
    config = Config.from_opts(provider: Handbeam.Agent.Provider.OpenAICompat, model: "x")
    state = State.init(config, Message.user("hi"))

    state = State.merge_usage(state, %{input_tokens: 0, output_tokens: 3, unknown?: true})
    state = State.merge_usage(state, %{input_tokens: 0, output_tokens: 0, unknown?: true})

    assert state.usage.unknown? == true
    assert state.usage.output_tokens == 3
  end
end
