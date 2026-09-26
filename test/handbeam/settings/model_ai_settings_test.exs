defmodule Handbeam.Settings.ModelAISettingsTest do
  use ExUnit.Case, async: true

  alias Handbeam.Settings.ModelAISettings

  describe "defaults/0" do
    test "returns sensible default values" do
      defaults = ModelAISettings.defaults()

      assert defaults.default_model == nil
      assert defaults.reasoning == "medium"
      assert defaults.om_enabled == false
      assert defaults.om_observer_model == nil
      assert defaults.om_reflector_model == nil
      assert defaults.om_memory_scope == "workspace"
      assert defaults.om_privacy_mode == "standard"
      assert defaults.om_max_recent_context == 5
      assert defaults.om_message_tokens == 30_000
      assert defaults.om_buffer_tokens == 10_000
      assert defaults.om_observation_tokens == 40_000
    end
  end

  describe "new/1 with empty map" do
    test "returns defaults" do
      settings = ModelAISettings.new(%{})
      assert settings == ModelAISettings.defaults()
    end
  end

  describe "new/1 with valid partial overrides" do
    test "overrides only specified fields" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "stepfun/step-router-v1",
          "reasoning" => "medium",
          "om_enabled" => true,
          "om_memory_scope" => "both"
        })

      assert settings.default_model == "stepfun/step-router-v1"
      assert settings.reasoning == "medium"
      assert settings.om_enabled == true
      assert settings.om_memory_scope == "both"
      # Unspecified fields stay at defaults
      assert settings.om_observer_model == nil
      assert settings.om_privacy_mode == "standard"
    end
  end

  describe "new/1 normalizes string keys" do
    test "handles map with all string keys" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "reasoning" => "high",
          "observational_memory" => %{
            "enabled" => true,
            "observer_model" => "claude-opus",
            "memory_scope" => "global"
          }
        })

      assert settings.default_model == "claude-sonnet-4"
      assert settings.reasoning == "high"
      assert settings.om_enabled == true
      assert settings.om_observer_model == "claude-opus"
      assert settings.om_memory_scope == "global"
    end
  end

  describe "to_runtime_opts/1" do
    test "default medium and explicit off survive runtime conversion" do
      for level <- ["medium", "off", "high"] do
        settings =
          if level == "medium",
            do: ModelAISettings.new(%{}),
            else: ModelAISettings.new(%{"reasoning" => level})

        opts = ModelAISettings.to_runtime_opts(settings)
        assert opts[:reasoning_level] == level
        assert Handbeam.Agent.Config.from_opts(opts).reasoning_level == level
        assert ModelAISettings.new(ModelAISettings.to_json_map(settings)).reasoning == level
      end

      assert Handbeam.Agent.Config.from_opts([]).reasoning_level == "medium"
    end

    test "converts to Coordinator-ready keyword opts" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "stepfun/step-router-v1",
          "reasoning" => "medium",
          "om_enabled" => true,
          "om_observer_model" => "claude-opus"
        })

      opts = ModelAISettings.to_runtime_opts(settings)

      assert Keyword.get(opts, :model) == "stepfun/step-router-v1"
      assert Keyword.get(opts, :reasoning_level) == "medium"

      om = Keyword.get(opts, :om)
      assert om[:enabled] == true
      assert om[:observer_model] == "claude-opus"
    end

    test "om is nil when disabled" do
      settings =
        ModelAISettings.new(%{
          "om_enabled" => false
        })

      opts = ModelAISettings.to_runtime_opts(settings)

      om = Keyword.get(opts, :om)
      assert om[:enabled] == false
    end

    test "model is nil when not set" do
      settings = ModelAISettings.defaults()
      opts = ModelAISettings.to_runtime_opts(settings)
      assert Keyword.get(opts, :model) == nil
    end

    test "observer_model falls back to default_model when not set" do
      settings =
        ModelAISettings.new(%{
          "default_model" => "stepfun/step-router-v1",
          "om_enabled" => true
        })

      opts = ModelAISettings.to_runtime_opts(settings)
      om = Keyword.get(opts, :om)
      assert om[:observer_model] == "stepfun/step-router-v1"
    end

    test "observer_model is nil when both are nil" do
      settings =
        ModelAISettings.new(%{
          "om_enabled" => true
        })

      opts = ModelAISettings.to_runtime_opts(settings)
      om = Keyword.get(opts, :om)
      assert om[:observer_model] == nil
    end
  end

  describe "to_json_map/1" do
    test "round-trips through new/1" do
      original =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "reasoning" => "medium",
          "om_enabled" => true
        })

      json_map = ModelAISettings.to_json_map(original)
      reloaded = ModelAISettings.new(json_map)

      assert reloaded.default_model == original.default_model
      assert reloaded.reasoning == original.reasoning
      assert reloaded.om_enabled == original.om_enabled
    end

    test "excludes nil default_model and nil om_reflector_model" do
      settings = ModelAISettings.defaults()
      json_map = ModelAISettings.to_json_map(settings)

      refute Map.has_key?(json_map, "default_model")
      refute Map.has_key?(Map.get(json_map, "observational_memory", %{}), "reflector_model")
    end
  end

  describe "diff/2" do
    test "returns only fields that differ from base" do
      base = ModelAISettings.defaults()

      override =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "om_enabled" => true
        })

      diff = ModelAISettings.diff(base, override)

      assert Map.has_key?(diff, :default_model)
      assert Map.has_key?(diff, :om_enabled)
      refute Map.has_key?(diff, :reasoning)
    end

    test "returns empty map when identical" do
      base = ModelAISettings.defaults()
      diff = ModelAISettings.diff(base, base)
      assert diff == %{}
    end
  end

  describe "merge/2" do
    test "base + override yields override values for specified fields" do
      base = ModelAISettings.defaults()

      override =
        ModelAISettings.new(%{
          "default_model" => "claude-sonnet-4",
          "om_enabled" => true
        })

      merged = ModelAISettings.merge(base, override)

      assert merged.default_model == "claude-sonnet-4"
      assert merged.om_enabled == true
      assert merged.reasoning == "medium"
    end
  end

  describe "validate/1" do
    test "accepts valid privacy_mode values" do
      assert ModelAISettings.validate(%{"om_privacy_mode" => "standard"}) == :ok
      assert ModelAISettings.validate(%{"om_privacy_mode" => "local_only"}) == :ok
    end

    test "rejects invalid privacy_mode" do
      assert ModelAISettings.validate(%{"om_privacy_mode" => "invalid"}) ==
               {:error, "om_privacy_mode must be 'standard' or 'local_only'"}
    end

    test "rejects invalid memory_scope" do
      assert ModelAISettings.validate(%{"om_memory_scope" => "unknown"}) ==
               {:error, "om_memory_scope must be 'workspace', 'global', or 'both'"}
    end

    test "accepts valid memory_scope values" do
      assert ModelAISettings.validate(%{"om_memory_scope" => "workspace"}) == :ok
      assert ModelAISettings.validate(%{"om_memory_scope" => "global"}) == :ok
      assert ModelAISettings.validate(%{"om_memory_scope" => "both"}) == :ok
    end

    test "rejects negative max_recent_context" do
      assert ModelAISettings.validate(%{"om_max_recent_context" => -1}) ==
               {:error, "om_max_recent_context must be >= 0"}
    end

    test "rejects non-positive token thresholds" do
      assert ModelAISettings.validate(%{"om_message_tokens" => 0}) ==
               {:error, "om_message_tokens must be > 0"}
    end

    test "accepts valid full config" do
      assert ModelAISettings.validate(%{
               "default_model" => "claude-sonnet-4",
               "om_enabled" => true,
               "om_observer_model" => "claude-haiku",
               "om_memory_scope" => "workspace",
               "om_privacy_mode" => "standard",
               "om_max_recent_context" => 5
             }) == :ok
    end

    test "validates with atom keys too" do
      assert ModelAISettings.validate(%{om_privacy_mode: "local_only"}) == :ok

      assert ModelAISettings.validate(%{om_privacy_mode: "bad"}) ==
               {:error, "om_privacy_mode must be 'standard' or 'local_only'"}
    end
  end

  describe "drop_unknown_memory_model/3" do
    test "clears a model the catalog no longer has and keeps a known one" do
      settings = %ModelAISettings{
        om_observer_model: "xai/grok-4.7",
        om_reflector_model: "openai_codex/gpt-6-sol"
      }

      known? = &(&1 == "openai_codex/gpt-6-sol")

      updated =
        settings
        |> ModelAISettings.drop_unknown_memory_model(:om_observer_model, known?)
        |> ModelAISettings.drop_unknown_memory_model(:om_reflector_model, known?)

      assert updated.om_observer_model == nil
      assert updated.om_reflector_model == "openai_codex/gpt-6-sol"
    end
  end
end
