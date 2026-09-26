defmodule Handbeam.Agent.Middleware.ToolGuardTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.{Config, Message, State}
  alias Handbeam.Agent.Middleware.ToolGuard

  defp tmp_workspace(settings) do
    dir = Path.join(System.tmp_dir!(), "sigil_tool_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".handbeam"))
    File.write!(Path.join(dir, ".handbeam/settings.jsonc"), Jason.encode!(settings))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp state(settings, tool_calls, overrides \\ %{}) do
    workspace = tmp_workspace(settings)
    config = %Config{working_directory: workspace, model: "fake", middleware: []}

    %State{State.init(config, "hi") | tool_guard_overrides: overrides}
    |> State.append_messages([Message.tool_use(tool_calls)])
  end

  test "after_tool_request allows memory tools and denies workspace tools without a workspace" do
    config = %Config{working_directory: nil, model: "fake", middleware: []}

    memory =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([%{type: "tool_use", id: "m1", name: "mem_recall", input: %{}}])
      ])

    assert ToolGuard.call(:after_tool_request, memory) == memory

    web =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([
          %{
            type: "tool_use",
            id: "w1",
            name: "web_fetch",
            input: %{"url" => "https://example.com"}
          }
        ])
      ])

    assert ToolGuard.call(:after_tool_request, web) == web

    open =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([
          %{type: "tool_use", id: "o1", name: "open_url", input: %{"url" => "https://example.com"}}
        ])
      ])

    assert ToolGuard.call(:after_tool_request, open) == open

    file =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([%{type: "tool_use", id: "r1", name: "read", input: %{}}])
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, file)
    assert [%{id: "r1"}] = guarded.tool_guard_denied_calls
  end

  test "after_tool_request passes through when all tools are auto approved" do
    settings = %{"tools" => %{"per_tool" => %{"read" => "auto"}}}
    state = state(settings, [%{type: "tool_use", id: "r1", name: "read", input: %{}}])

    assert ToolGuard.call(:after_tool_request, state) == state
  end

  test "after_tool_request returns denied tool result blocks without executing denied tools" do
    settings = %{"tools" => %{"deny" => ["bash(rm:*)"]}}

    state =
      state(settings, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "rm -rf tmp"}}
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "b1"}] = guarded.tool_guard_denied_calls
    assert [result] = guarded.tool_guard_result_blocks
    assert result.tool_use_id == "b1"
    assert result.is_error == true
    assert result.content =~ "Tool call denied by workspace permissions"
    refute result.content =~ "rm -rf"
  end

  test "after_tool_request interrupts when prompt approval is required" do
    settings = %{"tools" => %{"per_tool" => %{"bash" => "prompt"}}}

    state =
      state(settings, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "git status"}}
      ])

    assert {:interrupt, interrupted, data} = ToolGuard.call(:after_tool_request, state)
    assert interrupted.status == :interrupted
    assert interrupted.interrupt_data == data
    assert data.type == :tool_approval
    assert data.hitl_tool_call_ids == ["b1"]
    assert [%{tool_call_id: "b1", tool_name: "bash"}] = data.action_requests
  end

  test "after_tool_request auto-approves browser eval in full access" do
    settings = %{"tools" => %{"default_mode" => "auto"}}

    state =
      state(settings, [
        %{type: "tool_use", id: "br1", name: "browser", input: %{"args" => ["eval", "1"]}}
      ])

    assert ToolGuard.call(:after_tool_request, state) == state
  end

  test "after_tool_request interrupts browser eval in safe mode" do
    settings = %{"tools" => %{"default_mode" => "prompt"}}

    state =
      state(settings, [
        %{type: "tool_use", id: "br1", name: "browser", input: %{"args" => ["eval", "1"]}}
      ])

    assert {:interrupt, _interrupted, data} = ToolGuard.call(:after_tool_request, state)
    assert data.hitl_tool_call_ids == ["br1"]
  end

  test "after_tool_request denies local file navigation in browser args" do
    settings = %{"tools" => %{"default_mode" => "auto"}}

    state =
      state(settings, [
        %{
          type: "tool_use",
          id: "br2",
          name: "browser",
          input: %{"args" => ["open", "file:///etc/passwd"]}
        }
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "br2"}] = guarded.tool_guard_denied_calls
  end

  test "after_tool_request denies bash wrapping agent-browser" do
    settings = %{"tools" => %{"default_mode" => "auto"}}

    state =
      state(settings, [
        %{
          type: "tool_use",
          id: "b3",
          name: "bash",
          input: %{"command" => "agent-browser open https://example.com"}
        }
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert [%{id: "b3"}] = guarded.tool_guard_denied_calls
  end
end
