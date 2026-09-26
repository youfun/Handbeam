defmodule Handbeam.Permissions.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Handbeam.Permissions.ToolPolicy

  defp call(name, input \\ %{}), do: %{id: "call_#{name}", name: name, input: input}

  # Failure list for bash `unsandboxed: true` (written before the implementation):
  #   - full-access workspaces (`default_mode: auto`) still prompt;
  #   - read-only workspaces (`default_mode: deny`) deny;
  #   - deny rules and session deny overrides still deny;
  #   - allow rules, `per_tool: auto`, and session allow overrides do not skip the prompt,
  #     because they were granted for sandboxed execution;
  #   - only the literal boolean `true` escalates; `"true"` or `1` stays sandboxed.
  describe "unsandboxed bash" do
    defp unsandboxed(command \\ "mix test"),
      do: call("bash", %{"command" => command, "unsandboxed" => true})

    test "prompts even in full-access workspaces" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
    end

    test "is denied in read-only workspaces" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
      assert ToolPolicy.decision(policy, unsandboxed()) == :deny
    end

    test "deny rules and session deny overrides still win" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"deny" => ["bash(rm:*)"]}})
      assert ToolPolicy.decision(policy, unsandboxed("rm -rf x")) == :deny

      policy = ToolPolicy.from_settings(%{}, %{"bash" => :deny})
      assert ToolPolicy.decision(policy, unsandboxed()) == :deny
    end

    test "sandboxed grants do not skip the prompt" do
      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"allow" => ["bash"], "per_tool" => %{"bash" => "auto"}}},
          %{"bash" => :auto}
        )

      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
    end

    test "session pattern grants do not cover unsandboxed or unrelated prompts" do
      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "prompt"}},
          %{},
          ["bash(mix test*)"]
        )

      assert ToolPolicy.decision(policy, call("bash", %{"command" => "mix test"})) == :auto
      assert ToolPolicy.decision(policy, call("bash", %{"command" => "rm -rf tmp"})) == :prompt
      assert ToolPolicy.decision(policy, unsandboxed("mix test")) == :prompt
    end

    test "auto_review config does not skip the unsandboxed prompt" do
      policy =
        ToolPolicy.from_settings(%{
          "tools" => %{
            "default_mode" => "auto",
            "approvals_reviewer" => "auto_review",
            "allow" => ["bash"]
          }
        })

      assert ToolPolicy.decision(policy, unsandboxed()) == :prompt
    end

    test "only the boolean true escalates" do
      policy = ToolPolicy.from_settings(%{})

      for value <- ["true", 1, false, nil] do
        input = %{"command" => "ls", "unsandboxed" => value}
        assert ToolPolicy.decision(policy, call("bash", input)) == :auto
      end
    end
  end

  # Failure list for `task_status` `action: "apply"` (subagent worktree diff → workspace):
  #   - prompts even with full access and a `task_status` allow grant;
  #   - denied in read-only workspaces;
  #   - other actions (list/get/message/discard) follow the normal policy.
  describe "subagent worktree apply" do
    test "prompts despite full access or grants, denies in read-only" do
      apply = call("task_status", %{"action" => "apply", "child_conversation_id" => "c"})

      policy =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "per_tool" => %{"task_status" => "auto"}}},
          %{"task_status" => :auto}
        )

      assert ToolPolicy.decision(policy, apply) == :prompt

      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "deny"}})
      assert ToolPolicy.decision(policy, apply) == :deny
    end

    test "other actions are not escalated" do
      policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      for action <- ~w(list get message discard) do
        assert ToolPolicy.decision(policy, call("task_status", %{"action" => action})) == :auto
      end
    end
  end

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

    test "system open and share tools prompt in full access unless explicitly allowed or denied" do
      auto = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})

      assert ToolPolicy.decision(auto, call("open_url", %{"url" => "https://a.com"})) ==
               :prompt

      assert ToolPolicy.decision(auto, call("open_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(auto, call("share_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(
               auto,
               call("device_calendar", %{"calendar_action" => "list_events"})
             ) ==
               :prompt

      assert ToolPolicy.decision(auto, call("device_alarm", %{"hour" => 7, "minute" => 30})) ==
               :prompt

      # "Always allow" appends to the workspace allow list; only that tool changes.
      always =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "allow" => ["open_url"]}
        })

      assert ToolPolicy.decision(always, call("open_url", %{"url" => "https://a.com"})) ==
               :auto

      assert ToolPolicy.decision(always, call("open_file", %{"path" => "a.pdf"})) ==
               :prompt

      assert ToolPolicy.decision(always, call("share_file", %{"path" => "a.pdf"})) ==
               :prompt

      # "Allow for this session" writes a session override.
      session =
        ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}}, %{
          "share_file" => :auto
        })

      assert ToolPolicy.decision(session, call("share_file", %{"path" => "a.pdf"})) ==
               :auto

      assert ToolPolicy.decision(session, call("open_url", %{"url" => "https://a.com"})) ==
               :prompt

      denied =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "auto", "deny" => ["open_url"]}
        })

      assert ToolPolicy.decision(denied, call("open_url", %{"url" => "https://a.com"})) ==
               :deny

      per_tool_denied =
        ToolPolicy.from_settings(%{
          "tools" => %{
            "default_mode" => "auto",
            "allow" => ["open_file"],
            "per_tool" => %{"open_file" => "deny"}
          }
        })

      assert ToolPolicy.decision(per_tool_denied, call("open_file", %{"path" => "a.pdf"})) ==
               :deny

      session_denied =
        ToolPolicy.from_settings(
          %{"tools" => %{"default_mode" => "auto", "allow" => ["open_url"]}},
          %{"open_url" => :deny}
        )

      assert ToolPolicy.decision(
               session_denied,
               call("open_url", %{"url" => "https://a.com"})
             ) == :deny
    end

    test "system open and share tools still prompt in safe mode and honor allow rules there" do
      prompt = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "prompt"}})

      assert ToolPolicy.decision(prompt, call("open_url", %{"url" => "https://a.com"})) ==
               :prompt

      allowed =
        ToolPolicy.from_settings(%{
          "tools" => %{"default_mode" => "prompt", "allow" => ["open_url"]}
        })

      assert ToolPolicy.decision(allowed, call("open_url", %{"url" => "https://a.com"})) ==
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

  describe "sensitive paths" do
    test "allow, session allow, and unsandboxed cannot turn a credential path into prompt or auto" do
      policy =
        ToolPolicy.from_settings(
          %{
            "tools" => %{
              "default_mode" => "auto",
              "allow" => ["read", "bash"],
              "per_tool" => %{"read" => "auto", "bash" => "auto"}
            }
          },
          %{"read" => :auto, "bash" => :auto},
          ["read", "bash"]
        )

      for call <- [
            call("read", %{"file_path" => ".env"}),
            call("read", %{"file_path" => "~/.ssh/id_rsa"}),
            call("bash", %{"command" => "cat ~/.ssh/id_rsa"}),
            call("bash", %{"command" => "cat ~/.ssh/id_rsa", "unsandboxed" => true})
          ] do
        decision = ToolPolicy.decision(policy, call)
        assert decision == :deny
        refute decision in [:prompt, :auto]
      end

      assert ToolPolicy.decision(policy, call("read", %{"file_path" => "lib/app.ex"})) == :auto
      assert ToolPolicy.decision(policy, call("bash", %{"command" => "ls lib"})) == :auto
    end
  end
end
