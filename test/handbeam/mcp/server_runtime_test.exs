defmodule Handbeam.MCP.ServerRuntimeTest do
  @moduledoc """
  Tests for MCP ServerRuntime (HTTP + stdio transports).

  HTTP tests hit the real StepFun search endpoint and are tagged :external_api.
  Run with: mix test test/handbeam/mcp/server_runtime_test.exs --tag @external_api
  Skip them: mix test test/handbeam/mcp/server_runtime_test.exs --exclude @external_api
  """
  use ExUnit.Case, async: false

  describe "HTTP transport - stepsearch" do
    @tag :external_api
    test "start_link, tools, and call_tool end-to-end" do
      cfg = server_config("stepsearch")
      assert {:ok, pid} = Handbeam.MCP.ServerRuntime.start_link(server_config: cfg)
      assert Process.alive?(pid)

      assert {:ok, tools} = Handbeam.MCP.ServerRuntime.tools(pid)
      tool_names = Enum.map(tools, & &1.name)
      assert "web_search" in tool_names
      assert "web_fetch" in tool_names

      assert {:ok, text, _meta} =
               Handbeam.MCP.ServerRuntime.call_tool(pid, "web_search", %{"query" => "test", "n" => 1})

      assert is_binary(text)
      assert String.length(text) > 0

      Handbeam.MCP.ServerRuntime.shutdown(pid)
      refute Process.alive?(pid)
    end

    @tag :external_api
    test "call_tool returns 3-tuple" do
      cfg = server_config("stepsearch")
      {:ok, pid} = Handbeam.MCP.ServerRuntime.start_link(server_config: cfg)

      assert {:ok, _text, _meta} =
               Handbeam.MCP.ServerRuntime.call_tool(pid, "web_search", %{
                 "query" => "Elixir",
                 "n" => 1
               })

      Handbeam.MCP.ServerRuntime.shutdown(pid)
    end

    @tag :external_api
    test "search returns structured results" do
      cfg = server_config("stepsearch")
      {:ok, pid} = Handbeam.MCP.ServerRuntime.start_link(server_config: cfg)

      {:ok, text, _meta} =
        Handbeam.MCP.ServerRuntime.call_tool(pid, "web_search", %{"query" => "Elixir", "n" => 2})

      result = Jason.decode!(text)
      assert result["query"] == "Elixir"
      assert length(result["results"]) <= 2
      assert Enum.all?(result["results"], &match?(%{"title" => _, "url" => _}, &1))

      Handbeam.MCP.ServerRuntime.shutdown(pid)
    end

    @tag :external_api
    test "web_fetch retrieves page content" do
      cfg = server_config("stepsearch")
      {:ok, pid} = Handbeam.MCP.ServerRuntime.start_link(server_config: cfg)

      {:ok, text, _meta} =
        Handbeam.MCP.ServerRuntime.call_tool(pid, "web_fetch", %{"url" => "https://elixir-lang.org"})

      result = Jason.decode!(text)
      assert is_binary(result["content"])
      assert String.length(result["content"]) > 0

      Handbeam.MCP.ServerRuntime.shutdown(pid)
    end
  end

  describe "bootstrap / teardown cycle" do
    setup do
      orig_tools = Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))

      on_exit(fn ->
        current = Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))
        Enum.each(current -- orig_tools, &Handbeam.Tool.Registry.unregister/1)
      end)

      :ok
    end

    test "teardown_previous removes all mcp__ tools" do
      for name <- ["mcp__fake__a", "mcp__fake__b"] do
        :ok =
          Handbeam.Tool.Registry.register_virtual(name, "fake", %{}, fn _input, _ctx ->
            {:ok, "fake"}
          end)
      end

      assert length(Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))) >=
               2

      Handbeam.MCP.teardown_previous()

      remaining = Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))
      assert remaining == []
    end

    test "double bootstrap does not duplicate tools" do
      dir1 =
        setup_temp_project(%{
          "stepsearch" => %{
            "url" => "https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp",
            "headers" => %{
              "Authorization" =>
                "Bearer test-mcp-token"
            }
          }
        })

      {:ok, _} = Handbeam.MCP.bootstrap(project: dir1)

      tools1 =
        Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__stepsearch__"))

      assert length(tools1) > 0

      {:ok, _} = Handbeam.MCP.bootstrap(project: dir1)

      tools2 =
        Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__stepsearch__"))

      assert length(tools2) == length(tools1)

      empty_dir = setup_temp_project(%{})
      {:ok, _} = Handbeam.MCP.bootstrap(project: empty_dir, user_config_path: nil)

      stepsearch_after_3 =
        Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__stepsearch__"))

      # No servers in project config, user config suppressed -> no new tools from this bootstrap
      assert stepsearch_after_3 == []

      File.rm_rf!(dir1)
      File.rm_rf!(empty_dir)
    end

    test "bootstrap returns server_errors on failure" do
      dir = setup_temp_project(%{"broken" => %{"command" => "nonexistent_cmd_xyz"}})
      {:ok, result} = Handbeam.MCP.bootstrap(project: dir)
      errors = Map.get(result, :server_errors, [])
      assert Enum.any?(errors, &(&1.server == "broken"))
      File.rm_rf!(dir)
    end

    test "bootstrap does not raise on server failure" do
      dir = setup_temp_project(%{"broken" => %{"command" => "nonexistent_cmd_xyz"}})
      assert {:ok, _} = Handbeam.MCP.bootstrap(project: dir)
      File.rm_rf!(dir)
    end
  end

  describe "parse_http_response" do
    test "accepts already-decoded map from Req" do
      body = %{"id" => "1", "jsonrpc" => "2.0", "result" => %{"tools" => []}}
      assert {:ok, %{"tools" => []}} = Handbeam.MCP.ServerRuntime.parse_http_response(body)
    end

    test "accepts binary JSON string" do
      body = ~s({"id":"1","jsonrpc":"2.0","result":{"tools":[]}})
      assert {:ok, %{"tools" => []}} = Handbeam.MCP.ServerRuntime.parse_http_response(body)
    end

    test "returns error for JSON-RPC error response (map)" do
      body = %{"id" => "1", "jsonrpc" => "2.0", "error" => %{"message" => "not found"}}

      assert {:error, %{"message" => "not found"}} =
               Handbeam.MCP.ServerRuntime.parse_http_response(body)
    end

    test "returns error for unexpected body" do
      assert {:error, _} = Handbeam.MCP.ServerRuntime.parse_http_response(%{"random" => "data"})
    end
  end

  defp server_config(name) do
    %Handbeam.MCP.ServerConfig{
      name: name,
      command: nil,
      args: [],
      env: %{},
      runtime_env: %{},
      disabled: false,
      cwd: nil,
      transport: "stdio",
      type: nil,
      url: "https://api.stepfun.com/step_plan/v1/mcp/web_search/mcp",
      headers: %{
        "Authorization" => "Bearer test-mcp-token"
      },
      runtime_headers: %{
        "Authorization" => "Bearer test-mcp-token"
      },
      source: "test",
      raw: %{}
    }
  end

  defp setup_temp_project(servers) do
    dir = Path.join(System.tmp_dir!(), "mcp_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".mcp.json"), Jason.encode!(%{"mcpServers" => servers}))
    dir
  end
end
