defmodule Handbeam.Agent.ReasoningTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.Reasoning

  describe "supported_levels/1" do
    test "returns an empty list for non-reasoning models" do
      assert Reasoning.supported_levels(%{reasoning: false}) == []
    end

    test "infers Step Router / StepFun models when the flag is omitted" do
      levels = Reasoning.supported_levels(%{id: "step-router-v1", name: "Step Router v1"})

      assert "off" in levels
      assert "medium" in levels
      assert "high" in levels
    end

    test "infers provider_id stepfun when the flag is omitted" do
      levels = Reasoning.supported_levels(%{provider_id: "stepfun-anthropic", model_id: "other"})
      assert "medium" in levels
    end

    test "includes off and hides levels mapped to nil" do
      model = %{
        reasoning: true,
        thinking_level_map: %{
          "minimal" => "low",
          "low" => nil,
          "medium" => "medium",
          "high" => "high",
          "xhigh" => nil
        }
      }

      assert Reasoning.supported_levels(model) == ["off", "minimal", "medium", "high"]
    end
  end

  describe "default_level/1" do
    test "uses model default when supported" do
      assert Reasoning.default_level(%{reasoning: true, default_reasoning: "high"}) == "high"
    end

    test "falls back to medium for reasoning models" do
      assert Reasoning.default_level(%{reasoning: true}) == "medium"
    end

    test "returns off for non-reasoning models" do
      assert Reasoning.default_level(%{reasoning: false}) == "off"
    end
  end

  describe "resolve/2" do
    test "maps xhigh to high unless explicitly overridden" do
      assert Reasoning.resolve(%{reasoning: true}, "xhigh") == {:ok, "high"}

      assert Reasoning.resolve(
               %{reasoning: true, thinking_level_map: %{"xhigh" => "max"}},
               "xhigh"
             ) == {:ok, "max"}
    end

    test "returns :off for off" do
      assert Reasoning.resolve(%{reasoning: true}, "off") == :off
    end
  end

  describe "apply_provider_options/3" do
    test "does not mutate config for off" do
      config = %{api: :openai_responses, model: "gpt-5.4"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "off") == config
    end

    test "adds OpenAI Responses reasoning effort" do
      config = %{api: :openai_responses, model: "gpt-5.4"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "high") ==
               %{api: :openai_responses, model: "gpt-5.4", reasoning: %{effort: "high"}}
    end

    test "adds OpenAI-compatible reasoning_effort" do
      config = %{api: :openai, model: "gpt-5.4"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "medium") ==
               %{api: :openai, model: "gpt-5.4", reasoning_effort: "medium"}
    end

    test "adds DeepSeek thinking fields" do
      config = %{provider: "deepseek", model: "deepseek-v4-pro"}

      assert Reasoning.apply_provider_options(config, %{reasoning: true}, "high") ==
               %{
                 provider: "deepseek",
                 model: "deepseek-v4-pro",
                 thinking: %{type: "enabled"},
                 reasoning_effort: "high"
               }
    end
  end
end
