defmodule Handbeam.Permissions.RememberTest do
  use ExUnit.Case, async: false

  alias Handbeam.Permissions.{Remember, ToolPolicy}

  setup do
    previous = Application.get_env(:handbeam, :host)
    fixed = :persistent_term.get({Handbeam.Tool.Builtin.Browser, :backend}, :unfixed)
    :ok = Handbeam.Tool.Builtin.Browser.release_backend!()
    Handbeam.Host.put!(%{browser_backend: :cli})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)

      restore_browser(fixed)
    end)
  end

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

    test "CLI browser remembers args only" do
      assert Remember.pattern(call("browser", %{"args" => ["eval", "1"]})) == "browser(eval:*)"

      assert Remember.pattern(call("browser", %{"args" => ["open", "https://example.com"]})) ==
               "browser(open:*)"

      assert Remember.pattern(call("browser", %{"action" => "open"})) == "browser"
    end

    test "WebView browser remembers action only" do
      Handbeam.Host.put!(%{browser_backend: :webview})

      assert Remember.pattern(
               call("browser", %{"action" => "open", "url" => "https://example.com"})
             ) == "browser(open:*)"

      assert Remember.pattern(call("browser", %{"args" => ["open", "https://example.com"]})) ==
               "browser"
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

  defp restore_browser(:unfixed), do: Handbeam.Tool.Builtin.Browser.release_backend!()

  defp restore_browser(backend) do
    :persistent_term.put({Handbeam.Tool.Builtin.Browser, :backend}, backend)
    :ok
  end
end
