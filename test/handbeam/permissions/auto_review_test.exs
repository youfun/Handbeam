defmodule Handbeam.Permissions.AutoReviewTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.{Config, Message, State, Turn}
  alias Handbeam.Agent.Middleware.ToolGuard
  alias Handbeam.Permissions.AutoReview

  defmodule MarkerTool do
    @behaviour Handbeam.Agent.Tool

    def name, do: "auto_review_marker"
    def description, do: "Writes a marker file when executed"
    def input_schema, do: %{type: "object", properties: %{file: %{type: "string"}}}

    def execute(%{"file" => file}, %{working_directory: workspace}) do
      :ok = File.write(Path.join(workspace, file), "ran")
      {:ok, "touched #{file}", %{file_path: file}}
    end
  end

  setup do
    Process.delete(AutoReview.transport_key())
    :ok = Handbeam.Tool.Registry.register(MarkerTool, override: true)

    on_exit(fn ->
      Process.delete(AutoReview.transport_key())
      Handbeam.Tool.Registry.unregister(MarkerTool.name())
    end)

    :ok
  end

  defp workspace(settings) do
    dir = Path.join(System.tmp_dir!(), "auto_review_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".handbeam"))
    File.write!(Path.join(dir, ".handbeam/settings.jsonc"), Jason.encode!(settings))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp guard_state(settings, calls, overrides \\ %{}) do
    config = %Config{
      working_directory: workspace(settings),
      model: "fake",
      middleware: []
    }

    %State{State.init(config, "please run the local check") | tool_guard_overrides: overrides}
    |> State.append_messages([Message.tool_use(calls)])
  end

  defp reviewed(calls) do
    Process.put(AutoReview.transport_key(), fn request ->
      send(self(), {:reviewed, request})

      decisions =
        Enum.map(request.action_requests, fn req ->
          decision = Map.get(calls, req.tool_call_id, "deny")

          %{
            "tool_call_id" => req.tool_call_id,
            "decision" => decision,
            "rationale" => "because #{decision}"
          }
        end)

      {:ok, Jason.encode!(%{"decisions" => decisions})}
    end)
  end

  test "missing approvals_reviewer still interrupts a prompt" do
    state =
      guard_state(%{"tools" => %{"per_tool" => %{"bash" => "prompt"}}}, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "mix test"}}
      ])

    parent = self()

    Process.put(AutoReview.transport_key(), fn _request ->
      send(parent, :reviewed)
      {:ok, ~s({"decision":"approve","rationale":"ok"})}
    end)

    assert {:interrupt, interrupted, data} = ToolGuard.call(:after_tool_request, state)
    assert interrupted.status == :interrupted
    assert data.hitl_tool_call_ids == ["b1"]
    refute_received :reviewed
  end

  test "approve executes the tool once and does not write allow or a session override" do
    dir =
      workspace(%{
        "tools" => %{
          "default_mode" => "auto",
          "approvals_reviewer" => "auto_review",
          "allow" => ["read"],
          "per_tool" => %{"auto_review_marker" => "prompt"}
        }
      })

    reviewed(%{"m1" => "approve"})

    defmodule ApproveProvider do
      @behaviour Handbeam.Agent.Provider

      def complete(messages, _tools, _config) do
        if Enum.any?(messages, &(&1.role == :tool_result)) do
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("done")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        else
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Message.tool_use([
                 %{
                   type: "tool_use",
                   id: "m1",
                   name: "auto_review_marker",
                   input: %{"file" => "ran"}
                 }
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
    end

    config = %Config{
      provider: ApproveProvider,
      model: "fake",
      max_turns: 4,
      working_directory: dir,
      middleware: [ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "run the local check"), [])

    assert File.read!(Path.join(dir, "ran")) == "ran"
    assert result.status == :completed
    assert result.tool_guard_overrides == %{}
    assert {:ok, settings} = Handbeam.WorkspaceSettings.load(dir)
    assert get_in(settings, ["tools", "allow"]) == ["read"]
    refute result.status == :interrupted
  end

  test "deny returns the rationale and does not execute the tool" do
    dir =
      workspace(%{
        "tools" => %{
          "approvals_reviewer" => "auto_review",
          "per_tool" => %{"auto_review_marker" => "prompt"}
        }
      })

    reviewed(%{"m1" => "deny"})

    defmodule DenyProvider do
      @behaviour Handbeam.Agent.Provider

      def complete(messages, _tools, _config) do
        if Enum.any?(messages, &(&1.role == :tool_result)) do
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("stopped")],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        else
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Message.tool_use([
                 %{
                   type: "tool_use",
                   id: "m1",
                   name: "auto_review_marker",
                   input: %{"file" => "denied"}
                 }
               ])
             ],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
    end

    config = %Config{
      provider: DenyProvider,
      model: "fake",
      max_turns: 4,
      working_directory: dir,
      middleware: [ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "run it"), [])

    refute File.exists?(Path.join(dir, "denied"))
    tool_result = Enum.find(result.messages, &(&1.role == :tool_result))
    assert [%{content: content, is_error: true}] = tool_result.content
    assert content =~ "because deny"
    assert content =~ AutoReview.no_workaround()
  end

  test "crash, timeout, and invalid JSON fall back to human approval" do
    settings = %{
      "tools" => %{
        "approvals_reviewer" => "auto_review",
        "auto_review" => %{"timeout_ms" => 40},
        "per_tool" => %{"bash" => "prompt"}
      }
    }

    call = [%{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "mix test"}}]

    Process.put(AutoReview.transport_key(), fn _request -> raise "review crashed" end)

    assert {:interrupt, interrupted, data} =
             ToolGuard.call(:after_tool_request, guard_state(settings, call))

    assert interrupted.status == :interrupted
    assert data.type == :tool_approval
    assert interrupted.auto_review.consecutive_denies == 0
    refute interrupted.error

    Process.put(AutoReview.transport_key(), fn _request ->
      Process.sleep(200)
      {:ok, ~s({"decision":"deny","rationale":"late"})}
    end)

    assert {:interrupt, timed_out, data} =
             ToolGuard.call(:after_tool_request, guard_state(settings, call))

    assert timed_out.status == :interrupted
    assert data.hitl_tool_call_ids == ["b1"]
    assert timed_out.auto_review.consecutive_denies == 0
    refute timed_out.interrupt_data == nil

    Process.put(AutoReview.transport_key(), fn _request -> {:ok, "not json"} end)

    assert {:interrupt, _bad, data} =
             ToolGuard.call(:after_tool_request, guard_state(settings, call))

    assert data.action_requests |> hd() |> Map.get(:tool_call_id) == "b1"
  end

  test "an unavailable model falls back without treating the miss as deny" do
    dir =
      workspace(%{
        "tools" => %{
          "approvals_reviewer" => "auto_review",
          "auto_review" => %{"model" => "missing/no-such-model"},
          "per_tool" => %{"bash" => "prompt"}
        }
      })

    state =
      guard_state(
        %{
          "tools" => %{
            "approvals_reviewer" => "auto_review",
            "auto_review" => %{"model" => "missing/no-such-model"},
            "per_tool" => %{"bash" => "prompt"}
          }
        },
        [%{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "mix test"}}]
      )

    assert state.config.working_directory != dir
    assert {:interrupt, interrupted, _data} = ToolGuard.call(:after_tool_request, state)
    assert interrupted.status == :interrupted
    assert interrupted.auto_review.recent == []
  end

  test "unsandboxed bash is still prompt, then reviewed, and allow rules do not skip it" do
    settings = %{
      "tools" => %{
        "default_mode" => "auto",
        "approvals_reviewer" => "auto_review",
        "allow" => ["bash"]
      }
    }

    call = %{
      type: "tool_use",
      id: "u1",
      name: "bash",
      input: %{"command" => "cat ~/.ssh/id_rsa", "unsandboxed" => true}
    }

    policy = Handbeam.Permissions.ToolPolicy.from_settings(settings)
    assert Handbeam.Permissions.ToolPolicy.decision(policy, call) == :prompt

    parent = self()

    Process.put(AutoReview.transport_key(), fn request ->
      send(parent, {:reviewed, Enum.map(request.action_requests, & &1.tool_call_id)})
      {:ok, ~s({"decision":"deny","rationale":"credential file"})}
    end)

    assert {:tool_guard_denied, guarded} =
             ToolGuard.call(:after_tool_request, guard_state(settings, [call]))

    assert_received {:reviewed, ["u1"]}
    assert guarded.tool_guard_overrides == %{}
    assert [block] = guarded.tool_guard_result_blocks
    assert block.content =~ "credential file"
    assert block.content =~ AutoReview.no_workaround()
  end

  test "task_status apply stays :prompt and is reviewed; allow does not enter review" do
    settings = %{
      "tools" => %{
        "default_mode" => "auto",
        "approvals_reviewer" => "auto_review",
        "allow" => ["task_status", "run_elixir_script"]
      }
    }

    apply_call = %{
      type: "tool_use",
      id: "apply-1",
      name: "task_status",
      input: %{"action" => "apply", "child_conversation_id" => "child"}
    }

    allowed_script = %{
      type: "tool_use",
      id: "script-allowed",
      name: "run_elixir_script",
      input: %{"script" => "1 + 1"}
    }

    prompted_script = %{
      type: "tool_use",
      id: "script-1",
      name: "run_elixir_script",
      input: %{"script" => "1 + 1"}
    }

    policy = Handbeam.Permissions.ToolPolicy.from_settings(settings)
    assert Handbeam.Permissions.ToolPolicy.decision(policy, apply_call) == :prompt
    assert Handbeam.Permissions.ToolPolicy.decision(policy, allowed_script) == :auto

    prompt_policy =
      Handbeam.Permissions.ToolPolicy.from_settings(%{
        "tools" => %{"default_mode" => "auto", "approvals_reviewer" => "auto_review"}
      })

    assert Handbeam.Permissions.ToolPolicy.decision(prompt_policy, prompted_script) == :prompt

    parent = self()

    Process.put(AutoReview.transport_key(), fn request ->
      send(parent, {:reviewed, Enum.map(request.action_requests, & &1.tool_name)})
      {:ok, ~s({"decision":"deny","rationale":"not this gate"})}
    end)

    assert {:tool_guard_denied, guarded} =
             ToolGuard.call(:after_tool_request, guard_state(settings, [apply_call]))

    assert_received {:reviewed, ["task_status"]}
    assert guarded.tool_guard_overrides == %{}

    assert ToolGuard.call(:after_tool_request, guard_state(settings, [allowed_script]))
           |> then(fn state -> state.tool_guard_result_blocks end) == []

    refute_received {:reviewed, ["run_elixir_script"]}

    assert {:tool_guard_denied, _script} =
             ToolGuard.call(
               :after_tool_request,
               guard_state(
                 %{"tools" => %{"default_mode" => "auto", "approvals_reviewer" => "auto_review"}},
                 [prompted_script]
               )
             )

    assert_received {:reviewed, ["run_elixir_script"]}
  end

  test "session allow does not skip unsandboxed review" do
    settings = %{"tools" => %{"approvals_reviewer" => "auto_review", "default_mode" => "prompt"}}

    call = %{
      type: "tool_use",
      id: "u2",
      name: "bash",
      input: %{"command" => "ls", "unsandboxed" => true}
    }

    parent = self()

    Process.put(AutoReview.transport_key(), fn _request ->
      send(parent, :reviewed)
      {:ok, ~s({"decision":"deny","rationale":"sandbox"})}
    end)

    assert {:tool_guard_denied, _guarded} =
             ToolGuard.call(
               :after_tool_request,
               guard_state(settings, [call], %{"bash" => :auto})
             )

    assert_received :reviewed
  end

  test "full-access sandboxed bash does not call review" do
    settings = %{"tools" => %{"default_mode" => "auto", "approvals_reviewer" => "auto_review"}}

    parent = self()

    Process.put(AutoReview.transport_key(), fn _request ->
      send(parent, :reviewed)
      {:ok, ~s({"decision":"deny","rationale":"no"})}
    end)

    state =
      guard_state(settings, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "mix test"}}
      ])

    assert ToolGuard.call(:after_tool_request, state) == state
    refute_received :reviewed
  end

  test "default_mode deny does not call review" do
    settings = %{"tools" => %{"default_mode" => "deny", "approvals_reviewer" => "auto_review"}}
    parent = self()

    Process.put(AutoReview.transport_key(), fn _request ->
      send(parent, :reviewed)
      {:ok, ~s({"decision":"approve","rationale":"no"})}
    end)

    state =
      guard_state(settings, [
        %{type: "tool_use", id: "b1", name: "bash", input: %{"command" => "mix test"}}
      ])

    assert {:tool_guard_denied, guarded} = ToolGuard.call(:after_tool_request, state)
    assert hd(guarded.tool_guard_result_blocks).content =~ "workspace permissions"
    refute_received :reviewed
  end

  test "three consecutive denies halt the turn" do
    dir =
      workspace(%{
        "tools" => %{
          "approvals_reviewer" => "auto_review",
          "per_tool" => %{"auto_review_marker" => "prompt"}
        }
      })

    {:ok, reviews} = Agent.start_link(fn -> 0 end)

    Process.put(AutoReview.transport_key(), fn request ->
      Agent.update(reviews, &(&1 + 1))

      {:ok,
       Jason.encode!(%{
         "decisions" =>
           Enum.map(request.action_requests, fn req ->
             %{
               "tool_call_id" => req.tool_call_id,
               "decision" => "deny",
               "rationale" => "still no"
             }
           end)
       })}
    end)

    defmodule RepeatProvider do
      @behaviour Handbeam.Agent.Provider

      def complete(_messages, _tools, _config) do
        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [
             Message.tool_use([
               %{
                 type: "tool_use",
                 id: "d#{System.unique_integer([:positive])}",
                 name: "auto_review_marker",
                 input: %{"file" => "should-not-run"}
               }
             ])
           ],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
    end

    config = %Config{
      provider: RepeatProvider,
      model: "fake",
      max_turns: 8,
      working_directory: dir,
      middleware: [ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "keep trying"), [])

    assert result.status == :halted
    assert result.error =~ "超时不会被当成拒绝"
    assert Agent.get(reviews, & &1) == 3
    refute File.exists?(Path.join(dir, "should-not-run"))

    denied =
      result.messages
      |> Enum.filter(&(&1.role == :tool_result))
      |> Enum.flat_map(& &1.content)

    assert length(denied) == 3
    assert Enum.all?(denied, &(&1.content =~ AutoReview.no_workaround()))
  end

  test "a halt does not execute an approved sibling in the same batch" do
    dir =
      workspace(%{
        "tools" => %{
          "approvals_reviewer" => "auto_review",
          "per_tool" => %{"auto_review_marker" => "prompt"}
        }
      })

    Process.put(:halt_batch_step, 0)

    Process.put(AutoReview.transport_key(), fn request ->
      {:ok,
       Jason.encode!(%{
         "decisions" =>
           Enum.map(request.action_requests, fn req ->
             decision =
               if req.tool_name == "auto_review_marker" and req.tool_call_id == "ok",
                 do: "approve",
                 else: "deny"

             %{
               "tool_call_id" => req.tool_call_id,
               "decision" => decision,
               "rationale" => decision
             }
           end)
       })}
    end)

    defmodule HaltBatchProvider do
      @behaviour Handbeam.Agent.Provider

      def complete(_messages, _tools, _config) do
        step = Process.get(:halt_batch_step, 0)
        Process.put(:halt_batch_step, step + 1)

        calls =
          case step do
            0 ->
              [
                %{
                  type: "tool_use",
                  id: "d1",
                  name: "auto_review_marker",
                  input: %{"file" => "no-1"}
                }
              ]

            1 ->
              [
                %{
                  type: "tool_use",
                  id: "d2",
                  name: "auto_review_marker",
                  input: %{"file" => "no-2"}
                }
              ]

            _ ->
              [
                %{
                  type: "tool_use",
                  id: "d3",
                  name: "auto_review_marker",
                  input: %{"file" => "no-3"}
                },
                %{
                  type: "tool_use",
                  id: "ok",
                  name: "auto_review_marker",
                  input: %{"file" => "approved-sibling"}
                }
              ]
          end

        {:ok,
         %{
           stop_reason: :tool_use,
           messages: [Message.tool_use(calls)],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end

      def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
    end

    config = %Config{
      provider: HaltBatchProvider,
      model: "fake",
      max_turns: 8,
      working_directory: dir,
      middleware: [ToolGuard],
      provider_config: %{}
    }

    result = Turn.run_loop(State.init(config, "keep trying"), [])

    assert result.status == :halted
    refute File.exists?(Path.join(dir, "approved-sibling"))
    refute File.exists?(Path.join(dir, "no-3"))
  end

  test "a non-deny resets the consecutive counter and ten denies in the window stop" do
    ledger =
      AutoReview.record(AutoReview.initial_ledger(), [
        %{decision: :deny},
        %{decision: :deny},
        %{decision: :approve}
      ])

    refute ledger.stop
    assert ledger.consecutive_denies == 0

    mixed =
      Enum.flat_map(1..5, fn _ ->
        [%{decision: :deny}, %{decision: :deny}, %{decision: :approve}]
      end)

    stopped = AutoReview.record(AutoReview.initial_ledger(), mixed)
    assert stopped.stop
    assert Enum.count(stopped.recent, &(&1 == :deny)) == 10
  end

  test "ambiguous batch output fails closed" do
    requests = [%{tool_call_id: "a"}, %{tool_call_id: "b"}]

    assert {:error, :unattributable} =
             AutoReview.parse_decisions(~s({"decision":"approve","rationale":"ok"}), requests)

    assert {:ok, [%{tool_call_id: "only", decision: :approve}]} =
             AutoReview.parse_decisions(~s({"decision":"approve","rationale":"ok"}), [
               %{tool_call_id: "only"}
             ])
  end

  test "review prompt omits hidden reasoning and says the batch is out of bounds" do
    messages = [
      Message.user("please run the local check"),
      Message.assistant_blocks([
        %{type: "thinking", thinking: "SECRET_REASONING_abc"},
        %{type: "responses_reasoning", summary: "HIDDEN_SUMMARY_xyz"},
        %{type: "tool_use", id: "t1", name: "bash", input: %{"command" => "mix test"}}
      ])
    ]

    prompt =
      AutoReview.build_prompt(
        messages,
        [%{tool_call_id: "t1", tool_name: "bash", arguments: %{}}],
        "/tmp/ws"
      )

    assert prompt =~ "please run the local check"
    assert prompt =~ "out of bounds"
    assert prompt =~ "/tmp/ws"
    assert prompt =~ "tool_call_id=t1"
    refute prompt =~ "SECRET_REASONING_abc"
    refute prompt =~ "HIDDEN_SUMMARY_xyz"
    assert AutoReview.policy_text() =~ "cookie"
    assert AutoReview.policy_text() =~ "tools.allow"
  end
end
