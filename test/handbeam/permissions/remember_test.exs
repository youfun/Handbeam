defmodule Handbeam.Permissions.RememberTest do
  use ExUnit.Case, async: true

  alias Handbeam.Permissions.{Remember, ToolPolicy}

  defp call(name, input), do: %{id: "c1", name: name, input: input}

  describe "pattern/1" do
    test "bash keeps git subcommand as a matcher pattern" do
      assert Remember.pattern(call("bash", %{"command" => "git status --short"})) ==
               "bash(git status*)"

      assert Remember.pattern(call("bash", %{"command" => "mix compile"})) ==
               "bash(mix compile*)"

      assert Remember.pattern(call("bash", %{"command" => "ls -la"})) == "bash(ls:*)"
    end

    test "file tools remember the path" do
      assert Remember.pattern(call("edit", %{"file_path" => "lib/handbeam/agent/turn.ex"})) ==
               "edit(lib/handbeam/agent/turn.ex)"

      assert Remember.pattern(call("write", %{"path" => "config/dev.exs"})) ==
               "write(config/dev.exs)"
    end

    test "browser remembers the first arg family" do
      assert Remember.pattern(call("browser", %{"args" => ["eval", "1"]})) == "browser(eval:*)"

      assert Remember.pattern(call("browser", %{"args" => ["open", "https://example.com"]})) ==
               "browser(open:*)"

      assert Remember.pattern(
               call("browser", %{"action" => "open", "url" => "https://example.com"})
             ) == "browser(open:*)"
    end

    test "unknown tools fall back to the tool name" do
      assert Remember.pattern(call("mem_recall", %{})) == "mem_recall"
    end
  end

  test "remembered allow pattern auto-approves the same family under prompt mode" do
    policy =
      ToolPolicy.from_settings(%{
        "tools" => %{
          "default_mode" => "prompt",
          "allow" => [Remember.pattern(call("bash", %{"command" => "git status --short"}))]
        }
      })

    assert ToolPolicy.decision(policy, call("bash", %{"command" => "git status"})) == :auto
    assert ToolPolicy.decision(policy, call("bash", %{"command" => "rm -rf tmp"})) == :prompt
  end
end
