defmodule Handbeam.Agent.CompactorTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.{Compactor, Config, Message, State}

  defmodule ProbeProvider do
    @behaviour Handbeam.Agent.Provider

    @impl Handbeam.Agent.Provider
    def complete(
          messages,
          tool_defs,
          %{summary_response: summary_response, test_pid: test_pid} = config
        ) do
      send(test_pid, {:summary_request, messages, tool_defs, config})

      case summary_response do
        {:ok, text} when is_binary(text) ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant(text)],
             usage: %{input_tokens: 5, output_tokens: 8},
             response_metadata: %{id: "summary-msg-001", model: "probe-model"}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl Handbeam.Agent.Provider
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp build_state(messages, opts \\ []) do
    provider = Keyword.get(opts, :provider, ProbeProvider)
    provider_config = Keyword.get(opts, :provider_config, %{})
    max_tokens = Keyword.get(opts, :max_tokens, 200)
    compaction = Keyword.get(opts, :compaction, reserve_tokens: 20, keep_recent_tokens: 20)
    on_compaction = Keyword.get(opts, :on_compaction)

    config =
      Config.from_opts(
        provider: provider,
        provider_config: provider_config,
        max_tokens: max_tokens,
        compaction: compaction,
        on_compaction: on_compaction
      )

    %State{config: config, messages: messages}
  end

  defp summary_text(label) do
    """
    ## Goal
    #{label} goal

    ## Constraints & Preferences
    - keep exact paths

    ## Progress
    ### Done
    - [x] #{label} done

    ### In Progress
    - [ ] #{label} in progress

    ### Blocked
    - (none)

    ## Key Decisions
    - **#{label} decision**: preserve evidence

    ## Evidence & References
    - /tmp/#{String.downcase(label)}.ex

    ## Next Steps
    1. Continue #{String.downcase(label)}

    ## Critical Context
    - #{label} context
    """
  end

  defp summary_message?(%Message{content: content}) when is_binary(content) do
    String.starts_with?(content, Compactor.summary_prefix())
  end

  defp summary_message?(_message), do: false

  defp tool_result_message?(%Message{role: :tool_result}), do: true

  defp tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_message), do: false

  defp assistant_tool_call_message?(%Message{role: :assistant, content: blocks})
       when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_use", "server_tool_use"] -> true
      _ -> false
    end)
  end

  defp assistant_tool_call_message?(_message), do: false

  defp tool_pairs_intact?(messages) do
    Enum.with_index(messages)
    |> Enum.all?(fn
      {%Message{} = message, index} when index > 0 ->
        if tool_result_message?(message) do
          assistant_tool_call_message?(Enum.at(messages, index - 1))
        else
          true
        end

      {%Message{} = message, 0} ->
        not tool_result_message?(message)
    end)
  end

  describe "maybe_compact/1" do
    test "returns state unchanged when within reserve budget" do
      messages = [Message.user("hello"), Message.assistant("hi")]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("unused")}, test_pid: self()}
        )

      assert {:unchanged, ^state} = Compactor.maybe_compact(state)
      refute_received {:summary_request, _, _, _}
    end

    test "invokes the provider summarizer and stores a synthetic summary message" do
      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("middle question"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Alpha")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert_received {:summary_request, [%Message{role: :user, content: prompt}], [], _config}
      assert prompt =~ "<conversation>"
      assert prompt =~ "## Goal"

      assert hd(compacted.messages).content == "original request"
      assert Enum.at(compacted.messages, 1).role == :user
      assert summary_message?(Enum.at(compacted.messages, 1))
      assert Enum.at(compacted.messages, 1).content =~ "Alpha goal"
    end

    test "preserves recent messages intact based on the keep_recent_tokens budget" do
      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 800)),
        Message.user(String.duplicate("b", 400)),
        Message.assistant("recent 1"),
        Message.user("recent 2"),
        Message.assistant("recent 3"),
        Message.user("recent 4"),
        Message.assistant("recent 5")
      ]

      state =
        build_state(messages,
          max_tokens: 260,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 50],
          provider_config: %{summary_response: {:ok, summary_text("Recent")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert Enum.take(compacted.messages, -5) == Enum.take(messages, -5)
    end

    test "updates the existing summary instead of duplicating it" do
      initial_messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("recent")
      ]

      first_state =
        build_state(initial_messages,
          max_tokens: 180,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("First")}, test_pid: self()}
        )

      {:compacted, first_compaction} = Compactor.maybe_compact(first_state)

      second_state = %{
        first_compaction
        | config: %{
            first_compaction.config
            | provider_config: %{
                summary_response: {:ok, summary_text("Updated")},
                test_pid: self()
              }
          },
          messages:
            first_compaction.messages ++
              [Message.assistant(String.duplicate("b", 900)), Message.user("new latest")]
      }

      {:compacted, second_compaction} = Compactor.maybe_compact(second_state)

      summary_messages = Enum.filter(second_compaction.messages, &summary_message?/1)

      assert length(summary_messages) == 1
      assert hd(summary_messages).content =~ "Updated goal"
      refute hd(summary_messages).content =~ "First goal"
    end

    test "never leaves a kept tool result without its assistant tool call" do
      big_result = String.duplicate("r", 900)

      messages = [
        Message.user("original"),
        Message.user("inspect the file"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "t1", name: "read_file", input: %{path: "lib/foo.ex"}}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "t1", content: big_result}
        ]),
        Message.assistant("analysis after tool"),
        Message.assistant("latest note")
      ]

      state =
        build_state(messages,
          max_tokens: 260,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 5],
          provider_config: %{summary_response: {:ok, summary_text("Tool")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert tool_pairs_intact?(Enum.drop(compacted.messages, 2))
      refute tool_result_message?(Enum.at(compacted.messages, 2))
    end

    test "can compact a large single turn by keeping an assistant suffix verbatim" do
      messages = [
        Message.user("original"),
        Message.user("one big turn"),
        Message.assistant(String.duplicate("a", 900)),
        Message.assistant(String.duplicate("b", 900)),
        Message.assistant("tail that should stay verbatim")
      ]

      state =
        build_state(messages,
          max_tokens: 300,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Split")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert summary_message?(Enum.at(compacted.messages, 1))
      assert Enum.at(compacted.messages, 2) == Enum.at(messages, 3)
      assert Enum.at(compacted.messages, 3) == Enum.at(messages, 4)
    end

    test "falls back to truncation when summary generation fails" do
      long_text = String.duplicate("a", 500)

      messages = [
        Message.user("original"),
        Message.assistant(long_text),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 120,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:error, :boom}, test_pid: self()}
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:compacted, compacted} = Compactor.maybe_compact(state)
          compacted_msg = Enum.at(compacted.messages, 1)
          assert String.length(compacted_msg.content) <= 203
          refute Enum.any?(compacted.messages, &summary_message?/1)
        end)

      assert log =~ "summary compaction failed, falling back to truncation"
    end
  end

  describe "on_compaction callback" do
    test "fires callback with messages about to be summarized" do
      test_pid = self()

      callback = fn middle_messages, state ->
        send(test_pid, {:compaction_fired, middle_messages, state})
        :ok
      end

      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle question"),
        Message.assistant("middle answer"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Callback")}, test_pid: self()},
          on_compaction: callback
        )

      {:compacted, _compacted} = Compactor.maybe_compact(state)

      assert_received {:compaction_fired, middle_messages, received_state}
      assert middle_messages != []
      assert %State{} = received_state
    end

    test "does not fire callback when within budget" do
      test_pid = self()

      callback = fn _middle, _state ->
        send(test_pid, :should_not_fire)
        :ok
      end

      messages = [Message.user("hi"), Message.assistant("hello")]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("unused")}, test_pid: self()},
          on_compaction: callback
        )

      {:unchanged, _result} = Compactor.maybe_compact(state)

      refute_received :should_not_fire
    end

    test "compaction proceeds even when on_compaction crashes" do
      callback = fn _middle, _state ->
        raise "Boom! Callback crashed!"
      end

      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider_config: %{summary_response: {:ok, summary_text("Crash")}, test_pid: self()},
          on_compaction: callback
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)
      assert %State{} = compacted
      assert Enum.any?(compacted.messages, &summary_message?/1)
    end
  end
end
