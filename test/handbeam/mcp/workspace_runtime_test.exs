defmodule Handbeam.MCP.WorkspaceRuntimeTest do
  use ExUnit.Case, async: false
  alias Handbeam.MCP.{Access, Settings, ServerRuntime}

  setup do
    start_supervised!(Handbeam.MCP.RuntimeSupervisor)
    start_supervised!(Handbeam.MCP)
    Req.Test.set_req_test_to_shared()
    old = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    root = Path.join(System.tmp_dir!(), "mcp-runtime-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      send(owner, {:request, conn.host, message["method"]})
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/json, text/event-stream"]

      case message["method"] do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-#{conn.host}")
          |> Req.Test.json(%{
            jsonrpc: "2.0",
            id: message["id"],
            result: %{protocolVersion: "2025-06-18"}
          })

        "notifications/initialized" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-#{conn.host}"]
          Plug.Conn.send_resp(conn, 202, "")

        "tools/list" ->
          assert Plug.Conn.get_req_header(conn, "mcp-protocol-version") == ["2025-06-18"]

          Req.Test.json(conn, %{
            jsonrpc: "2.0",
            id: message["id"],
            result: %{
              tools: [%{name: "echo", description: "Echo", inputSchema: %{type: "object"}}]
            }
          })

        "tools/call" ->
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-#{conn.host}"]

          result = %{
            content: [%{type: "text", text: conn.host}],
            isError: message["params"]["arguments"]["fail"] == true
          }

          body =
            "event: message\ndata: " <>
              Jason.encode!(%{jsonrpc: "2.0", method: "notifications/progress"}) <>
              "\n\n" <>
              "data: " <>
              Jason.encode!(%{jsonrpc: "2.0", id: message["id"], result: result}) <> "\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, body)
      end
    end)

    on_exit(fn ->
      Req.default_options(old)
      File.rm_rf!(root)
    end)

    %{root: root, opts: [user_config_path: Path.join(root, "mcp.json")]}
  end

  test "two workspaces keep independent runtimes; revoke blocks discovery AND captured executors",
       %{opts: opts} do
    form =
      Settings.new_form("a")
      |> Map.merge(%{
        "name" => "Docs",
        "url" => "https://one.example/mcp",
        "workspace_ids" => ["a", "b"]
      })

    {:ok, id} = Settings.save(form, opts)
    a = Keyword.put(opts, :workspace_id, "a")
    b = Keyword.put(opts, :workspace_id, "b")
    {:ok, first} = Handbeam.MCP.bootstrap(a)
    {:ok, second} = Handbeam.MCP.bootstrap(b)
    assert Enum.all?(first.runtime_pids, &Process.alive?/1)
    assert first.registered != second.registered
    [name] = first.registered
    assert byte_size(name) <= 64
    {:ok, tool} = Handbeam.Tool.Registry.get(name)
    assert {:ok, "one.example", _} = tool.executor.(%{}, %{mcp_scope: a})
    assert {:error, _} = tool.executor.(%{}, %{mcp_scope: b})
    definitions = Enum.map(first.registered ++ second.registered, &%{name: &1})
    assert [%{name: ^name}] = Access.filter(definitions, %{mcp_scope: a})
    assert [] = Access.filter([%{name: name}], %{})

    {:ok, edit} = Settings.edit(id, opts)
    {:ok, ^id} = Settings.save(%{edit | "workspace_ids" => ["b"]}, opts)
    assert {:error, _} = tool.executor.(%{}, %{mcp_scope: a})
    assert [] = Access.filter([%{name: name}], %{mcp_scope: a})
    {:ok, other_tool} = Handbeam.Tool.Registry.get(hd(second.registered))
    assert {:ok, "one.example", _} = other_tool.executor.(%{}, %{mcp_scope: b})
    {:ok, empty} = Handbeam.MCP.bootstrap(a)
    assert empty.registered == []
    assert Enum.all?(second.runtime_pids, &Process.alive?/1)
  end

  test "same ID with a changed URL replaces connection; successful config is reused", %{
    opts: opts
  } do
    form =
      Settings.new_form("a") |> Map.merge(%{"name" => "Docs", "url" => "https://one.example/mcp"})

    {:ok, id} = Settings.save(form, opts)
    a = Keyword.put(opts, :workspace_id, "a")
    {:ok, first} = Handbeam.MCP.bootstrap(a)
    assert {:ok, ^first} = Handbeam.MCP.bootstrap(a)
    {:ok, edit} = Settings.edit(id, opts)
    {:ok, ^id} = Settings.save(%{edit | "url" => "https://two.example/mcp"}, opts)
    {:ok, second} = Handbeam.MCP.bootstrap(a)
    assert first.runtime_pids != second.runtime_pids
    [pid] = second.runtime_pids
    assert {:ok, "two.example", _} = ServerRuntime.call_tool(pid, "echo", %{})
    assert {:error, "two.example", _} = ServerRuntime.call_tool(pid, "echo", %{"fail" => true})
  end

  test "test connection uses draft credentials but never registers or persists tools", %{
    opts: opts
  } do
    original = Handbeam.Tool.Registry.list()

    form =
      Settings.new_form("a")
      |> Map.merge(%{"name" => "Docs", "url" => "https://draft.example/mcp"})

    assert {:ok, %{tool_count: 1}} = Settings.test_connection(form, opts)
    assert Handbeam.Tool.Registry.list() == original
    refute File.exists?(Settings.path(opts))
  end

  test "mobile host refuses stdio even when asked directly", %{opts: opts} do
    previous = Application.get_env(:handbeam, :host)
    Handbeam.Host.put!(%{shell: false, mcp: true})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)
    end)

    File.write!(
      Settings.path(opts),
      Jason.encode!(%{"mcpServers" => %{"local" => %{"command" => "echo"}}})
    )

    assert Access.config(opts).servers == %{}

    assert {:error, :unsupported_transport} =
             Handbeam.MCP.start_runtime(
               server_config: %Handbeam.MCP.ServerConfig{name: "local", command: "echo"}
             )
  end
end
