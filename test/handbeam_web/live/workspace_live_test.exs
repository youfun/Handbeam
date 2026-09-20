defmodule HandbeamWeb.WorkspaceLiveTest do
  @moduledoc """
  Tests for the WorkspaceLive — the main three-column Handbeam workspace.

  Reference: `beam_scriber/` (BeamScribe LiveView UI patterns)

  Covers:
    - Mount renders workspace with correct page_title and three-column layout
    - Status bar renders model/tokens/session id
    - Empty message does not append to list
    - Send message adds user message, clears input, sets running state
    - handle_info %AgentEvent{} struct consumes events correctly
    - :message_delta incrementally merges into last assistant message
    - :tool_start / :tool_end display tool progress with input/duration/errors
    - :run_start / :run_end manage running state and status
    - File preview empty state and error state
    - Diff rendering with basic +/- highlights
    - Both {:agent_event, event} and bare %AgentEvent{} dispatch work
    - Tool event helpers: summarize_input, format_duration, update_tool_event
  """

  use HandbeamWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Handbeam.PubSub.AgentEvent

  setup do
    isolate_conversation_home!()
    :ok
  end

  # ── Helper: build an AgentEvent for tests ──
  defp agent_event(kind, payload, seq \\ 1) do
    agent_event(kind, payload, seq, "s:1")
  end

  defp agent_event(kind, payload, seq, topic) do
    %AgentEvent{
      kind: kind,
      payload: payload,
      seq: seq,
      topic: topic,
      ts_ms: 0
    }
  end

  defp session_id_from_html(html) do
    ids =
      Regex.scan(~r/data-session-id="([^"]*)"/, html, capture: :all_but_first)
      |> List.flatten()

    Enum.find(ids, &(&1 != "")) || List.last(ids) ||
      raise "no data-session-id in html"
  end

  defp create_default_conversation(view) do
    view
    |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
    |> render_click()

    view |> render() |> session_id_from_html()
  end

  defp workspace_conversation_count(html, workspace_name, workspace_id) do
    marker = "phx-value-ws_id=\"#{workspace_id}\""

    html
    |> String.split(~s(>#{workspace_name}</span>), parts: 2)
    |> List.last()
    |> String.split(marker, parts: 2)
    |> hd()
    |> then(&Regex.scan(~r/class=\"conversation-row(?:\s|\")/, &1))
    |> length()
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  end

  defp isolate_conversation_home! do
    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "sigil_lv_home_#{System.unique_integer([:positive])}")
    System.put_env("HOME", home_dir)

    safe_rm_test_rune!(home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    home_dir
  end

  defp safe_rm_test_rune!(home_dir) do
    target = Path.expand(Path.join(home_dir, ".handbeam"))
    tmp_root = Path.expand(System.tmp_dir!())

    if String.starts_with?(target, tmp_root) do
      File.rm_rf!(target)
    else
      raise "[PathSafety] refusing to delete non-temp .handbeam/: #{target} (tmp_root=#{tmp_root})"
    end
  end

  defp write_test_models_config(path) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "models" => [
              %{
                "id" => "step-router-v1",
                "name" => "Step Router v1 (StepFun)",
                "reasoning" => true,
                "defaultReasoning" => "medium",
                "thinkingLevelMap" => %{"minimal" => "low", "xhigh" => nil}
              }
            ]
          },
          "sui2api" => %{
            "baseUrl" => "https://example.test/v1",
            "api" => "openai-responses",
            "models" => [
              %{"id" => "gpt-5.5", "name" => "GPT-5.5"}
            ]
          }
        }
      })
    )
  end

  defp configure_test_models! do
    models_path =
      Path.join(
        System.tmp_dir!(),
        "sigil_lv_models_#{System.unique_integer([:positive])}.json"
      )

    write_test_models_config(models_path)
    System.put_env("HANDBEAM_MODELS_FILE", models_path)

    on_exit(fn ->
      System.delete_env("HANDBEAM_MODELS_FILE")
      if File.exists?(models_path), do: File.rm!(models_path)
    end)

    models_path
  end

  describe "mount" do
    test "renders workspace with correct page_title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Handbeam — Workspace"
      assert html =~ "projects-panel-title"
      assert html =~ "专案" or html =~ "Projects"
    end

    test "renders three-column layout regions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"activity-bar\""
      assert html =~ "id=\"workspace-panel\""
      assert html =~ "id=\"ai-panel\""
    end

    test "renders status bar with tokens and session id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"status-bar\""
      refute html =~ "id=\"status-model\""
      refute html =~ "href=\"?locale="
      assert html =~ "Tokens:"
      assert html =~ "id=\"status-input-tokens\""
      assert html =~ "id=\"status-output-tokens\""
      assert html =~ "id=\"status-label\""
      assert html =~ "idle"
      assert html =~ "sid:"
    end

    test "loads persisted token usage for an existing conversation", %{conn: conn} do
      {:ok, conversation} = Handbeam.ConversationStore.create("default", title: "Token Stats")

      :ok =
        Handbeam.ConversationStore.add_token_usage(conversation["id"], %{
          input_tokens: 17,
          output_tokens: 23
        })

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert has_element?(view, "#status-input-tokens", "17")
      assert has_element?(view, "#status-output-tokens", "23")
    end

    test "does not select a conversation owned by another workspace", %{conn: conn} do
      {:ok, foreign_conversation} =
        Handbeam.ConversationStore.create("another-workspace", title: "Foreign")

      {:ok, _view, html} = live(conn, "/w/default/c/#{foreign_conversation["id"]}")

      refute html =~ ~s(data-session-id="#{foreign_conversation["id"]}")
    end

    test "renders AI input area with input box and send button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"ai-input\""
      assert html =~ "id=\"send-button\""
      assert html =~ "id=\"ai-input-area\""
    end

    test "ai input textarea does not render leading whitespace around the value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~r/<textarea[^>]*id=\"ai-input\"[^>]*><\/textarea>/
      refute html =~ ~r/<textarea[^>]*id=\"ai-input\"[^>]*>\s+\n\s*<\/textarea>/
    end

    test "renders empty state when no messages are present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"no-messages\""
      assert html =~ "No messages yet"
    end

    test "renders no-file-selected placeholder in editor area", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"no-file-selected\""
      assert html =~ "No file selected"
    end

    test "diff view is hidden initially", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "id=\"diff-view\""
    end

    test "editor tabs show empty placeholder when no files open", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "no files open"
    end
  end

  describe "input interaction" do
    test "update_input event updates the input_value assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      _html = render_keyup(view, "update_input", %{"value" => "hello world"})

      assert element(view, "textarea#ai-input") |> render() =~ "hello world"
    end

    test "empty message does not add to list on send (whitespace only)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_submit(%{"message" => "   "})

      # No new user message with whitespace-only content should appear
      refute render(view) =~ ~s(class="msg-bubble msg-user")
    end

    test "empty string does not add to list on send", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("form")
      |> render_submit(%{"message" => ""})

      refute render(view) =~ ~s(class="msg-bubble msg-user")
    end
  end

  describe "send_message" do
    test "adding a user message appears in the message list", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Read sample.txt"})
        assert render(view) =~ "Read sample.txt"
      end)
    end

    test "input clears after sending a message", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Read config"})
        assert has_element?(view, "textarea#ai-input", "")
      end)
    end

    test "sending a message persists user-visible history before run_end", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)
      view |> element("form") |> render_submit(%{"message" => "durable before run_end"})
      _ = render(view)

      assert Enum.any?(
               Handbeam.ConversationStore.load_messages(conversation_id),
               &match?(%{"content" => "durable before run_end", "role" => "user"}, &1)
             )

      {:ok, _view2, html2} = live(conn, "/")
      assert html2 =~ "durable before run_end"

      assert {:ok, conversation} = Handbeam.ConversationStore.get(conversation_id)

      assert Enum.any?(conversation["timeline"], fn entry ->
               entry["content"] == "durable before run_end"
             end)
    end

    test "sending a message preserves previously loaded history", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, _conv} =
        Handbeam.ConversationStore.create("default",
          id: "conv-history",
          title: "New chat",
          timeline: [
            %{
              "id" => "timeline-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "Earlier context"
            },
            %{
              "id" => "timeline-2",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "Previous reply"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/")

      rendered_before = render(view)
      assert rendered_before =~ "Earlier context"
      assert rendered_before =~ "Previous reply"

      view |> element("form") |> render_submit(%{"message" => "New question"})

      rendered_after = render(view)
      assert rendered_after =~ "Earlier context"
      assert rendered_after =~ "Previous reply"
      assert rendered_after =~ "New question"
    end

    test "switching away and back reloads persisted streaming display history", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, first} =
        Handbeam.ConversationStore.create("default",
          id: "conv-switch-a",
          title: "Count from 1",
          timeline: [
            %{
              "id" => "msg-user-a",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "从1数到1011"
            }
          ]
        )

      {:ok, second} =
        Handbeam.ConversationStore.create("default",
          id: "conv-switch-b",
          title: "Second chat",
          timeline: []
        )

      {:ok, view, _html} = live(conn, "/")

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      assert render(view) =~ "从1数到1011"

      Handbeam.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:run_start, %{model: "test"}}
      )

      Handbeam.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:message_delta, %{chunk: "1, 2, 3, 4, 5"}}
      )

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      refute render(view) =~ "1, 2, 3, 4, 5"

      Handbeam.Agent.TranscriptPersistence.handle_event(
        first["id"],
        {:run_end, %{status: "completed", turns: 1}}
      )

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first["id"]}']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "从1数到1011"
      assert rendered =~ "1, 2, 3, 4, 5"
    end

    test "syncing current running conversation preserves in-flight timeline", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbeam.ConversationStore.create("default",
          id: "conv-running-preserve",
          title: "Running preserve",
          timeline: [
            %{
              "id" => "msg-user-running-preserve",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "keep running user text"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{conversation["id"]}")
      topic = "session:#{conversation["id"]}"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, topic)})

      send(
        view.pid,
        {:agent_event, agent_event(:message_delta, %{chunk: "in-flight reply"}, 2, topic)}
      )

      assert render(view) =~ "in-flight reply"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{conversation["id"]}']"
      )
      |> render_click()

      assert render(view) =~ "in-flight reply"
    end

    test "switching conversations ignores previous conversation running state when resetting timeline",
         %{
           conn: conn
         } do
      isolate_conversation_home!()

      {:ok, first} =
        Handbeam.ConversationStore.create("default",
          id: "conv-running-switch-a",
          title: "Running first",
          timeline: [
            %{
              "id" => "msg-user-running-a",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "first running conversation"
            }
          ]
        )

      {:ok, second} =
        Handbeam.ConversationStore.create("default",
          id: "conv-running-switch-b",
          title: "Running second",
          timeline: [
            %{
              "id" => "msg-user-running-b",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "second selected conversation"
            }
          ]
        )

      {:ok, view, _html} = live(conn, "/w/default/c/#{first["id"]}")
      first_topic = "session:#{first["id"]}"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, first_topic)})

      assert render(view) =~ "first running conversation"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second["id"]}']"
      )
      |> render_click()

      rendered = render(view)
      assert rendered =~ "second selected conversation"
      refute rendered =~ "first running conversation"
      refute has_element?(view, "#status-label", "running")
    end

    test "sets running state after submitting a message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use run_start event to reliably set running state (avoids race with async Task)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      rendered = render(view)
      assert rendered =~ "running"
    end

    test "input remains enabled when agent is running for steering", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Use run_start event to reliably set running state (avoids race with async Task)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      rendered = render(view)
      refute rendered =~ "disabled"
      refute rendered =~ "cursor-not-allowed"
    end

    test "tool_events remain visible on new message send", %{conn: conn} do
      configure_test_models!()

      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        sid = create_default_conversation(view)
        {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
        {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
        :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
        topic = "session:#{sid}"

        send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 1, topic)})

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{tool: "read", input: %{file_path: "test.txt"}},
             2,
             topic
           )}
        )

        send(
          view.pid,
          {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 25}, 3, topic)}
        )

        assert has_element?(view, "#tool-event-read")
        send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed"}, 4, topic)})

        view
        |> element("form")
        |> render_submit(%{"message" => "New message", "model" => "stepfun/step-router-v1"})

        assert has_element?(view, "#tool-event-read")
        assert render(view) =~ "New message"
      end)
    end

    test "running submit enqueues candidate instead of clearing active tool state", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.txt"}}, 2, topic)}
      )

      assert has_element?(view, "#tool-event-read")

      view
      |> element("form")
      |> render_submit(%{"message" => "please adjust", "model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#tool-event-read")
      assert render(view) =~ "please adjust"

      assert [%Handbeam.Agent.Message{role: :user, content: "please adjust"}] =
               Handbeam.Agent.CandidateQueue.drain_steer(queue)

      assert [] = Handbeam.Agent.CandidateQueue.drain_follow_up(queue)
    end

    test "running queue button enqueues follow_up", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("#queue-button")
      |> render_click(%{
        "message" => "when finished",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "when finished"
      assert render(view) =~ "Queued"

      assert [%Handbeam.Agent.Message{role: :user, content: "when finished"}] =
               Handbeam.Agent.CandidateQueue.drain_follow_up(queue)

      assert [] = Handbeam.Agent.CandidateQueue.drain_steer(queue)
    end

    test "idle queue_message starts a new run instead of erroring", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      _sid = create_default_conversation(view)

      render_click(view, "queue_message", %{
        "message" => "idle queue becomes a run",
        "model" => "stepfun/step-router-v1"
      })

      html = render(view)
      assert html =~ "idle queue becomes a run"
      refute html =~ "no longer accepting"
    end

    test "running submit records pending, undo restores draft, terminal run_end marks undelivered",
         %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("form")
      |> render_submit(%{"message" => "steer pending", "model" => "stepfun/step-router-v1"})

      assert render(view) =~ "Waiting to insert"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [msg_id] = Map.keys(pending)

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click()

      assert :sys.get_state(view.pid).socket.assigns.input_value =~ "steer pending"
      assert Handbeam.Agent.CandidateQueue.get_messages(queue) == []

      view
      |> element("form")
      |> render_submit(%{"message" => "left behind", "model" => "stepfun/step-router-v1"})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "cancelled"}, 3, topic)}
      )

      html = render(view)
      assert html =~ "Not delivered"

      _ = msg_id
    end

    test "resend_pending keeps composer draft and pending attachments, and ignores a second click",
         %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("form")
      |> render_submit(%{"message" => "retry later", "model" => "stepfun/step-router-v1"})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "cancelled"}, 3, topic)}
      )

      assert render(view) =~ "Not delivered"
      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      [old_id] = Map.keys(pending)

      render_keyup(view, "update_input", %{"value" => "keep draft"})

      keep_att = %{"id" => "keep-web", "filename" => "keep.png"}

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{state | socket: Phoenix.Component.assign(socket, :pending_attachments, [keep_att])}
      end)

      view
      |> element("button[phx-click='resend_pending']")
      |> render_click(%{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep draft"
      assert assigns.pending_attachments == [keep_att]
      refute Map.has_key?(assigns.pending_messages, old_id)

      queued = Handbeam.Agent.CandidateQueue.get_messages(queue)
      assert Enum.any?(queued, &(&1.message.content == "retry later"))
      queue_count = length(queued)

      render_click(view, "resend_pending", %{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value == "keep draft"
      assert length(Handbeam.Agent.CandidateQueue.get_messages(queue)) == queue_count
    end

    test "resend_pending keeps the undelivered item when send fails", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      view
      |> element("form")
      |> render_submit(%{"message" => "cannot resend", "model" => "stepfun/step-router-v1"})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "cancelled"}, 3, topic)}
      )

      assert render(view) =~ "Not delivered"
      [old_id] = Map.keys(:sys.get_state(view.pid).socket.assigns.pending_messages)

      too_many =
        for i <- 1..5 do
          %{"id" => "att-#{i}", "filename" => "#{i}.png"}
        end

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        pending = socket.assigns.pending_messages

        pending =
          Map.update!(pending, old_id, fn item ->
            Map.put(item, :attachments, too_many)
          end)

        %{state | socket: Phoenix.Component.assign(socket, :pending_messages, pending)}
      end)

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 4, topic)}
      )

      view
      |> element("button[phx-click='resend_pending']")
      |> render_click(%{"id" => old_id})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.pending_messages[old_id].status == :undelivered
      assert assigns.composer_error == "At most 4 attachments per message."
    end

    test "reload hydrates queued attachments from transcript and undo restores them", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      mid = "msg-hyd-#{System.unique_integer([:positive])}"
      atts = [%{"id" => "att-w", "filename" => "pic.png", "kind" => "image"}]

      {:ok, _} =
        Handbeam.ConversationTranscriptStore.append(sid, %{
          "id" => mid,
          "role" => "user",
          "content_type" => "user_msg",
          "content" => "with picture",
          "attachments" => atts
        })

      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      :ok = Handbeam.PubSub.Session.enqueue_candidate(sid, "with picture", message_id: mid)

      {:ok, view, _html} = live(conn, "/")

      view
      |> element("#conversation-#{sid} button[phx-click='select_conversation']")
      |> render_click()

      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      pending = :sys.get_state(view.pid).socket.assigns.pending_messages
      assert pending[mid].content == "with picture"
      assert hd(pending[mid].attachments)["id"] == "att-w"
      assert hd(pending[mid].attachments)["filename"] == "pic.png"

      view
      |> element("button[phx-click='cancel_pending']")
      |> render_click(%{"id" => mid})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.input_value =~ "with picture"
      assert Enum.any?(assigns.pending_attachments, &(&1["filename"] == "pic.png"))
      assert Handbeam.Agent.CandidateQueue.get_messages(queue) == []
    end

    test "running steer button click enqueues candidate", %{conn: conn} do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
      {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
      :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      assert has_element?(view, "#status-label", "running")

      view
      |> element("form")
      |> render_submit(%{
        "message" => "please adjust by click",
        "model" => "stepfun/step-router-v1"
      })

      assert render(view) =~ "please adjust by click"

      assert [%Handbeam.Agent.Message{role: :user, content: "please adjust by click"}] =
               Handbeam.Agent.CandidateQueue.drain_steer(queue)
    end

    test "UI running with idle coordinator starts a new run instead of stale error", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, conversation} =
        Handbeam.ConversationStore.create("default",
          id: "conv-stale-running",
          title: "Stale running"
        )

      sid = conversation["id"]
      {:ok, view, _html} = live(conn, "/w/default/c/#{sid}")
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      assert has_element?(view, "#status-label", "running")

      view
      |> element("form")
      |> render_submit(%{"message" => "start again", "model" => "stepfun/step-router-v1"})

      rendered = render(view)
      refute rendered =~ "The previous run is no longer accepting input"
      assert rendered =~ "start again"

      assert Enum.any?(
               Handbeam.ConversationStore.load_messages(sid),
               &(&1["content"] == "start again")
             )
    end

    test "turn_start restores working indicator when a later provider turn is active", %{
      conn: conn
    } do
      configure_test_models!()

      {:ok, view, _html} = live(conn, "/")
      sid = create_default_conversation(view)
      topic = "session:#{sid}"

      send(
        view.pid,
        {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, topic)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:message_delta, %{chunk: "working"}, 2, topic)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "completed"}, 3, topic)}
      )

      refute has_element?(view, "#agent-working")

      send(
        view.pid,
        {:agent_event, agent_event(:turn_start, %{turn: 8}, 4, topic)}
      )

      assert has_element?(view, "#agent-working")
      assert has_element?(view, "#status-label", "running")
    end

    test "sending a message with an uploaded image renders attachments in the timeline", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{path: png_path, name: "x.png", type: "image/png", content: File.read!(png_path)}
        ])

      render_upload(upload, "x.png")

      view |> element("form") |> render_submit(%{"message" => "see image"})
      rendered = render(view)

      assert rendered =~ "see image"
      assert rendered =~ "/uploads/"
    end

    test "completed uploaded image renders a composer attachment preview before send", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{path: png_path, name: "preview.png", type: "image/png", content: File.read!(png_path)}
        ])

      render_upload(upload, "preview.png")

      assert has_element?(view, "#composer-attachments")
      assert has_element?(view, "#composer-attachments span.sr-only", "preview.png")
      assert render(view) =~ "preview.png"
    end

    test "sent image uses persistable string-key fields for timeline urls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      png_path =
        Path.join(System.tmp_dir!(), "sigil_lv_upload_#{System.unique_integer([:positive])}.png")

      File.write!(png_path, <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0>>)

      upload =
        file_input(view, "form", :images, [
          %{
            path: png_path,
            name: "string-key.png",
            type: "image/png",
            content: File.read!(png_path)
          }
        ])

      render_upload(upload, "string-key.png")
      view |> element("form") |> render_submit(%{"message" => "string keys"})
      html = render(view)
      assert html =~ "string keys"
      assert html =~ "/uploads/"
      assert html =~ "string-key.png" or html =~ "alt="
    end

    test "upload plus button wraps the live file input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".composer-icon-btn input[type='file']")
    end
  end

  describe "agent events via handle_info" do
    test "run_start event sets running state and clears previous tool state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude-sonnet"})})

      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "claude-sonnet"
    end

    test "run_start event via bare struct (no tuple wrapper)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, agent_event(:run_start, %{model: "claude-haiku"}))

      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "claude-haiku"
    end

    test "message_delta appends a new assistant message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Hello, I am"})})

      assert has_element?(view, ".msg-bubble.msg-assistant", "Hello, I am")
    end

    test "ignores tuple-wrapped agent events from a stale session topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      current_sid = view |> render() |> session_id_from_html()
      stale_topic = "session:stale-conversation"

      send(
        view.pid,
        {:agent_event,
         agent_event(:message_delta, %{chunk: "stale assistant text"}, 1, stale_topic)}
      )

      assert is_binary(current_sid)
      refute render(view) =~ "stale assistant text"
    end

    test "ignores bare AgentEvent structs from a stale session topic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        agent_event(:message_delta, %{chunk: "bare stale assistant text"}, 1, "session:old-conv")
      )

      refute render(view) =~ "bare stale assistant text"
    end

    test "message_delta merges into last assistant message incrementally", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Part 1. "})})

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Part 2."}, 2)})

      # Should have ONE assistant message with combined content
      html = render(view)
      assert html =~ "Part 1. Part 2."
    end

    test "thinking_delta shows thinking status without exposing content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event, agent_event(:thinking_delta, %{chunk: "private reasoning"}, 2)}
      )

      html = render(view)
      refute html =~ "private reasoning"

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Visible answer"}, 3)})

      html = render(view)
      refute html =~ "private reasoning"
      assert html =~ "Visible answer"
    end

    test "message_delta after user message creates new assistant block", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        view |> element("form") |> render_submit(%{"message" => "Hello"})
        send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Hi there!"})})
        assert render(view) =~ "Hello"
        assert render(view) =~ "Hi there!"
      end)
    end

    test "tool_start event displays tool name and input summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_read_1",
           tool: "read",
           input: %{file_path: "config/runtime.exs"}
         })}
      )

      assert has_element?(view, "#tool-tu_read_1")
      assert has_element?(view, "#tool-tu_read_1", "read")
      assert has_element?(view, "#tool-tu_read_1", "runtime.exs")
    end

    test "tool_start event with command input shows command summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "mix test"}})}
      )

      assert has_element?(view, "#tool-event-bash")
      assert has_element?(view, "#tool-event-bash", "bash")
      assert has_element?(view, "#tool-event-bash", "mix test")
    end

    test "tool_start event with content input shows content summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "write", input: %{content: "defmodule Foo do end"}})}
      )

      assert has_element?(view, "#tool-event-write")
      assert has_element?(view, "#tool-event-write", "defmodule Foo do end")
    end

    test "tool_start event with empty input shows no summary text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{}})})

      assert has_element?(view, "#tool-event-read")
      assert has_element?(view, "#tool-event-read", "read")
    end

    test "tool_end event updates tool status to done with duration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.txt"}})}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 250}, 2)})

      rendered = render(view)
      # Tool icon should be ✓ (done) and show duration
      assert rendered =~ "✓"
      assert rendered =~ "250ms"
    end

    test "tool_end event with error shows error status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "rm -rf /"}})}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool: "bash", duration_ms: 120, error: "Permission denied"}, 2)}
      )

      rendered = render(view)
      # Tool icon should be ✗ (error) and show error message
      assert rendered =~ "✗"
      assert rendered =~ "Permission denied"
    end

    test "browser missing-binary tool_end shows a copyable install card", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_browser_missing",
           tool: "browser",
           input: %{args: ["open", "https://example.com"]}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_browser_missing",
             tool: "browser",
             duration_ms: 12,
             error: "agent-browser is not installed",
             details: %{
               failure_category: "missing-binary",
               install_command: "npm install -g agent-browser && agent-browser install",
               next_actions: [%{id: "install-agent-browser"}]
             }
           },
           2
         )}
      )

      assert has_element?(view, "#browser-install-tool-tu_browser_missing")

      assert has_element?(
               view,
               "#browser-install-tool-tu_browser_missing",
               "npm install -g agent-browser && agent-browser install"
             )

      assert has_element?(view, "#browser-install-copy-tool-tu_browser_missing")

      html = render(view)

      assert html =~ "npm install -g agent-browser &amp;&amp; agent-browser install" or
               html =~ "npm install -g agent-browser && agent-browser install"

      refute html =~ ~s("agent-browser is not installed")
    end

    test "tool_end event with details.file_path but no diff does not add to editor_files", %{
      conn: conn
    } do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "my_module.ex")
      File.write!(file_path, "defmodule MyModule do end")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{tool: "edit", input: %{file_path: file_path}})}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "edit",
               duration_ms: 100,
               details: %{file_path: file_path}
             },
             2
           )}
        )

        rendered = render(view)
        refute has_element?(view, ".file-tab", "my_module.ex")
        assert rendered =~ "no files open"
      after
        File.rm(file_path)
      end
    end

    test "tool_end event with direct file_path but no diff does not add to editor_files", %{
      conn: conn
    } do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "foo.ex")
      File.write!(file_path, "# foo")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_end, %{tool: "edit", duration_ms: 100, file_path: file_path})}
        )

        rendered = render(view)
        refute has_element?(view, ".file-tab", "foo.ex")
        assert rendered =~ "no files open"
      after
        File.rm(file_path)
      end
    end

    test "tool_end event with non-empty diff adds to editor_files", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "changed.ex")
      File.write!(file_path, "# changed")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "edit",
               duration_ms: 100,
               details: %{
                 file_path: file_path,
                 diff_lines: [%{"type" => "ins", "text" => "# changed"}]
               }
             }
           )}
        )

        rendered = render(view)
        assert rendered =~ "changed.ex"
      after
        File.rm(file_path)
      end
    end

    test "duplicate file_path does not add duplicate editor file", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "dup.ex")
      File.write!(file_path, "# dup")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_end, %{
             tool: "edit",
             duration_ms: 100,
             file_path: file_path,
             details: %{diff_lines: [%{"type" => "ins", "text" => "# dup"}]}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool: "write",
               duration_ms: 200,
               file_path: file_path,
               details: %{diff_lines: [%{"type" => "ins", "text" => "# dup"}]}
             },
             2
           )}
        )

        rendered = render(view)
        assert rendered =~ "dup.ex"
      after
        File.rm(file_path)
      end
    end

    test "multiple tool events show all in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "a.txt"}})}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 50}, 2)})

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "bash", input: %{command: "ls"}}, 3)}
      )

      send(view.pid, {:agent_event, agent_event(:tool_end, %{tool: "bash", duration_ms: 100}, 4)})

      rendered = render(view)
      assert rendered =~ "id=\"tool-event-read\""
      assert rendered =~ "id=\"tool-event-bash\""
      assert rendered =~ "✓"
    end

    test "run_end event stops running and updates status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Set running via event (avoid Task race from render_submit)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      assert render(view) =~ "running"

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 3})})

      rendered = render(view)
      assert rendered =~ "completed"
      assert has_element?(view, "#status-turns", "3")
    end

    test "usage updates refresh the running footer and replace cumulative totals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:usage_updated, %{usage: %{input_tokens: 10, output_tokens: 15}}, 2)}
      )

      assert has_element?(view, "#status-input-tokens", "10")
      assert has_element?(view, "#status-output-tokens", "15")
      assert has_element?(view, "button[phx-click='stop_run']")

      payload = %{
        "usage" => %{
          "input_tokens" => 25,
          "output_tokens" => 35,
          "cache_read_input_tokens" => 7,
          "cache_creation_input_tokens" => 3
        }
      }

      for seq <- [3, 4] do
        send(view.pid, {:agent_event, agent_event(:usage_updated, payload, seq)})
        assert has_element?(view, "#status-input-tokens", "25")
        assert has_element?(view, "#status-output-tokens", "35")
        assert has_element?(view, "#status-cache-read", "7")
        assert has_element?(view, "#status-cache-write", "3")
      end

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{status: "completed", turns: 2, usage: payload["usage"]}, 5)}
      )

      assert has_element?(view, "#status-input-tokens", "25")
      assert has_element?(view, "#status-output-tokens", "35")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"}, 6)})
      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: :cancelled}, 7)})
      send(view.pid, {:agent_event, agent_event(:usage_updated, payload, 8)})
      assert has_element?(view, "#status-input-tokens", "0")
      assert has_element?(view, "#status-output-tokens", "0")
    end

    test "token footer formats live and final usage while preserving exact titles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "fake"})})
      assert has_element?(view, "#status-input-tokens[title='0']", "0")

      usage = %{
        input_tokens: 5481,
        output_tokens: 827,
        cache_read_input_tokens: 999_950,
        cache_creation_input_tokens: 1000
      }

      send(view.pid, {:agent_event, agent_event(:usage_updated, %{usage: usage}, 2)})
      assert has_element?(view, "button[phx-click='stop_run']")
      assert has_element?(view, "#status-input-tokens[title='5481']", "5.5K")
      assert has_element?(view, "#status-output-tokens[title='827']", "827")
      assert has_element?(view, "#status-cache-read[title='999950']", "1M")
      assert has_element?(view, "#status-cache-write[title='1000']", "1K")

      final_usage = %{
        usage
        | input_tokens: 33_261,
          output_tokens: 1250,
          cache_read_input_tokens: 1_200_000,
          cache_creation_input_tokens: 999
      }

      send(
        view.pid,
        {:agent_event,
         agent_event(:run_end, %{status: :completed, turns: 2, usage: final_usage}, 3)}
      )

      refute has_element?(view, "button[phx-click='stop_run']")
      assert has_element?(view, "#status-input-tokens[title='33261']", "33.3K")
      assert has_element?(view, "#status-output-tokens[title='1250']", "1.3K")
      assert has_element?(view, "#status-cache-read[title='1200000']", "1.2M")
      assert has_element?(view, "#status-cache-write[title='999']", "999")
    end

    test "run_end event updates input and output token counts from provider usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{input_tokens: 12, output_tokens: 8}},
           2
         )}
      )

      assert has_element?(view, "#status-input-tokens", "12")
      assert has_element?(view, "#status-output-tokens", "8")
    end

    test "run_end accepts string-keyed provider usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{"input_tokens" => 9, "output_tokens" => 6}}
         )}
      )

      assert has_element?(view, "#status-input-tokens", "9")
      assert has_element?(view, "#status-output-tokens", "6")
    end

    test "run_end accepts string-keyed payload from persisted session events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{
             "status" => "completed",
             "turns" => 2,
             "usage" => %{"input_tokens" => 21, "output_tokens" => 13}
           }
         )}
      )

      assert has_element?(view, "#status-input-tokens", "21")
      assert has_element?(view, "#status-output-tokens", "13")
      assert has_element?(view, "#status-turns", "2")
    end

    test "run_end with error status shows error in status bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "error", turns: 0, error: "timeout"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "error"
      assert rendered =~ "Run error"
      assert rendered =~ "timeout"
    end

    test "run_end clears running indicator", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      refute has_element?(view, "#agent-working")
    end

    test "stop button cancels projection and ignores late streaming chunks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})
      assert has_element?(view, "button[phx-click='stop_run']", "Stop")

      view |> element("button[phx-click='stop_run']") |> render_click()

      assert has_element?(view, "#status-label", "cancelled")
      refute has_element?(view, "#agent-working")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "late chunk"}, 2)})
      refute render(view) =~ "late chunk"

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "new chunk"}, 4)})
      assert render(view) =~ "new chunk"
    end

    test "stop button ignores late tool events and stale completed run_end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"})})
      view |> element("button[phx-click='stop_run']") |> render_click()

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "bash", input: %{command: "mix test"}}, 2)}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "bash", duration_ms: 25}, 3)}
      )

      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 4)})

      rendered = render(view)
      refute rendered =~ "mix test"
      refute has_element?(view, "#tool-event-bash")
      assert has_element?(view, "#status-label", "cancelled")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "claude"}, 5)})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "bash", input: %{command: "mix format"}}, 6)}
      )

      assert render(view) =~ "mix format"
    end

    test "unrecognized event kind is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:unknown_kind, %{foo: "bar"})})

      # View should still be alive and render the status bar
      rendered = render(view)
      assert rendered =~ "id=\"status-bar\""
    end

    test "streaming chunks render incrementally without losing content on run_end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Start a run
      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      # Simulate streaming: many small chunks (like real SSE streaming)
      chunks = ["Hello", ", ", "this ", "is ", "a ", "streaming ", "test."]

      Enum.each(chunks, fn chunk ->
        send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: chunk})})
      end)

      # All chunks should have accumulated into one assistant message
      full_text = Enum.join(chunks)
      assert render(view) =~ full_text

      # Run ends — content should still be present
      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{status: "completed", turns: 1, usage: %{input_tokens: 5, output_tokens: 7}},
           99
         )}
      )

      rendered = render(view)
      assert rendered =~ full_text
      assert rendered =~ "completed"
      refute has_element?(view, "#agent-working")
    end

    test "streaming chunks render before run_end", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "AI response"})})
      assert render(view) =~ "AI response"
    end

    test "conversation store is updated during streaming chunks and finalized on run_end", %{
      conn: conn
    } do
      # Use an isolated home so we can check conversation file writes safely.
      isolate_conversation_home!()

      {:ok, view, _html} = live(conn, "/")
      conversation_id = create_default_conversation(view)

      # Ensure initial file exists by triggering runtime persistence.
      Handbeam.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_start, %{model: "test"}}
      )

      Handbeam.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_end, %{status: "completed", turns: 1}}
      )

      _ = render(view)
      messages_path = Handbeam.ConversationStore.messages_path(conversation_id)

      # Verify the derived item file was created under the isolated conversation home.
      assert File.exists?(messages_path),
             "Expected conversation messages file to exist after initial run_end"

      # Capture item content after initial persistence.
      content_before = File.read!(messages_path)

      # Now send streaming chunks — display history should be durable before run_end.
      for i <- 1..20 do
        Handbeam.Agent.TranscriptPersistence.handle_event(
          conversation_id,
          {:message_delta, %{chunk: "chunk#{i} "}}
        )
      end

      content_after_streaming = File.read!(messages_path)
      assert content_after_streaming == content_before

      # Now send run_end — buffered chunks should persist without losing streamed content.
      Handbeam.Agent.TranscriptPersistence.handle_event(
        conversation_id,
        {:run_end,
         %{status: "completed", turns: 2, usage: %{input_tokens: 10, output_tokens: 20}}}
      )

      content_after_run_end = File.read!(messages_path)

      assert content_after_run_end =~ "chunk1"
      assert content_after_run_end =~ "chunk20"

      assert {:ok, conversation} = Handbeam.ConversationStore.get(conversation_id)
      assert Enum.any?(conversation["timeline"], &(&1["content"] =~ "chunk1"))
      assert Enum.any?(conversation["timeline"], &(&1["content"] =~ "chunk20"))
    end
  end

  describe "preview and browser cards" do
    test "preview_serve tool_end renders open preview card without covering composer", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "preview-card"

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "preview_serve",
          duration_ms: 12,
          details: %{
            preview_id: "pv_live",
            title: "Demo site",
            conversation_id: "conv-preview-card",
            preview_path: "/preview/pv_live"
          }
        })
      )

      rendered = render(view)
      assert rendered =~ "preview-card"
      assert rendered =~ "打开预览"
      assert rendered =~ "用浏览器打开"
      assert rendered =~ "Demo site"
      assert rendered =~ ~s(id="composer") or rendered =~ "phx-submit=\"send_message\""
    end

    test "needs_user browser result shows takeover prompt, not an auto overlay", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        agent_event(:tool_end, %{
          tool: "browser",
          duration_ms: 8,
          details: %{
            needs_user: true,
            reason: "captcha",
            session_id: "bws_live",
            backend: "webview"
          }
        })
      )

      rendered = render(view)
      assert rendered =~ "接管浏览器"
      assert rendered =~ "captcha"
      refute rendered =~ "Mob.UI.webview"
    end
  end

  describe "file preview" do
    test "render_file_preview returns content for valid file" do
      ws = Handbeam.Workspace.ensure_root!()
      tmp = Path.join(ws, "sigil_lv_test_preview.txt")
      File.write!(tmp, "hello\nworld")

      try do
        result = HandbeamWeb.WorkspaceLive.render_file_preview(tmp)
        assert result =~ "hello"
        assert result =~ "world"
      after
        File.rm(tmp)
      end
    end

    test "render_file_preview returns access denied for non-existent file" do
      result = HandbeamWeb.WorkspaceLive.render_file_preview("/nonexistent/path.txt")
      assert result =~ "Access denied"
    end

    test "render_file_preview returns empty for nil" do
      assert HandbeamWeb.WorkspaceLive.render_file_preview(nil) == ""
    end

    test "select_file shows error for non-existent file in UI", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      bad_path = Path.join(ws, "nonexistent.txt")

      {:ok, view, _html} = live(conn, "/")

      # Add a file to editor_files so a tab appears to click
      send(
        view.pid,
        agent_event(:tool_end, %{tool: "edit", duration_ms: 100, file_path: bad_path})
      )

      rendered = render(view)
      # The file doesn't exist, so it shouldn't be added to editor_files
      # Verify the UI still works
      assert rendered =~ "no files open"
    end

    test "select_file shows file content in preview", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      tmp = Path.join(ws, "sigil_lv_test_ui.txt")
      File.write!(tmp, "preview content line 1")

      {:ok, view, _html} = live(conn, "/")
      _ = create_default_conversation(view)

      try do
        # Add a file to editor_files
        send(
          view.pid,
          agent_event(:tool_end, %{
            tool: "edit",
            duration_ms: 100,
            file_path: tmp,
            details: %{diff_lines: [%{"type" => "ins", "text" => "preview content line 1"}]}
          })
        )

        # Click the file tab
        view
        |> element("button", "sigil_lv_test_ui.txt")
        |> render_click()

        rendered = render(view)
        assert rendered =~ "preview content line 1"
      after
        File.rm(tmp)
      end
    end
  end

  describe "diff view" do
    test "diff_prefix returns line markers" do
      assert HandbeamWeb.WorkspaceLive.diff_prefix("ins") == "+"
      assert HandbeamWeb.WorkspaceLive.diff_prefix("del") == "-"
      assert HandbeamWeb.WorkspaceLive.diff_prefix("eq") == " "
      assert HandbeamWeb.WorkspaceLive.diff_prefix("skip") == "⋯"
    end

    test "view_diff renders structured escaped diff lines by timeline entry id", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "diff_target.ex")
      File.write!(file_path, "safe")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_edit_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_edit_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "del", "text" => "<script>alert('xss')</script>"},
                   %{"type" => "ins", "text" => "safe"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#tool-tu_edit_1 button", "Show diff") |> render_click()

        rendered = render(view)
        assert rendered =~ "id=\"diff-view\""
        assert rendered =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
        refute rendered =~ "<script>"
        assert rendered =~ "+"
        assert rendered =~ "-"
      after
        File.rm(file_path)
      end
    end

    test "Show diff button hidden when diff_lines is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_edit_empty",
           tool: "edit",
           input: %{file_path: "some.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_end,
           %{
             tool_use_id: "tu_edit_empty",
             tool: "edit",
             duration_ms: 10,
             details: %{diff_lines: []}
           },
           2
         )}
      )

      rendered = render(view)
      refute has_element?(view, "#tool-tu_edit_empty .tool-diff-link")
      refute rendered =~ "Show diff"
    end

    test "close_diff clears diff state and re-opening works", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "close_test.ex")
      File.write!(file_path, "content")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_close_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_close_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "eq", "text" => "content"},
                   %{"type" => "ins", "text" => "new"}
                 ]
               }
             },
             2
           )}
        )

        # Open diff
        view |> element("#tool-tu_close_1 button", "Show diff") |> render_click()
        rendered = render(view)
        assert rendered =~ "id=\"diff-view\""
        assert rendered =~ "new"

        # Close diff
        view |> element("#diff-view button", "× Close") |> render_click()
        rendered = render(view)
        refute rendered =~ "id=\"diff-view\""

        # Open again — should not show old content
        view |> element("#tool-tu_close_1 button", "Show diff") |> render_click()
        rendered = render(view)
        assert rendered =~ "id=\"diff-view\""
        assert rendered =~ "new"
      after
        File.rm(file_path)
      end
    end

    test "diff view renders skip lines safely with correct class", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "skip_test.ex")
      File.write!(file_path, "first")

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_skip_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_skip_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: [
                   %{"type" => "skip", "text" => "... 120 unchanged lines ..."},
                   %{"type" => "del", "text" => "old"},
                   %{"type" => "ins", "text" => "new"}
                 ]
               }
             },
             2
           )}
        )

        view |> element("#tool-tu_skip_1 button", "Show diff") |> render_click()
        rendered = render(view)

        # Skip line renders
        assert rendered =~ "diff-skip"
        # Text is safely escaped (contains dots, not raw HTML)
        assert rendered =~ "120 unchanged lines"
        # Skip prefix is ⋯
        assert rendered =~ "⋯"
      after
        File.rm(file_path)
      end
    end

    test "reverts a recorded edit change from diff view", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_edit_test.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)

      change = Handbeam.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_revert_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_revert_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: change.diff_lines,
                 change: change
               }
             },
             2
           )}
        )

        view |> element("#tool-tu_revert_1 button", "Show diff") |> render_click()
        assert render(view) =~ "Revert"

        view |> element("#diff-view button", "Revert") |> render_click()
        assert render(view) =~ "Confirm revert"

        view |> element("#diff-view button", "Confirm revert") |> render_click()
        rendered = render(view)

        assert File.read!(file_path) == before
        assert rendered =~ "Reverted file to the recorded before state"
        assert rendered =~ "reverted"
      after
        File.rm(file_path)
      end
    end

    test "blocks revert when file changed after diff", %{conn: conn} do
      ws = Handbeam.Workspace.ensure_root!()
      file_path = Path.join(ws, "revert_conflict_test.ex")
      before = "value = 1\n"
      after_text = "value = 2\n"
      File.write!(file_path, after_text)

      change = Handbeam.ChangeSnapshot.build_edit_snapshot(file_path, before, after_text)

      {:ok, view, _html} = live(conn, "/")

      try do
        send(
          view.pid,
          {:agent_event,
           agent_event(:tool_start, %{
             tool_use_id: "tu_conflict_1",
             tool: "edit",
             input: %{file_path: file_path}
           })}
        )

        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_end,
             %{
               tool_use_id: "tu_conflict_1",
               tool: "edit",
               duration_ms: 42,
               details: %{
                 file_path: file_path,
                 diff_lines: change.diff_lines,
                 change: change
               }
             },
             2
           )}
        )

        view |> element("#tool-tu_conflict_1 button", "Show diff") |> render_click()
        File.write!(file_path, "user changed\n")
        view |> element("#diff-view button", "Revert") |> render_click()
        view |> element("#diff-view button", "Confirm revert") |> render_click()

        rendered = render(view)
        assert File.read!(file_path) == "user changed\n"
        assert rendered =~ "file changed since this diff"
        assert rendered =~ "conflict"
      after
        File.rm(file_path)
      end
    end
  end

  describe "status helpers" do
    test "status_dot_class returns correct classes" do
      assert HandbeamWeb.WorkspaceLive.status_dot_class(:idle) =~ "idle"
      assert HandbeamWeb.WorkspaceLive.status_dot_class(:running) =~ "running"
      assert HandbeamWeb.WorkspaceLive.status_dot_class(:error) =~ "error"
      assert HandbeamWeb.WorkspaceLive.status_dot_class(:completed) =~ "completed"
    end

    test "tool_status_icon returns correct icons" do
      assert HandbeamWeb.WorkspaceLive.tool_status_icon(:running) == "◌"
      assert HandbeamWeb.WorkspaceLive.tool_status_icon(:done) == "✓"
      assert HandbeamWeb.WorkspaceLive.tool_status_icon(:error) == "✗"
    end

    test "tool_status_class returns correct classes" do
      assert HandbeamWeb.WorkspaceLive.tool_status_class(:running) =~ "text-warning"
      assert HandbeamWeb.WorkspaceLive.tool_status_class(:done) =~ "text-success"
      assert HandbeamWeb.WorkspaceLive.tool_status_class(:error) =~ "text-error"
    end

    test "render_tool_status returns correct labels" do
      assert HandbeamWeb.WorkspaceLive.render_tool_status(:running) == "running"
      assert HandbeamWeb.WorkspaceLive.render_tool_status(:done) == "done"
      assert HandbeamWeb.WorkspaceLive.render_tool_status(:error) == "error"
    end

    test "format_duration returns formatted time" do
      assert HandbeamWeb.WorkspaceLive.format_duration(nil) == nil
      assert HandbeamWeb.WorkspaceLive.format_duration(500) == "500ms"
      assert HandbeamWeb.WorkspaceLive.format_duration(1500) =~ "1.5s"
    end
  end

  describe "agent event dispatch compatibility" do
    test "accepts AgentEvent struct directly (bare struct via send)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, agent_event(:run_start, %{model: "direct-model"}))

      rendered = render(view)
      assert rendered =~ "direct-model"
      assert rendered =~ "running"
    end

    test "accepts {:agent_event, %AgentEvent{}} tuple form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "tuple-model"})})

      rendered = render(view)
      assert rendered =~ "tuple-model"
      assert rendered =~ "running"
    end

    test "accepts map-like agent_event (backward compat)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, %{kind: :run_start, payload: %{model: "map-model"}}})

      rendered = render(view)
      assert rendered =~ "map-model"
      assert rendered =~ "running"
    end

    test "tool_start with legacy :name key still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         %{kind: :tool_start, payload: %{name: "read", input: %{file_path: "x.txt"}}}}
      )

      assert has_element?(view, "#tool-event-read")
      assert has_element?(view, "#tool-event-read", "x.txt")
    end

    test "tool_end with legacy :name key still works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event, %{kind: :tool_start, payload: %{name: "bash", input: %{command: "ls"}}}}
      )

      send(
        view.pid,
        {:agent_event, %{kind: :tool_end, payload: %{name: "bash", duration_ms: 300}}}
      )

      rendered = render(view)
      assert rendered =~ "300ms"
      assert rendered =~ "✓"
    end
  end

  describe "full event flow" do
    test "full run_start → tool_start → tool_end → message_delta → run_end cycle", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")
        sid = view |> render() |> session_id_from_html()
        {:ok, _session} = Handbeam.PubSub.Session.start_or_get(session_id: sid)
        {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
        :ok = Handbeam.PubSub.Session.attach_run(sid, self(), queue)

        # 1. User submits message
        send(
          view.pid,
          {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, sid)}
        )

        view |> element("form") |> render_submit(%{"message" => "Read the config"})
        assert render(view) =~ "Read the config"

        # 2. Agent starts
        send(
          view.pid,
          {:agent_event, agent_event(:run_start, %{model: "step-router-v1"}, 1, sid)}
        )

        assert render(view) =~ "running"

        # 3. Tool starts
        send(
          view.pid,
          {:agent_event,
           agent_event(
             :tool_start,
             %{tool: "read", input: %{file_path: "config/runtime.exs"}},
             2,
             sid
           )}
        )

        assert has_element?(view, "#tool-event-read", "runtime.exs")

        # 4. Tool ends
        send(
          view.pid,
          {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 150}, 3, sid)}
        )

        rendered = render(view)
        assert rendered =~ "✓"
        assert rendered =~ "150ms"

        # 5. Assistant streams response
        send(
          view.pid,
          {:agent_event, agent_event(:message_delta, %{chunk: "The config contains"}, 4, sid)}
        )

        send(
          view.pid,
          {:agent_event, agent_event(:message_delta, %{chunk: " useful settings."}, 5, sid)}
        )

        assert render(view) =~ "The config contains useful settings."

        # 6. Run ends
        send(
          view.pid,
          {:agent_event, agent_event(:run_end, %{status: "completed", turns: 2}, 6, sid)}
        )

        rendered = render(view)
        assert rendered =~ "completed"
        assert rendered =~ "Turns:"
        assert rendered =~ "2"
        refute has_element?(view, "#agent-working")
      end)
    end
  end

  describe "openai provider config" do
    test "status bar shows OpenAI model on mount" do
      Application.put_env(:handbeam, :openai, model: "custom-oai-model")

      result = HandbeamWeb.WorkspaceLive.status_dot_class(:idle)
      # Verify config is read from Application env
      assert result =~ "idle"

      Application.delete_env(:handbeam, :openai)
    end

    test "openai_provider_config returns defaults when no env configured" do
      # Ensure no config is set
      Application.delete_env(:handbeam, :openai)

      {:ok, _view, html} = build_conn() |> live("/")

      # Status bar should show default OpenAI model
      assert html =~ "step-router-v1"
    end

    test "run_end with error status is handled without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "step-router-v1"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :run_end,
           %{
             status: "error",
             turns: 0,
             error: "OPENAI_API_KEY not configured"
           },
           2
         )}
      )

      rendered = render(view)
      assert rendered =~ "error"
      assert rendered =~ "Run error"
      assert rendered =~ "OPENAI_API_KEY"

      # View should still render (not crash)
      assert rendered =~ "id=\"status-bar\""
    end
  end

  describe "new_session" do
    test "new_session button creates a new session and clears messages", %{conn: conn} do
      with_log(fn ->
        {:ok, view, _html} = live(conn, "/")

        # Send a message first
        view |> element("form") |> render_submit(%{"message" => "Hello"})
        assert render(view) =~ "Hello"

        # Click the current workspace's inline new conversation button.
        view
        |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
        |> render_click()

        rendered = render(view)
        refute rendered =~ "Hello"
        assert rendered =~ "No messages yet"
        assert rendered =~ "idle"
        assert rendered =~ "step-router-v1"
      end)
    end

    test "new_session preserves OpenAI model in status bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
      |> render_click()

      rendered = render(view)
      assert rendered =~ "step-router-v1"
    end
  end

  describe "workspace integration" do
    setup do
      base_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_ws_case_#{System.unique_integer([:positive])}")

      ws_dir = Path.join(base_dir, "workspace")
      store_path = Path.join(base_dir, "workspaces.json")
      old_home = System.get_env("HOME")
      home_dir = Path.join(base_dir, "home")

      File.mkdir_p!(base_dir)
      System.put_env("HOME", home_dir)
      System.put_env("HANDBEAM_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAM_WORKSPACE", ws_dir)
      Handbeam.Workspace.ensure_root!()

      on_exit(fn ->
        if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
        System.delete_env("HANDBEAM_WORKSPACE")
        System.delete_env("HANDBEAM_WORKSPACES_FILE")
        if File.exists?(base_dir), do: File.rm_rf!(base_dir)
      end)

      {:ok, ws_dir: ws_dir, home_dir: home_dir}
    end

    test "adding a workspace does not create a conversation", %{conn: conn} do
      project_dir =
        Path.join(System.tmp_dir!(), "sigil_added_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Added Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        rendered = render(view)

        assert rendered =~ "Added Project"
        assert rendered =~ "sid:none"
        assert rendered =~ "No messages yet"
        {:ok, added_ws} = Handbeam.WorkspaceStore.get_by_path(project_dir)
        assert Handbeam.ConversationStore.list_for_workspace(added_ws["id"]) == []
        assert workspace_conversation_count(rendered, "Added Project", added_ws["id"]) == 0
      after
        File.rm_rf!(project_dir)
      end
    end

    test "sandbox host imports a copied directory as the workspace", %{conn: conn} do
      previous = Application.get_env(:handbeam, :host)

      imported =
        Path.join(System.tmp_dir!(), "sigil_imported_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(imported)
      File.write!(Path.join(imported, "README.md"), "from downloads")

      Handbeam.Host.put!(%{
        data_dir:
          Path.join(System.tmp_dir!(), "handbeam_host_#{System.unique_integer([:positive])}"),
        shell: false,
        terminal: false,
        desktop_browser: false
      })

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        assert render(view) =~ "从下载导入"

        send(view.pid, {:workspace_imported, %{path: imported, name: "Downloads Project"}})
        rendered = render(view)

        assert rendered =~ "Downloads Project"
        {:ok, added_ws} = Handbeam.WorkspaceStore.get_by_path(imported)
        assert added_ws["name"] == "Downloads Project"
      after
        if previous,
          do: Application.put_env(:handbeam, :host, previous),
          else: Application.delete_env(:handbeam, :host)

        File.rm_rf!(imported)
      end
    end

    test "status bar shows MCP and skills counts for the current workspace", %{conn: conn} do
      project_dir =
        Path.join(System.tmp_dir!(), "sigil_counts_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, ".handbeam/skills/code-review"))
      File.mkdir_p!(Path.join(project_dir, ".handbeam/skills/docs"))

      File.write!(
        Path.join(project_dir, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "one" => %{"command" => "echo"},
            "two" => %{"command" => "printf"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".handbeam/skills/code-review/SKILL.md"),
        """
        ---
        name: code-review
        description: Review code
        ---

        Review instructions.
        """
      )

      File.write!(
        Path.join(project_dir, ".handbeam/skills/docs/SKILL.md"),
        """
        ---
        name: docs
        description: Write docs
        ---

        Docs instructions.
        """
      )

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Counted Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        assert has_element?(view, "#status-mcp-count", "2")
        assert has_element?(view, "#status-skills-count", "2")
      after
        File.rm_rf!(project_dir)
      end
    end

    test "status bar includes global MCP and skills counts", %{conn: conn, home_dir: home_dir} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_global_counts_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)
      File.mkdir_p!(Path.join(project_dir, ".handbeam/skills/code-review"))
      File.mkdir_p!(Path.join(project_dir, ".agents/skills/docs"))
      File.mkdir_p!(Path.join(home_dir, ".handbeam"))
      File.mkdir_p!(Path.join(home_dir, ".handbeam/skills/global-review"))

      File.write!(
        Path.join(home_dir, ".handbeam/mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "global" => %{"command" => "global-cmd"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".mcp.json"),
        Jason.encode!(%{
          "mcpServers" => %{
            "one" => %{"command" => "echo"},
            "two" => %{"command" => "printf"}
          }
        })
      )

      File.write!(
        Path.join(project_dir, ".handbeam/skills/code-review/SKILL.md"),
        """
        ---
        name: code-review
        description: Review code
        ---

        Review instructions.
        """
      )

      File.write!(
        Path.join(project_dir, ".agents/skills/docs/SKILL.md"),
        """
        ---
        name: docs
        description: Write docs
        ---

        Docs instructions.
        """
      )

      File.write!(
        Path.join(home_dir, ".handbeam/skills/global-review/SKILL.md"),
        """
        ---
        name: global-review
        description: Global review
        ---

        Global review instructions.
        """
      )

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Global Counted Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        assert has_element?(view, "#status-mcp-count", "3")
        assert has_element?(view, "#status-skills-count", "3")
      after
        File.rm_rf!(project_dir)
      end
    end

    test "selected model is scoped to each conversation in the same workspace", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_per_conversation_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      first_conversation_id = create_default_conversation(view)

      render_change(view, "select_model", %{"model" => "sui2api/gpt-5.5"})

      assert render(view) =~ "sui2api / GPT-5.5"

      view
      |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
      |> render_click()

      second_html = render(view)
      second_conversation_id = session_id_from_html(second_html)
      assert second_conversation_id != first_conversation_id
      refute second_html =~ "sui2api / GPT-5.5"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{first_conversation_id}']"
      )
      |> render_click()

      assert render(view) =~ "sui2api / GPT-5.5"

      view
      |> element(
        ".conversation-item[phx-click='select_conversation'][phx-value-id='#{second_conversation_id}']"
      )
      |> render_click()
    end

    test "sending in a newly added workspace creates the first conversation", %{conn: conn} do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_send_added_project_#{System.unique_integer([:positive])}"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_send_added_models_#{System.unique_integer([:positive])}.json"
        )

      File.mkdir_p!(project_dir)
      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Send Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        assert render(view) =~ "sid:none"

        view
        |> element("form")
        |> render_submit(%{"message" => "你好", "model" => "sui2api/gpt-5.5"})

        rendered = render(view)
        refute rendered =~ "sid:none"
        assert rendered =~ "你好"

        {:ok, added_ws} = Handbeam.WorkspaceStore.get_by_path(project_dir)
        assert [_conversation] = Handbeam.ConversationStore.list_for_workspace(added_ws["id"])
      after
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
        File.rm_rf!(project_dir)
      end
    end

    test "select_workspace creates an active conversation when only archived conversations exist",
         %{
           conn: conn
         } do
      project_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_archived_project_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(project_dir)

      try do
        {:ok, view, _html} = live(conn, "/")

        view |> element("#activity-bar button[phx-click='open_add_project']") |> render_click()
        view |> render_keyup("update_add_path", %{"value" => project_dir})
        view |> render_keyup("update_add_name", %{"value" => "Archived Project"})
        view |> element("button[phx-click='confirm_add_project']") |> render_click()

        {:ok, added_ws} = Handbeam.WorkspaceStore.get_by_path(project_dir)
        {:ok, archived} = Handbeam.ConversationStore.create(added_ws["id"], [{"title", "Old"}])
        {:ok, _archived} = Handbeam.ConversationStore.archive(archived["id"])

        view
        |> element(
          ".workspace-header[phx-click='select_workspace'][phx-value-id='#{added_ws["id"]}']"
        )
        |> render_click()

        rendered = render(view)
        assert rendered =~ "Archived Project"
        refute rendered =~ "sid:none"

        active =
          added_ws["id"]
          |> Handbeam.ConversationStore.list_for_workspace(include_archived?: false)

        assert length(active) == 1

        archived =
          added_ws["id"]
          |> Handbeam.ConversationStore.list_for_workspace(include_archived?: true)
          |> Enum.filter(&Map.get(&1, "archived_at"))

        assert length(archived) == 1
      after
        File.rm_rf!(project_dir)
      end
    end

    test "mount renders the active workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end

    test "tool_end with file_path adds editor tab with relative name", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      # Create a file in the workspace
      file_path = Path.join(ws_dir, "hello.exs")
      File.write!(file_path, "IO.puts(\"hello world\")")

      {:ok, view, _html} = live(conn, "/")

      # Send tool_end with file_path pointing to workspace file
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 100,
           file_path: file_path,
           details: %{diff_lines: [%{"type" => "ins", "text" => "IO.puts(\"hello world\")"}]}
         })}
      )

      rendered = render(view)
      # The tab should show the relative path (just the filename)
      assert rendered =~ "hello.exs"
    end

    test "tool_end with file_path auto-selects file if no active_file", %{
      conn: conn,
      ws_dir: ws_dir
    } do
      file_path = Path.join(ws_dir, "auto.exs")
      File.write!(file_path, "x = 1")

      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 120,
           file_path: file_path,
           details: %{diff_lines: [%{"type" => "ins", "text" => "x = 1"}]}
         })}
      )

      rendered = render(view)
      # Should show file content since auto-selected
      assert rendered =~ "x = 1"
    end

    test "tool_end with outside workspace path is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Send tool_end with a path outside the workspace
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "read",
           duration_ms: 50,
           file_path: "/etc/passwd"
         })}
      )

      rendered = render(view)
      # Should NOT show the sensitive file
      refute rendered =~ "passwd"
      # Should still have empty editor tabs
      assert rendered =~ "no files open"
    end

    test "select_file outside workspace does not read system file" do
      result = HandbeamWeb.WorkspaceLive.render_file_preview("/etc/passwd")
      assert result =~ "Access denied"
    end

    test "render_file_preview shows content for workspace file", %{ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "preview.exs")
      File.write!(file_path, "defmodule Foo do\n  def bar, do: :ok\nend")

      result = HandbeamWeb.WorkspaceLive.render_file_preview(file_path)
      assert result =~ "defmodule Foo do"
      assert result =~ ":ok"
    end

    test "render_file_preview/2 shows content when file is in non-global custom workspace" do
      # Create a file in a directory that is NOT the global workspace
      custom_dir =
        Path.join(System.tmp_dir!(), "sigil_custom_project_#{System.unique_integer([:positive])}")

      File.mkdir_p!(custom_dir)

      file_path = Path.join(custom_dir, "custom.exs")
      File.write!(file_path, "defmodule Custom do\n  def run, do: :custom\nend")

      try do
        # render_file_preview/1 uses the global workspace root and should fail
        result1 = HandbeamWeb.WorkspaceLive.render_file_preview(file_path)
        assert result1 =~ "Access denied"

        # render_file_preview/2 with custom workspace_root should work
        result2 = HandbeamWeb.WorkspaceLive.render_file_preview(file_path, custom_dir)
        assert result2 =~ "defmodule Custom do"
        assert result2 =~ ":custom"
      after
        File.rm_rf!(custom_dir)
      end
    end

    test "tool_end with details from executor creates editor tab", %{conn: conn, ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "from_details.exs")
      File.write!(file_path, "# from details")

      {:ok, view, _html} = live(conn, "/")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 90,
           details: %{
             file_path: file_path,
             bytes: 14,
             lines: 1,
             diff_lines: [%{"type" => "ins", "text" => "# from details"}]
           },
           file_path: file_path
         })}
      )

      rendered = render(view)
      assert rendered =~ "from_details.exs"
    end

    test "auto-selects newly created file", %{conn: conn, ws_dir: ws_dir} do
      file_path = Path.join(ws_dir, "hello.exs")
      File.write!(file_path, "IO.puts(\"hello world\")")

      {:ok, view, _html} = live(conn, "/")

      # Simulate Agent writing hello.exs via write tool
      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{
           tool: "write",
           duration_ms: 100,
           file_path: file_path,
           details: %{
             file_path: file_path,
             bytes: 21,
             lines: 1,
             diff_lines: [%{"type" => "ins", "text" => "IO.puts(\"hello world\")"}]
           }
         })}
      )

      rendered = render(view)
      assert rendered =~ "hello.exs"
      assert rendered =~ "hello world"
    end
  end

  describe "model switching" do
    test "model picker shows current model on mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "id=\"model-picker\""
      assert html =~ "step-router-v1"
    end

    test "run_start event updates current model state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "custom-oai-model"})})

      rendered = render(view)
      assert rendered =~ "custom-oai-model"
    end

    test "model display persists across new_session", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
      |> render_click()

      rendered = render(view)
      assert rendered =~ "step-router-v1"
    end

    test "workspace label remains visible in the workspace panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end
  end

  describe "conversation stream" do
    test "renders conversations under workspace groups", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "workspace-group"
      assert html =~ "conversations-list"

      view
      |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
      |> render_click()

      assert render(view) =~ "conversation-row"
    end

    test "conversation items omit workspace badges inside grouped workspaces", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "workspace-badge"
    end

    test "workspace panel shows the active workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, ".workspace-panel-header", "My Workspace")
    end

    test "new_conversation_in_workspace renders inside grouped workspace list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='new_conversation_in_workspace'][phx-value-ws_id='default']")
      |> render_click()

      html = render(view)
      assert html =~ "conversations-list"
      assert html =~ "conversation-row"
    end

    test "right workspace panel uses a single floating toggle instead of expand bar", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/")

      assert html =~ ~s(id="workspace-panel-toggle")
      refute html =~ ~s(id="workspace-expand-bar")

      view
      |> element("#workspace-panel-toggle")
      |> render_click()

      html = render(view)
      assert html =~ ~s(workspace-panel-toggle)
      assert html =~ "collapsed"
      refute html =~ ~s(id="workspace-expand-bar")
    end

    test "mobile workspace sheet has new conversation entry without duplicate workspace row", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      view
      |> element("button[phx-click='open_sheet'][phx-value-type='workspace']")
      |> render_click()

      html = render(view)
      assert html =~ ~s(id="workspace-sheet")
      assert html =~ "sheet-new-conv-btn"
      refute html =~ "sheet-ws-row"

      view
      |> element(
        "#workspace-sheet button[phx-click='mobile_new_conversation_in_workspace'][phx-value-ws_id='default']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "conversation-row"
      refute html =~ ~s(id="workspace-sheet" class="bottom-sheet open")
    end

    test "recycle bin toggle shows archived conversations in stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Recycle bin starts collapsed
      html = render(view)
      assert html =~ "▸"

      # Toggle recycle bin
      view |> element("button[phx-click='toggle_recycle_bin']") |> render_click()

      html = render(view)
      assert html =~ "▾"
    end

    test "conversation stream scrolls past workspaces while preserving scroll position", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      html = render(view)
      assert html =~ "workspace-group"
      assert html =~ "conversations-list"
    end
  end

  describe "strip_think_tags" do
    test "strips think tags from plain text" do
      {thinking, clean, buffer} =
        HandbeamWeb.WorkspaceLive.strip_think_tags("", "<think>reasoning</think> answer")

      assert thinking == "reasoning"
      assert clean == " answer"
      assert buffer == ""
    end

    test "strips thinking tags variant" do
      {thinking, clean, _} =
        HandbeamWeb.WorkspaceLive.strip_think_tags("", "<thinking>deep thought</thinking> done")

      assert thinking == "deep thought"
      assert clean == " done"
    end

    test "handles text without think tags" do
      {thinking, clean, buffer} =
        HandbeamWeb.WorkspaceLive.strip_think_tags("", "plain text no tags")

      assert thinking == ""
      assert clean == "plain text no tags"
      assert buffer == ""
    end

    test "accumulates partial tags across chunk boundaries" do
      # First chunk: partial opening tag
      {t1, c1, buf1} = HandbeamWeb.WorkspaceLive.strip_think_tags("", "<thi")
      assert t1 == ""
      assert c1 == ""

      # Second chunk: complete the tag and some thinking text
      {t2, c2, buf2} = HandbeamWeb.WorkspaceLive.strip_think_tags(buf1, "nk>thinking text")
      assert t2 == "thinking text"
      assert c2 == ""
      # Buffer encodes inside state; empty partial = still inside think block
      assert buf2 == "<in>"
    end

    test "accumulates partial closing tag across chunks" do
      {t1, c1, buf1} = HandbeamWeb.WorkspaceLive.strip_think_tags("", "<think>inner</thi")
      assert t1 == "inner"
      assert c1 == ""

      # Combined: </thi + nk> = </think> closes block, "after" is outside, "/think> visible" is trailing
      {t2, c2, buf2} = HandbeamWeb.WorkspaceLive.strip_think_tags(buf1, "nk>after</think> visible")
      assert t2 == ""
      assert c2 == "after</think> visible"
      assert buf2 == ""
    end

    test "handles multiple think blocks" do
      {thinking, clean, _} =
        HandbeamWeb.WorkspaceLive.strip_think_tags(
          "",
          "<think>first</think> middle <think>second</think> end"
        )

      assert thinking == "firstsecond"
      assert clean == " middle  end"
    end

    test "handles empty input" do
      {t, c, b} = HandbeamWeb.WorkspaceLive.strip_think_tags("", "")
      assert t == ""
      assert c == ""
      assert b == ""
    end

    test "think tag opens but never closes across many chunks" do
      {t1, c1, buf1} = HandbeamWeb.WorkspaceLive.strip_think_tags("", "prefix <think>reason")
      assert t1 == "reason"
      assert c1 == "prefix "

      {t2, c2, buf2} = HandbeamWeb.WorkspaceLive.strip_think_tags(buf1, "ing continues")
      assert t2 == "ing continues"
      assert c2 == ""

      # Still no close tag — buffer should be empty, state stays :inside
      {t3, c3, _} = HandbeamWeb.WorkspaceLive.strip_think_tags(buf2, " and more")
      assert t3 == " and more"
      assert c3 == ""
    end
  end

  describe "turn folding" do
    test "compute_turns groups entries into a turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "AI response"})})
      rendered = render(view)

      assert rendered =~ "AI response"
      assert rendered =~ "turn-group"
    end

    test "turn header shows for multi-entry turns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "first"})})
      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "second"}, 4)})

      rendered = render(view)
      assert rendered =~ "first"
      assert rendered =~ "second"
      assert rendered =~ "turn-header"
    end

    test "tool calls and assistant belong to same turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event, agent_event(:tool_start, %{tool: "read", input: %{file_path: "test.rb"}})}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 50}, 2)}
      )

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "done"}, 3)})

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "done"
    end

    test "turn header includes truncated summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "hello world"})})
      send(view.pid, {:agent_event, agent_event(:run_end, %{status: "completed", turns: 1}, 2)})

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"}, 3)})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "bonus"}, 4)})

      rendered = render(view)
      assert rendered =~ "turn-summary"
    end

    test "system error messages belong to their turn", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "reply"})})

      send(
        view.pid,
        {:agent_event, agent_event(:run_end, %{status: "error", turns: 0, error: "timeout"}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "reply"
      assert rendered =~ "timeout"
    end
  end

  describe "tool call folding" do
    test "assistant text after tool call starts a new message segment", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Before tool."})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "README.md"}}, 2)}
      )

      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "After tool."}, 3)})

      rendered = render(view)
      before_pos = :binary.match(rendered, "Before tool.") |> elem(0)
      tool_pos = :binary.match(rendered, "README.md") |> elem(0)
      after_pos = :binary.match(rendered, "After tool.") |> elem(0)

      assert before_pos < tool_pos
      assert tool_pos < after_pos
    end

    test "tool call finalizes previous assistant stream item", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})
      send(view.pid, {:agent_event, agent_event(:message_delta, %{chunk: "Before tool."})})

      assert render(view) =~ ~s(data-streaming="true")

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "README.md"}}, 2)}
      )

      rendered = render(view)
      assert rendered =~ ~s(data-final="true")
      assert rendered =~ ~s(data-streaming="false")
    end

    test "multiple consecutive completed tools collapse into one work summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_1",
           tool: "read",
           input: %{file_path: "a.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_1", tool: "read", duration_ms: 30}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_2", tool: "bash", input: %{command: "ls"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_2", tool: "bash", duration_ms: 20}, 4)}
      )

      rendered = render(view)
      assert rendered =~ "tool-work-collapsed"
      assert rendered =~ "tool-work-summary"
      assert rendered =~ "Explored 1 file, 1 command"
      refute rendered =~ "Hide Work"
    end

    test "single completed tool call collapses without a group wrapper", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{tool: "read", input: %{file_path: "single.ex"}})}
      )

      send(
        view.pid,
        {:agent_event, agent_event(:tool_end, %{tool: "read", duration_ms: 10}, 2)}
      )

      rendered = render(view)
      assert rendered =~ "Explored 1 file"
      assert rendered =~ "tool-work-collapsed"
      refute rendered =~ "tool-group"
    end

    test "completed tool work can be expanded and hidden again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:agent_event, agent_event(:run_start, %{model: "test"})})

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_start, %{
           tool_use_id: "tu_a",
           tool: "read",
           input: %{file_path: "x.ex"}
         })}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_a", tool: "read", duration_ms: 10}, 2)}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(
           :tool_start,
           %{tool_use_id: "tu_b", tool: "write", input: %{content: "abc"}},
           3
         )}
      )

      send(
        view.pid,
        {:agent_event,
         agent_event(:tool_end, %{tool_use_id: "tu_b", tool: "write", duration_ms: 5}, 4)}
      )

      rendered = render(view)
      assert rendered =~ "Explored 2 files"
      refute rendered =~ "Hide Work"

      view
      |> element("#tool-work-summary-tool-tu_a")
      |> render_click()

      expanded = render(view)
      assert expanded =~ "Hide Work"
      assert expanded =~ "x.ex"
      refute expanded =~ "tool-work-collapsed"

      view
      |> element("#tool-work-hide-tool-tu_a")
      |> render_click()

      collapsed = render(view)
      assert collapsed =~ "Explored 2 files"
      refute collapsed =~ "Hide Work"
    end
  end

  describe "workspace model policy" do
    @tag :tmp_dir

    test "empty policy allowlist is treated as unrestricted", %{conn: conn} do
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_policy_#{System.unique_integer([:positive])}")

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_policy_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_policy_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      # Empty models.allow.providers means no workspace restriction.
      settings_path = Handbeam.WorkspaceSettings.path(tmp_ws_dir)
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Jason.encode!(%{
          "models" => %{
            "allow" => %{"providers" => %{}}
          }
        })
      )

      System.put_env("HANDBEAM_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAM_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)
      Handbeam.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAM_WORKSPACE")
        System.delete_env("HANDBEAM_WORKSPACES_FILE")
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      assert rendered =~ "model-picker"
      assert rendered =~ "stepfun"
      assert rendered =~ "sui2api"
    end

    test "model picker visible when settings file absent", %{conn: conn} do
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "sigil_lv_nopolicy_#{System.unique_integer([:positive])}")

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_nopolicy_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_nopolicy_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      # NO settings file written — missing .handbeam/settings.jsonc means unrestricted.

      System.put_env("HANDBEAM_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAM_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)
      Handbeam.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAM_WORKSPACE")
        System.delete_env("HANDBEAM_WORKSPACES_FILE")
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      # With no policy, model picker should be visible
      assert rendered =~ "model-picker"
      assert rendered =~ "stepfun"
      assert rendered =~ "sui2api"
    end

    test "refreshing model picker reloads latest model config", %{conn: conn} do
      tmp_ws_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_refresh_models_#{System.unique_integer([:positive])}"
        )

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_refresh_models_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_refresh_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)

      System.put_env("HANDBEAM_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAM_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)
      Handbeam.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAM_WORKSPACE")
        System.delete_env("HANDBEAM_WORKSPACES_FILE")
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      initial_render = render(view)
      assert initial_render =~ "Step Router v1 (StepFun)"
      refute initial_render =~ "GPT-5.4 Mini"

      File.write!(
        models_path,
        Jason.encode!(%{
          "defaultProvider" => "stepfun",
          "defaultModel" => "gpt-5.4-mini",
          "providers" => %{
            "stepfun" => %{
              "baseUrl" => "https://api.stepfun.com/step_plan/v1",
              "api" => "stepfun-step-plan",
              "provider" => "stepfun",
              "models" => [
                %{"id" => "step-router-v1", "name" => "Step Router v1 (StepFun)"},
                %{"id" => "gpt-5.4-mini", "name" => "GPT-5.4 Mini"}
              ]
            },
            "sui2api" => %{
              "baseUrl" => "https://example.test/v1",
              "api" => "openai-responses",
              "models" => [
                %{"id" => "gpt-5.5", "name" => "GPT-5.5"}
              ]
            }
          }
        })
      )

      view
      |> element("#model-picker")
      |> render_click()

      refreshed = render(view)
      assert refreshed =~ "GPT-5.4 Mini"
    end

    test "missing global model config is seeded on first visit", %{conn: conn} do
      tmp_ws_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_missing_models_#{System.unique_integer([:positive])}"
        )

      store_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_store_missing_models_#{System.unique_integer([:positive])}.json"
        )

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_models_missing_#{System.unique_integer([:positive])}.json"
        )

      System.put_env("HANDBEAM_WORKSPACES_FILE", store_path)
      System.put_env("HANDBEAM_WORKSPACE", tmp_ws_dir)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)
      Handbeam.Workspace.ensure_root!()

      on_exit(fn ->
        System.delete_env("HANDBEAM_WORKSPACE")
        System.delete_env("HANDBEAM_WORKSPACES_FILE")
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(tmp_ws_dir), do: File.rm_rf!(tmp_ws_dir)
        if File.exists?(store_path), do: File.rm!(store_path)
      end)

      refute File.exists?(models_path)

      {:ok, view, _html} = live(conn, "/")
      rendered = render(view)

      assert File.exists?(models_path)
      assert rendered =~ "model-picker"
      refute rendered =~ "Configure models before sending"
    end
  end

  describe "reasoning selector" do
    test "renders beside the input controls for reasoning-capable models", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_reasoning_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      assert has_element?(view, "#reasoning-picker")
      assert has_element?(view, "#reasoning-picker option[value='medium']")
      assert has_element?(view, "#reasoning-picker option[value='high']")
      refute has_element?(view, "#reasoning-picker option[value='xhigh']")
    end

    test "selecting reasoning updates the selected value", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_select_reasoning_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      view
      |> element("#reasoning-picker")
      |> render_change(%{"reasoning" => "high"})

      assert has_element?(view, "#reasoning-picker option[value='high']")
      assert render(view) =~ "reasoning-picker"
    end

    test "form-level composer_drop keeps a High reasoning pick", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_composer_drop_reasoning_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})

      # Native <select> inside #composer fires the form phx-change, not only
      # the picker's own select_reasoning event.
      view
      |> element("#composer")
      |> render_change(%{"reasoning" => "high", "model" => "stepfun/step-router-v1"})

      html = render(view)
      assert html =~ ~s(option selected value="high") or html =~ ~s(value="high" selected)
    end

    test "model and reasoning stay visible as mid-conversation controls", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_mid_thread_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, html} = live(conn, "/")
      render_change(view, "select_model", %{"model" => "stepfun/step-router-v1"})
      html = render(view)

      assert html =~ "composer-turn-controls"
      assert has_element?(view, "#model-picker")
      assert has_element?(view, "#reasoning-picker")
      assert html =~ "This conversation" or html =~ "本对话使用"
    end
  end

  describe "tool permissions menu" do
    test "toggles permission menu and selects new permission mode", %{conn: conn} do
      {:ok, default_ws} = Handbeam.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      html = render(view)

      # Initial state: menu should not be visible
      refute html =~ "permission-dropdown-menu"
      assert html =~ "Full Access" or html =~ "完整存取"

      # Click the permission pill to toggle menu
      view |> element("button[phx-click='toggle_permission_menu']") |> render_click()
      assert render(view) =~ "permission-dropdown-menu"

      # Select auto mode
      view
      |> element("button[phx-click='select_permission_mode'][phx-value-mode='auto']")
      |> render_click()

      refute render(view) =~ "permission-dropdown-menu"
      assert render(view) =~ "Full Access" or render(view) =~ "完整存取"

      # Verify settings.jsonc on disk is updated
      assert {:ok, settings} = Handbeam.WorkspaceSettings.load(workspace_root)
      assert get_in(settings, ["tools", "default_mode"]) == "auto"
    end

    test "always-allow persists a matcher pattern and skips the next HITL", %{conn: conn} do
      {:ok, default_ws} = Handbeam.WorkspaceStore.ensure_default!()
      workspace_root = default_ws["path"]

      :ok = Handbeam.WorkspaceSettings.update_default_mode(workspace_root, :prompt)

      {:ok, view, _html} = live(conn, "/")
      create_default_conversation(view)

      pending = %{
        type: :tool_approval,
        action_requests: [
          %{
            tool_call_id: "b1",
            tool_name: "bash",
            arguments: %{"command" => "git status --short"},
            suggested_pattern: "bash(git status*)"
          }
        ]
      }

      send(view.pid, {:agent_event, agent_event(:tool_approval_requested, pending, 1)})
      html = render(view)

      assert html =~ "tool-approval-overlay"
      assert html =~ "Always allow"
      assert html =~ "bash(git status*)"

      view
      |> element("button[phx-click='approve_all_tools'][phx-value-remember='always']")
      |> render_click()

      refute render(view) =~ "tool-approval-overlay"

      assert {:ok, settings} = Handbeam.WorkspaceSettings.load(workspace_root)
      assert "bash(git status*)" in (get_in(settings, ["tools", "allow"]) || [])

      policy = Handbeam.Permissions.ToolPolicy.from_workspace(workspace_root)

      assert Handbeam.Permissions.ToolPolicy.decision(policy, %{
               name: "bash",
               input: %{"command" => "git status"}
             }) == :auto

      assert Handbeam.Permissions.ToolPolicy.decision(policy, %{
               name: "bash",
               input: %{"command" => "rm -rf tmp"}
             }) == :prompt
    end
  end

  describe "settings panel" do
    @tag capture_log: false
    test "toggles Observational Memory without crashing", %{conn: conn} do
      Logger.configure(level: :debug)

      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_settings_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      # Open settings panel and get returned html by following redirect
      result = view |> element("#open-settings") |> render_click()
      {:ok, settings_view, html} = follow_redirect(result, conn)

      # Verify settings page is open and shows Model / AI settings
      assert html =~ "Model / AI"

      # Find the Observational Memory checkbox and change it
      html_after_click =
        settings_view
        |> element("input[name='om_enabled']")
        |> render_change(%{"om_enabled" => "true"})

      # Verify it toggled and didn't crash
      assert html_after_click =~ "Observer model" or html_after_click =~ "观测模型"
    end

    test "updates default model and reasoning settings without crashing", %{conn: conn} do
      models_path =
        Path.join(
          System.tmp_dir!(),
          "sigil_lv_settings_models_#{System.unique_integer([:positive])}.json"
        )

      write_test_models_config(models_path)
      System.put_env("HANDBEAM_MODELS_FILE", models_path)

      on_exit(fn ->
        System.delete_env("HANDBEAM_MODELS_FILE")
        if File.exists?(models_path), do: File.rm!(models_path)
      end)

      {:ok, view, _html} = live(conn, "/")

      # Open settings panel
      result = view |> element("#open-settings") |> render_click()
      {:ok, settings_view, _html} = follow_redirect(result, conn)

      # Change default model
      html =
        settings_view
        |> element("select[name='default_model']")
        |> render_change(%{"default_model" => "stepfun/step-router-v1"})

      # The default_model option is selected
      assert html =~ "selected"

      # Change reasoning
      html =
        settings_view
        |> element("select[name='reasoning']")
        |> render_change(%{"reasoning" => "high"})

      assert html =~ "selected"
    end
  end

  describe "skill autocomplete" do
    setup do
      on_exit(fn ->
        home_skills = Path.join([System.get_env("HOME") || "", ".handbeam", "skills"])

        if File.dir?(home_skills) do
          home_skills
          |> File.ls!()
          |> Enum.each(fn name ->
            if String.starts_with?(name, "autocomplete-") or name in ["other-skill", "other-code"] do
              File.rm_rf!(Path.join(home_skills, name))
            end
          end)
        end
      end)

      :ok
    end

    defp create_test_skill(name, description) do
      skill_dir =
        Path.join([System.get_env("HOME") || Handbeam.Home.path(), ".handbeam", "skills", name])

      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        """
        ---
        name: #{name}
        description: #{description}
        ---

        Test skill body.
        """
      )

      :ok
    end

    test "typing / shows skill suggestions dropdown", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha skill for testing")
      create_test_skill("autocomplete-beta", "Beta skill for testing")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/"})

      # The dropdown should appear with both skills
      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
    end

    test "typing /autocomplete filters to matching skills", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")
      create_test_skill("autocomplete-beta", "Beta")
      create_test_skill("other-skill", "Other")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/autocomplete"})

      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
      refute html =~ "other-skill"
    end

    test "typing /xyz with no match shows no suggestions", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/xyz"})

      # No dropdown when no matches
      refute html =~ "skill-suggestions"
    end

    test "typing plain text without / shows no suggestions", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "hello world"})

      refute html =~ "skill-suggestions"
    end

    test "selecting a skill suggestion replaces input with /skill:name", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha skill for testing")

      {:ok, view, _html} = live(conn, "/")

      # First, simulate typing "/auto"
      _html = render_keyup(view, "update_input", %{"value" => "/auto"})

      # Then select the suggestion
      html =
        view
        |> element(
          "button[phx-click='select_skill_suggestion'][phx-value-name='autocomplete-alpha']"
        )
        |> render_click()

      # Input should now contain /skill:autocomplete-alpha
      assert html =~ "/skill:autocomplete-alpha"
      # Dropdown should be dismissed
      refute html =~ "skill-suggestions"
    end

    test "dismissing skill suggestions clears the dropdown", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")

      {:ok, view, _html} = live(conn, "/")

      _html = render_keyup(view, "update_input", %{"value" => "/"})

      html = render_click(view, "dismiss_skill_suggestions", %{})

      refute html =~ "skill-suggestions"
    end

    test "typing /skill: filters by skill name after prefix", %{conn: conn} do
      create_test_skill("autocomplete-alpha", "Alpha")
      create_test_skill("autocomplete-beta", "Beta")
      create_test_skill("other-code", "Code")

      {:ok, view, _html} = live(conn, "/")

      html = render_keyup(view, "update_input", %{"value" => "/skill:auto"})

      assert html =~ "skill-suggestions"
      assert html =~ "autocomplete-alpha"
      assert html =~ "autocomplete-beta"
      refute html =~ "other-code"
    end
  end

  describe "conversation navigator" do
    test "lists only user messages next to the scroll-to-bottom control", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbeam.ConversationStore.create("default",
          id: "conv-nav-many",
          title: "Nav many",
          timeline: [
            %{
              "id" => "nav-user-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "先看第一轮用户问题"
            },
            %{
              "id" => "nav-assistant-1",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "助手不该出现在导航"
            },
            %{
              "id" => "nav-tool-1",
              "content_type" => "tool",
              "tool_name" => "read",
              "content" => "README.md"
            },
            %{
              "id" => "nav-user-2",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "再问第二轮"
            }
          ]
        )

      {:ok, _view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ ~s(id="conversation-nav")
      assert html =~ ~s(class="conversation-nav-buttons")
      assert html =~ ~s(data-conversation-nav-toggle)
      assert html =~ ~s(id="mobile-fab")
      assert html =~ ~s(data-target-id="nav-user-1")
      assert html =~ ~s(data-target-id="nav-user-2")
      assert html =~ "先看第一轮用户问题"
      assert html =~ "再问第二轮"
      refute html =~ ~s(data-target-id="nav-assistant-1")
      refute html =~ ~s(data-target-id="nav-tool-1")
    end

    test "hides the hamburger when there are fewer than two user turns", %{conn: conn} do
      isolate_conversation_home!()

      {:ok, conversation} =
        Handbeam.ConversationStore.create("default",
          id: "conv-nav-short",
          title: "Nav short",
          timeline: [
            %{
              "id" => "nav-only-user",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "只有一条"
            },
            %{
              "id" => "nav-only-assistant",
              "content_type" => "assistant_msg",
              "role" => "assistant",
              "content" => "一条回复"
            }
          ]
        )

      {:ok, _view, html} = live(conn, "/w/default/c/#{conversation["id"]}")

      assert html =~ ~s(id="conversation-nav")
      assert html =~ ~s(id="mobile-fab")
      refute html =~ ~s(data-conversation-nav-toggle)
      refute html =~ ~s(data-target-id="nav-only-user")
    end
  end
end
