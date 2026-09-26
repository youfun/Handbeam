defmodule Handbeam.E2E.MCPToolTest do
  @moduledoc """
  A real MCP stdio server (test/fixtures/mcp/echo_server.py) is configured
  through a workspace `.mcp.json` and called from inside a live agent run:

  1. `Handbeam.Agent.run` bootstraps MCP for the workspace and bridges the
     server's tools into the tool registry as `mcp__echo_*__echo_text`.
  2. The run (FakeProvider) calls the tool; the transcript records a done
     tool entry whose output is the server's echoed text, and the run
     completes.
  3. A server that cannot connect is reported per-server without
     registering anything.

  Run: mix test --include e2e test/handbeam/e2e/mcp_tool_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.ConversationStore
  alias Handbeam.ConversationTranscriptStore
  alias Handbeam.PubSub.Session

  @moduletag :e2e

  @echo_input "hello from mcp"

  @echo_server ~s"""
  import json
  import sys


  def send(msg):
      sys.stdout.write(json.dumps(msg) + "\\n")
      sys.stdout.flush()


  def main():
      while True:
          raw = sys.stdin.readline()
          if raw == "":
              return 0

          raw = raw.strip()
          if not raw:
              continue

          try:
              msg = json.loads(raw)
          except ValueError:
              continue

          if not isinstance(msg, dict) or "method" not in msg:
              continue

          method = msg["method"]
          msg_id = msg.get("id")

          if method == "initialize":
              send({
                  "jsonrpc": "2.0",
                  "id": msg_id,
                  "result": {
                      "protocolVersion": "2024-11-05",
                      "capabilities": {"tools": {}},
                      "serverInfo": {"name": "echo", "version": "0.1.0"},
                  },
              })
          elif method == "notifications/initialized":
              pass
          elif method == "tools/list":
              send({
                  "jsonrpc": "2.0",
                  "id": msg_id,
                  "result": {
                      "tools": [
                          {
                              "name": "echo_text",
                              "description": "Echo the provided text back",
                              "inputSchema": {
                                  "type": "object",
                                  "properties": {"text": {"type": "string"}},
                                  "required": ["text"],
                              },
                          }
                      ]
                  },
              })
          elif method == "tools/call":
              args = (msg.get("params") or {}).get("arguments") or {}
              send({
                  "jsonrpc": "2.0",
                  "id": msg_id,
                  "result": {
                      "content": [
                          {"type": "text", "text": "echo: " + str(args.get("text", ""))}
                      ]
                  },
              })
          elif msg_id is not None:
              send({"jsonrpc": "2.0", "id": msg_id, "error": {"message": "unknown method"}})


  if __name__ == "__main__":
      sys.exit(main())
  """

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbeam.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "mcp-e2e-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    server_script = Path.join(root, "echo_server.py")
    File.write!(server_script, @echo_server)

    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAM_MODELS_FILE")
    models = Path.join(root, "models.json")

    File.write!(
      models,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HOME", home)
    System.put_env("HANDBEAM_MODELS_FILE", models)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_models,
        do: System.put_env("HANDBEAM_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAM_MODELS_FILE")

      if Process.whereis(Handbeam.Tool.Registry) do
        Handbeam.Tool.Registry.list()
        |> Enum.filter(&String.starts_with?(&1, "mcp__"))
        |> Enum.each(&Handbeam.Tool.Registry.unregister/1)
      end

      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, server_script: server_script}
  end

  defp settle(sid, attempts \\ 200) do
    busy? = Registry.lookup(Handbeam.AgentRunRegistry, sid) != []

    cond do
      busy? and attempts > 0 ->
        receive do
        after
          20 -> settle(sid, attempts - 1)
        end

      busy? ->
        flunk("run did not settle")

      true ->
        for pid <- Task.Supervisor.children(Handbeam.AgentRunTaskSupervisor) do
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        end

        {:ok, session} = Session.start_or_get(session_id: sid)
        :sys.get_state(session)

        if tracker = Process.whereis(Handbeam.Runtime.TaskTracker), do: :sys.get_state(tracker)

        :ok
    end
  end

  defp start_mcp_stack do
    # The MCP supervisor tree is not part of the test application start.
    start_supervised!(Handbeam.MCP.RuntimeSupervisor)
    start_supervised!(Handbeam.MCP)
  end

  test "a workspace .mcp.json server's tool is bridged and called during a live run", %{
    workspace: workspace,
    server_script: server_script
  } do
    start_mcp_stack()

    python = System.find_executable("python3") || raise("python3 is required for this e2e")

    File.write!(
      Path.join(workspace, ".mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{"echo" => %{"command" => python, "args" => [server_script]}}
      })
    )

    sid = "mcp-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    script = fn messages, defs ->
      tool = Enum.find_value(defs, &(&1.name =~ ~r/^mcp__echo_/ && &1.name))

      cond do
        is_nil(tool) ->
          flunk("the bridged mcp tool was not offered to the provider")

        Enum.any?(messages, &match?(%Handbeam.Agent.Message{role: :tool_result}, &1)) ->
          "the mcp tool answered"

        true ->
          {:tools, [%{name: tool, input: %{"text" => @echo_input}}]}
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "call the echo tool",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbeam.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbeam.Agent.default_tools(),
               mcp: true,
               trusted_project?: true,
               source: :cli,
               streaming: false,
               max_turns: 4
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000

    # The bridge registered the namespaced tool with server metadata.
    tool =
      Enum.find(Handbeam.Tool.Registry.list(), &String.match?(&1, ~r/^mcp__echo_.+__echo_text$/))

    assert tool, "expected the bridged mcp tool in the registry"

    {:ok, entry} = Handbeam.Tool.Registry.get(tool)
    assert entry.meta.source == :mcp
    assert entry.meta.server == "echo"
    assert entry.meta.remote_name == "echo_text"

    # A direct call with the run's MCP scope reaches the external process.
    scope_opts =
      Handbeam.MCP.Access.options(working_directory: workspace, trusted_project?: true)

    assert {:ok, text, _details} =
             entry.executor.(%{"text" => "direct"}, %{mcp_scope: scope_opts})

    assert text == "echo: direct"

    # The transcript records what the external server answered.
    {:ok, entries} = ConversationTranscriptStore.list(sid)
    tool_entry = Enum.find(entries, &(&1["tool_name"] == tool))
    assert tool_entry, "the mcp tool call must appear in the transcript"
    assert tool_entry["tool_status"] == "done"
    assert tool_entry["output"] =~ "echo: #{@echo_input}"
    assert tool_entry["tool_error"] in [nil, ""]

    assert Enum.any?(
             entries,
             &(&1["role"] == "assistant" and &1["status"] == "completed" and
                 &1["content"] == "the mcp tool answered")
           )

    # Teardown removes every bridged mcp__ tool.
    assert :ok = Handbeam.MCP.teardown_previous()
    assert :error = Handbeam.Tool.Registry.get(tool)
    assert [] = Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))

    settle(sid)
  end

  test "a server that cannot connect is reported per-server without registering anything" do
    start_mcp_stack()

    project = Path.join(System.tmp_dir!(), "mcp-e2e-broken-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(project, ".handbeam"))

    on_exit(fn -> File.rm_rf!(project) end)

    File.write!(
      Path.join(project, ".handbeam/mcp.json"),
      Jason.encode!(%{
        "mcpServers" => %{"broken" => %{"command" => "nonexistent_cmd_xyz", "args" => []}}
      })
    )

    assert {:ok, %{registered: [], server_errors: errors}} =
             Handbeam.MCP.bootstrap(project: project, user_config_path: nil)

    assert [%{server: "broken", error: "Connection failed"}] = errors

    assert [] = Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))
  end
end
