defmodule Handbeam.Agent.CliAgentTest do
  @moduledoc """
  Failure list for the CLI-agent boundary. These paths do not enter
  `Handbeam.Agent.Turn`, so they are isolated here.

  Invariants:

    * the registry resolves `"droid"` and rejects an unknown id
    * a missing executable returns `:not_available` and is not installed
    * a second backend registers without changing the Droid module
    * behaviour callbacks return normalized events, never Droid JSON-RPC
    * a permission request is answered on stdin, or the turn stops
    * `list_models` reads the executable's catalog, not a hardcoded list
    * model and reasoning effort are the CLI's flags, not a Provider switch
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.CliAgent.{Droid, Event, Grok, Registry, Run}
  alias Handbeam.Agent.CliAgent.Session, as: CliSession

  setup do
    Registry.reset()
    on_exit(fn -> Registry.reset() end)
    :ok
  end

  test "registry resolves droid and grok and rejects an unknown id" do
    assert {:ok, Droid} = Registry.fetch("droid")
    assert {:ok, Grok} = Registry.fetch("grok")
    assert Droid.id() == "droid"
    assert Grok.id() == "grok"
    assert {:error, :unknown_backend} = Registry.fetch("codex-cli")
  end

  test "a second backend registers without changing the Droid module" do
    assert :ok = Registry.register(Handbeam.Agent.CliAgentTest.FakeBackend)
    assert {:ok, Handbeam.Agent.CliAgentTest.FakeBackend} = Registry.fetch("fake-cli")
    assert {:ok, Droid} = Registry.fetch("droid")
    assert Handbeam.Agent.CliAgentTest.FakeBackend.id() == "fake-cli"
  end

  test "missing executable returns not_available" do
    assert {:error, :not_available} =
             Droid.start_session(cwd: File.cwd!(), executable: missing_executable())

    assert {:error, :not_available} = Droid.list_models(executable: missing_executable())
  end

  test "initialize, one user message, text deltas, and turn end" do
    script = fake_droid(turn_script())

    assert {:ok, %CliSession{backend: "droid", session_id: "sess-1"} = session} =
             Droid.start_session(cwd: File.cwd!(), executable: script)

    parent = self()

    assert {:ok, %CliSession{session_id: "sess-1"}, events} =
             Droid.send_message(session, "hello", fn event -> send(parent, {:event, event}) end)

    assert_receive {:event, {:text_delta, "Hel"}}
    assert_receive {:event, {:text_delta, "lo"}}
    assert_receive {:event, {:turn_end, %{stop_reason: :end_turn, session_id: "sess-1"}}}

    assert Enum.all?(events, &Event.normalized?/1)
    refute Enum.any?(events, &wire?/1)
    assert Droid.stop_session(session) == :ok
  end

  test "a permission request is answered, not dropped" do
    script = fake_droid(permission_script())

    assert {:ok, session} = Droid.start_session(cwd: File.cwd!(), executable: script)

    assert {:ok, _session, events} =
             Droid.send_message(session, "edit the file", fn
               {:permission_request, request} ->
                 assert Enum.any?(request.options, &(&1["value"] == "proceed_once"))
                 {:permission, "proceed_once"}

               _event ->
                 :ok
             end)

    assert {:permission_request, %{selected: "proceed_once"}} =
             Enum.find(events, &match?({:permission_request, _}, &1))

    assert {:text_delta, "done"} in events
    assert Enum.any?(events, &match?({:turn_end, _}, &1))

    written = File.read!(stdin_log(script))
    assert written =~ ~s("method":"droid.initialize_session")
    assert written =~ ~s("selectedOption":"proceed_once")
    refute written =~ "skip-permissions"
  end

  test "an unanswered permission stops the turn and does not approve" do
    script = fake_droid(permission_script())
    assert {:ok, session} = Droid.start_session(cwd: File.cwd!(), executable: script)

    assert {:error, :permission_unanswered} =
             Droid.send_message(session, "edit the file", fn _event -> :ok end)

    written = File.read!(stdin_log(script))
    refute written =~ "selectedOption"
  end

  test "droid-specific JSON never leaks through the behaviour callbacks" do
    script = fake_droid(turn_script())
    assert {:ok, session} = Droid.start_session(cwd: File.cwd!(), executable: script)
    assert {:ok, session, events} = Droid.send_message(session, "hello", fn _ -> :ok end)

    encoded = inspect(events) <> inspect(Map.drop(session, [:private]))
    refute encoded =~ "jsonrpc"
    refute encoded =~ "textDelta"
    refute encoded =~ "droid.session_notification"
    assert session.backend == "droid"
    assert %CliSession{} = session
  end

  test "list_models reads the executable catalog and start passes model flags" do
    script = fake_droid(models_script())

    assert {:ok, models} = Droid.list_models(executable: script, cwd: File.cwd!())

    assert models == [
             %{id: "model-a", display_name: "Model A", reasoning_levels: ["low", "high"]}
           ]

    log = File.read!(argv_log(script))
    assert log =~ "stream-jsonrpc"
    assert File.read!(stdin_log(script)) =~ "droid.list_models"

    session_script = fake_droid(turn_script())

    assert {:ok, _session} =
             Droid.start_session(
               cwd: File.cwd!(),
               executable: session_script,
               model: "model-a",
               reasoning_effort: "high"
             )

    argv = File.read!(argv_log(session_script))
    assert argv =~ "-m"
    assert argv =~ "model-a"
    assert argv =~ "-r"
    assert argv =~ "high"
    refute argv =~ "skip-permissions-unsafe"
  end

  test "models_unavailable when the executable cannot list models" do
    script = fake_droid(empty_models_script())
    assert {:error, :models_unavailable} = Droid.list_models(executable: script, cwd: File.cwd!())
  end

  test "run projects text without executing tools through the handbeam executor" do
    script = fake_droid(tool_script())

    assert {:ok, "noted", %{backend: "droid", session_id: "sess-1"}} =
             Run.turn("inspect", backend: "droid", cwd: File.cwd!(), executable: script)

    assert {:error, :unknown_backend} = Run.turn("nope", backend: "missing", cwd: File.cwd!())
  end

  test "grok ACP session projects text and answers only an explicit permission" do
    script = grok_script()

    assert {:ok, %CliSession{backend: "grok", session_id: "grok-sess"} = session} =
             Grok.start_session(cwd: File.cwd!(), executable: script, model: "grok-4.7")

    assert {:ok, _session, events} =
             Grok.send_message(session, "hello", fn
               {:permission_request, request} ->
                 assert Enum.any?(request.options, &(&1["value"] == "allow_once"))
                 {:permission, "allow_once"}

               _event ->
                 :ok
             end)

    assert Enum.any?(events, &match?({:text_delta, "ok"}, &1))
    assert Enum.any?(events, &match?({:turn_end, %{stop_reason: :end_turn}}, &1))
    assert Enum.all?(events, &Event.normalized?/1)
    assert File.read!(stdin_log(script)) =~ "session/prompt"
    assert File.read!(stdin_log(script)) =~ "allow_once"
    assert Grok.stop_session(session) == :ok
  end

  test "grok lists models from the executable text, not a hardcoded catalog" do
    script = fake_droid(grok_models_script())

    assert {:ok, models} = Grok.list_models(executable: script, cwd: File.cwd!())
    assert Enum.any?(models, &(&1.id == "grok-4.7"))
    refute Enum.any?(models, &(&1.id == "gemini-3.8-flash"))
  end

  test "grok model changes apply on the next start, not as a provider switch" do
    script = grok_script()
    assert {:ok, session} = Grok.start_session(cwd: File.cwd!(), executable: script)

    assert {:error, :apply_on_next_start} =
             Grok.update_model(session, model: "grok-4.6", reasoning_effort: "low")

    assert Grok.stop_session(session) == :ok
  end

  test "phone host without a shell keeps the backend unavailable" do
    previous = Application.get_env(:handbeam, :host)
    Application.put_env(:handbeam, :host, %{shell: false})
    on_exit(fn -> restore_host(previous) end)

    refute Droid.available?()
    assert {:error, :not_available} = Run.turn("hello", backend: "droid", cwd: File.cwd!())
  end

  defp restore_host(nil), do: Application.delete_env(:handbeam, :host)
  defp restore_host(previous), do: Application.put_env(:handbeam, :host, previous)

  defp missing_executable do
    Path.join(System.tmp_dir!(), "handbeam-missing-droid-#{System.unique_integer([:positive])}")
  end

  defp fake_droid(body) do
    dir = Path.join(System.tmp_dir!(), "handbeam-droid-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "droid")
    File.write!(script, body)
    File.chmod!(script, 0o755)
    script
  end

  defp stdin_log(script), do: script <> ".stdin"
  defp argv_log(script), do: script <> ".argv"

  defp turn_script do
    """
    #!/bin/sh
    printf '%s\\n' "$@" > "$0.argv"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$0.stdin"
      case "$line" in
        *initialize_session*|*load_session*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"1","type":"response","result":{"sessionId":"sess-1","session":{"messages":[]},"settings":{}}}'
          ;;
        *add_user_message*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"2","type":"response","result":{}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"droid_working_state_changed","newState":"working"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"assistant_text_delta","messageId":"m1","blockIndex":0,"textDelta":"Hel"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"assistant_text_delta","messageId":"m1","blockIndex":0,"textDelta":"lo"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"droid_working_state_changed","newState":"idle"}}}'
          ;;
      esac
    done
    """
  end

  defp permission_script do
    """
    #!/bin/sh
    printf '%s\\n' "$@" > "$0.argv"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$0.stdin"
      case "$line" in
        *initialize_session*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"1","type":"response","result":{"sessionId":"sess-1","session":{"messages":[]},"settings":{}}}'
          ;;
        *add_user_message*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"perm-1","type":"request","method":"droid.request_permission","params":{"toolUses":[{"toolUse":{"type":"tool_use","id":"t1","name":"Edit","input":{}},"confirmationType":"edit","details":{"type":"edit","filePath":"a.ex","fileName":"a.ex"}}],"options":[{"label":"Once","value":"proceed_once"},{"label":"Cancel","value":"cancel"}]}}'
          ;;
        *selectedOption*)
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"droid_working_state_changed","newState":"working"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"assistant_text_delta","messageId":"m1","blockIndex":0,"textDelta":"done"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"droid_working_state_changed","newState":"idle"}}}'
          ;;
      esac
    done
    """
  end

  defp models_script do
    """
    #!/bin/sh
    printf '%s\\n' "$@" > "$0.argv"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$0.stdin"
      case "$line" in
        *list_models*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"models","type":"response","result":{"models":[{"id":"model-a","displayName":"Model A","supportedReasoningEfforts":["low","high"],"disabled":false},{"id":"hidden","displayName":"Hidden","supportedReasoningEfforts":["low"],"disabled":true}]}}'
          ;;
      esac
    done
    """
  end

  defp empty_models_script do
    """
    #!/bin/sh
    printf '%s\\n' "$@" > "$0.argv"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$0.stdin"
      case "$line" in
        *list_models*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"models","type":"response","result":{}}'
          ;;
      esac
    done
    """
  end

  defp grok_script do
    source = Path.expand("../../support/fake_grok_acp.py", __DIR__)
    dir = Path.join(System.tmp_dir!(), "handbeam-grok-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "grok")
    File.cp!(source, script)
    File.chmod!(script, 0o755)
    script
  end

  defp grok_models_script do
    """
    #!/bin/sh
    if [ "$1" = "models" ]; then
      printf '%s\\n' "Default model: grok-4.7"
      printf '%s\\n' "  * grok-4.7 (default)"
      printf '%s\\n' "  - grok-4.6"
      exit 0
    fi
    exit 1
    """
  end

  defp tool_script do
    """
    #!/bin/sh
    printf '%s\\n' "$@" > "$0.argv"
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$0.stdin"
      case "$line" in
        *initialize_session*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"1","type":"response","result":{"sessionId":"sess-1","session":{"messages":[]},"settings":{}}}'
          ;;
        *add_user_message*)
          printf '%s\\n' '{"jsonrpc":"2.0","id":"2","type":"response","result":{}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"droid_working_state_changed","newState":"working"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"tool_call","toolUse":{"type":"tool_use","id":"tool-1","name":"Read","input":{"path":"a.ex"}}}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"tool_result","messageId":"m1","toolUseId":"tool-1","content":"file","isError":false}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"assistant_text_delta","messageId":"m1","blockIndex":0,"textDelta":"noted"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","type":"notification","method":"droid.session_notification","params":{"notification":{"type":"droid_working_state_changed","newState":"idle"}}}'
          ;;
      esac
    done
    """
  end

  defp wire?(event) do
    Event.wire?(elem(event, 1))
  rescue
    _ -> false
  end
end
