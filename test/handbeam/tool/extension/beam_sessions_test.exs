defmodule Handbeam.Tool.Extension.BeamSessionsTest do
  use Handbeam.DataCase, async: false

  setup do
    # Register BEAM tools on-demand
    Handbeam.Tool.Registry.register_beam_tools(:all)
    %{}
  end

  defp build_context do
    %{working_directory: File.cwd!()}
  end

  describe "ext__beam__sessions" do
    test "lists active sessions including the test session" do
      {:ok, output} = Handbeam.Tool.Extension.Beam.Sessions.execute(%{}, build_context())
      assert is_binary(output)
      # Should find at least the test process session if any are active
    end

    test "has proper tool metadata" do
      assert Handbeam.Tool.Extension.Beam.Sessions.name() == "ext__beam__sessions"
      assert is_binary(Handbeam.Tool.Extension.Beam.Sessions.description())
      assert is_map(Handbeam.Tool.Extension.Beam.Sessions.input_schema())
    end
  end

  describe "ext__beam__session_snapshot" do
    test "returns error for nonexistent session" do
      {:error, reason} =
        Handbeam.Tool.Extension.Beam.SessionSnapshot.execute(
          %{"session_id" => "nonexistent-session-id-12345"},
          build_context()
        )

      assert reason =~ "not found" or reason =~ "Session"
    end

    test "session_id is required" do
      {:error, reason} =
        Handbeam.Tool.Extension.Beam.SessionSnapshot.execute(%{}, build_context())

      assert reason =~ "session_id"
    end

    test "has proper tool metadata" do
      assert Handbeam.Tool.Extension.Beam.SessionSnapshot.name() == "ext__beam__session_snapshot"
      assert is_binary(Handbeam.Tool.Extension.Beam.SessionSnapshot.description())
    end
  end

  describe "ext__beam__session_steer" do
    test "returns error for nonexistent session" do
      {:error, reason} =
        Handbeam.Tool.Extension.Beam.SessionSteer.execute(
          %{"session_id" => "nonexistent-session-id-12345", "message" => "hello"},
          build_context()
        )

      assert reason =~ "not found" or reason =~ "Session"
    end

    test "session_id and message are required" do
      {:error, reason} =
        Handbeam.Tool.Extension.Beam.SessionSteer.execute(%{}, build_context())

      assert reason =~ "session_id and message"
    end

    test "has proper tool metadata" do
      assert Handbeam.Tool.Extension.Beam.SessionSteer.name() == "ext__beam__session_steer"
      assert is_binary(Handbeam.Tool.Extension.Beam.SessionSteer.description())
    end
  end

  describe "on-demand registration" do
    test "register_beam_tools/0 registers all beam tools" do
      Handbeam.Tool.Registry.reset()

      # Initially, only builtin tools
      list_before = Handbeam.Tool.Registry.list()
      refute Enum.any?(list_before, &String.starts_with?(&1, "ext__beam__"))

      # Register all beam tools
      Handbeam.Tool.Registry.register_beam_tools(:all)

      list_after = Handbeam.Tool.Registry.list()
      assert Enum.any?(list_after, &(&1 == "ext__beam__docs"))
      assert Enum.any?(list_after, &(&1 == "ext__beam__eval"))
      assert Enum.any?(list_after, &(&1 == "ext__beam__top"))
      assert Enum.any?(list_after, &(&1 == "ext__beam__sessions"))
      assert Enum.any?(list_after, &(&1 == "ext__beam__session_snapshot"))
      assert Enum.any?(list_after, &(&1 == "ext__beam__session_steer"))
    end

    test "register_beam_tools(:safe_only) excludes dangerous tools" do
      Handbeam.Tool.Registry.reset()
      Handbeam.Tool.Registry.register_beam_tools(:safe_only)

      list = Handbeam.Tool.Registry.list()

      # Safe tools should be registered
      assert Enum.any?(list, &(&1 == "ext__beam__docs"))
      assert Enum.any?(list, &(&1 == "ext__beam__top"))
      assert Enum.any?(list, &(&1 == "ext__beam__sessions"))
      assert Enum.any?(list, &(&1 == "ext__beam__session_snapshot"))

      # Dangerous tools should NOT be registered
      refute Enum.any?(list, &(&1 == "ext__beam__eval"))
      refute Enum.any?(list, &(&1 == "ext__beam__process_info"))
      refute Enum.any?(list, &(&1 == "ext__beam__session_steer"))
    end
  end
end
