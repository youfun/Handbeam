defmodule Handbeam.Tool.Extension.TerminalTest do
  use ExUnit.Case, async: false

  alias Handbeam.Terminal.Registry

  @workspace_id "test-ws-tools"
  @workspace_path File.cwd!()

  setup_all do
    unless Process.whereis(Registry) do
      {:ok, _} = Registry.start_link()
    end

    :ok
  end

  setup do
    context = %{
      workspace_id: @workspace_id,
      workspace_path: @workspace_path,
      working_directory: @workspace_path
    }

    on_exit(fn ->
      Registry.remove_workspace(@workspace_id)
    end)

    {:ok, context: context}
  end

  describe "ext__term_list" do
    test "returns empty list when no terminals", %{context: ctx} do
      {:ok, json} = Handbeam.Tool.Extension.Terminal.ext_term_list(%{}, ctx)
      assert {:ok, terminals} = Jason.decode(json)
      assert terminals == []
    end
  end

  describe "ext__term_output" do
    test "returns error for unknown terminal (no real session)", %{context: ctx} do
      result =
        Handbeam.Tool.Extension.Terminal.ext_term_output(
          %{"terminal" => "nonexistent"},
          ctx
        )

      assert {:error, msg} = result
      assert msg =~ "not found"
    end

    test "handles missing workspace_id", %{context: _ctx} do
      result =
        Handbeam.Tool.Extension.Terminal.ext_term_output(
          %{"terminal" => "any"},
          %{}
        )

      assert {:error, _} = result
    end
  end

  describe "ext__term_send" do
    test "returns error for unknown terminal", %{context: ctx} do
      result =
        Handbeam.Tool.Extension.Terminal.ext_term_send(
          %{"terminal" => "nope", "input" => "test"},
          ctx
        )

      assert {:error, _} = result
    end

    test "rejects empty input", %{context: ctx} do
      result =
        Handbeam.Tool.Extension.Terminal.ext_term_send(
          %{"terminal" => "any", "input" => ""},
          ctx
        )

      assert {:error, msg} = result
      assert msg =~ "input is required"
    end

    test "rejects missing terminal name", %{context: ctx} do
      result =
        Handbeam.Tool.Extension.Terminal.ext_term_send(
          %{"input" => "test"},
          ctx
        )

      assert {:error, msg} = result
      assert msg =~ "terminal name is required"
    end

    test "rejects nil terminal name", %{context: ctx} do
      result =
        Handbeam.Tool.Extension.Terminal.ext_term_send(
          %{"terminal" => nil, "input" => "test"},
          ctx
        )

      assert {:error, _} = result
    end
  end

  describe "tool policy defaults" do
    test "ext__term_send auto-runs in full access and prompts in safe mode" do
      auto_policy =
        Handbeam.Permissions.ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert Handbeam.Permissions.ToolPolicy.decision(auto_policy, %{
               name: "ext__term_send",
               input: %{"terminal" => "test", "input" => "echo hi"}
             }) == :auto

      prompt_policy =
        Handbeam.Permissions.ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert Handbeam.Permissions.ToolPolicy.decision(prompt_policy, %{
               name: "ext__term_send",
               input: %{"terminal" => "test", "input" => "echo hi"}
             }) == :prompt
    end

    test "ext__term_list defaults to auto in ToolPolicy" do
      policy = Handbeam.Permissions.ToolPolicy.from_settings(%{})

      decision =
        Handbeam.Permissions.ToolPolicy.decision(policy, %{
          name: "ext__term_list",
          input: %{}
        })

      assert decision == :auto
    end

    test "ext__term_output defaults to auto in ToolPolicy" do
      policy = Handbeam.Permissions.ToolPolicy.from_settings(%{})

      decision =
        Handbeam.Permissions.ToolPolicy.decision(policy, %{
          name: "ext__term_output",
          input: %{"terminal" => "test"}
        })

      assert decision == :auto
    end
  end
end
