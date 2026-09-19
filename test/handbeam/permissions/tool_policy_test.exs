defmodule Handbeam.Permissions.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Handbeam.Permissions.ToolPolicy

  defp call(name, input \\ %{}), do: %{id: "call_#{name}", name: name, input: input}

  describe "from_settings/2" do
    test "defaults to auto for missing or old settings" do
      assert ToolPolicy.from_settings(%{}) |> ToolPolicy.decision(call("bash")) == :auto

      old_settings = %{"tools" => %{"beam" => %{"auto" => true}, "explicit" => []}}
      assert ToolPolicy.from_settings(old_settings) |> ToolPolicy.decision(call("edit")) == :auto
    end

    test "applies precedence deny > per_tool > allow > default_mode" do
      settings = %{
        "tools" => %{
          "default_mode" => "prompt",
          "allow" => ["bash", "mem_*"],
          "deny" => ["bash(rm:*)"],
          "per_tool" => %{"bash" => "auto", "write" => "deny", "read" => "prompt"}
        }
      }

      policy = ToolPolicy.from_settings(settings)

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "rm -rf tmp"})) == :deny
      assert ToolPolicy.decision(policy, call("bash", %{"command" => "git status"})) == :auto
      assert ToolPolicy.decision(policy, call("write")) == :deny
      assert ToolPolicy.decision(policy, call("read")) == :prompt
      assert ToolPolicy.decision(policy, call("mem_recall")) == :auto
      assert ToolPolicy.decision(policy, call("unknown")) == :prompt
    end

    test "session overrides deny before workspace policy" do
      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "per_tool" => %{"bash" => "auto"}}},
          %{"bash" => :deny}
        )

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "git status"})) == :deny
    end

    test "invalid approval modes fall back safely to auto" do
      settings = %{
        "tools" => %{"default_mode" => "wat", "per_tool" => %{"bash" => "wat"}}
      }

      policy = ToolPolicy.from_settings(settings)
      assert ToolPolicy.decision(policy, call("bash")) == :auto
      assert ToolPolicy.decision(policy, call("other")) == :auto
    end

    test "mount tools auto-run in full access and prompt in safe mode" do
      auto_policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
      assert ToolPolicy.decision(auto_policy, call("ext__mount__apply")) == :auto
      assert ToolPolicy.decision(auto_policy, call("ext__mount__drop")) == :auto

      prompt_policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})
      assert ToolPolicy.decision(prompt_policy, call("ext__mount__apply")) == :prompt
      assert ToolPolicy.decision(prompt_policy, call("ext__mount__drop")) == :prompt

      configured =
        ToolPolicy.from_settings(%{
          "tools" => %{"per_tool" => %{"ext__mount__apply" => "auto"}}
        })

      assert ToolPolicy.decision(configured, call("ext__mount__apply")) == :auto
    end

    test "mix_project prompts in auto workspaces but honors deny and allow" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("mix_project", %{"action" => "compile"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["mix_project"]}
        })

      assert ToolPolicy.decision(denied, call("mix_project", %{"action" => "compile"})) ==
               :deny

      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "mix_project" => :auto
        })

      assert ToolPolicy.decision(session, call("mix_project", %{"action" => "compile"})) ==
               :auto

      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["mix_project"]}
        })

      assert ToolPolicy.decision(always, call("mix_project", %{"action" => "compile"})) ==
               :auto
    end

    test "run_elixir_script prompts in auto workspaces but honors deny and allow" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["run_elixir_script"]}
        })

      assert ToolPolicy.decision(denied, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :deny

      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "run_elixir_script" => :auto
        })

      assert ToolPolicy.decision(session, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :auto

      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["run_elixir_script"]}
        })

      assert ToolPolicy.decision(always, call("run_elixir_script", %{"path" => "a.exs"})) ==
               :auto
    end

    test "android intent tools prompt in full access unless explicitly allowed or denied" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("android_open_url", %{"url" => "https://a.com"})) ==
               :prompt

      assert ToolPolicy.decision(auto, call("android_open_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(auto, call("android_share_file", %{"path" => "a.pdf"})) ==
               :prompt

      # "Always allow" appends to the workspace allow list; only that tool changes.
      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["android_open_url"]}
        })

      assert ToolPolicy.decision(always, call("android_open_url", %{"url" => "https://a.com"})) ==
               :auto

      assert ToolPolicy.decision(always, call("android_open_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(always, call("android_share_file", %{"path" => "a.pdf"})) ==
               :prompt

      # "Allow for this session" writes a session override.
      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "android_share_file" => :auto
        })

      assert ToolPolicy.decision(session, call("android_share_file", %{"path" => "a.pdf"})) ==
               :auto

      assert ToolPolicy.decision(session, call("android_open_url", %{"url" => "https://a.com"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["android_open_url"]}
        })

      assert ToolPolicy.decision(denied, call("android_open_url", %{"url" => "https://a.com"})) ==
               :deny

      per_tool_denied =
        ToolPolicy.from_settings(%{
          "tools" => %{
            "default_mode" => "auto",
            "allow" => ["android_open_file"],
            "per_tool" => %{"android_open_file" => "deny"}
          }
        })

      assert ToolPolicy.decision(per_tool_denied, call("android_open_file", %{"path" => "a.pdf"})) ==
               :deny

      session_denied =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "allow" => ["android_open_url"]}},
          %{"android_open_url" => :deny}
        )

      assert ToolPolicy.decision(
               session_denied,
               call("android_open_url", %{"url" => "https://a.com"})
             ) == :deny
    end

    test "android intent tools still prompt in safe mode and honor allow rules there" do
      prompt = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert ToolPolicy.decision(prompt, call("android_open_url", %{"url" => "https://a.com"})) ==
               :prompt

      allowed =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "prompt", "allow" => ["android_open_url"]}
        })

      assert ToolPolicy.decision(allowed, call("android_open_url", %{"url" => "https://a.com"})) ==
               :auto
    end

    test "full access skips capability prompts but keeps capability denies" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"args" => ["open", "https://example.com"]})
             ) ==
               :auto

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["eval", "1"]})) == :auto

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["cookies", "get"]})) ==
               :auto

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"args" => ["open", "file:///etc/passwd"]})
             ) == :deny
    end

    test "safe mode still prompts for browser sensitive families" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["eval", "1"]})) == :prompt

      assert ToolPolicy.decision(policy, call("browser", %{"args" => ["cookies", "get"]})) ==
               :prompt
    end

    test "explicit workspace policy still wins over browser capability defaults" do
      deny_eval =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["browser(eval:*)"]}
        })

      assert ToolPolicy.decision(deny_eval, call("browser", %{"args" => ["eval", "1"]})) == :deny

      auto_eval =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "per_tool" => %{"browser" => "auto"}}
        })

      assert ToolPolicy.decision(auto_eval, call("browser", %{"args" => ["eval", "1"]})) == :auto
    end

    test "desktop does not classify native action/url as argv" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(
               policy,
               call("browser", %{"action" => "open", "url" => "https://example.org"})
             ) == :deny
    end

    test "denies bash wrapping agent-browser even when default_mode is auto" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(
               policy,
               call("bash", %{"command" => "agent-browser open https://example.com"})
             ) == :deny

      assert ToolPolicy.decision(
               policy,
               call("bash", %{"command" => "npx agent-browser snapshot -i"})
             ) == :deny

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls"})) == :auto
    end
  end
end
