defmodule Handbeam.Tool.RegistryTest do
  @moduledoc """
  Tests for the tool registry GenServer.

  Reference: `alloy/` (Tool Registry pattern)
  Test pattern: hand-written

  Covers:
    - Registering tools
    - Retrieving tools by name
    - Listing registered tools
    - Generating tool definitions
    - Tool function lookups
  """

  use ExUnit.Case, async: false

  alias Handbeam.Tool.Registry

  # Note: Handbeam.Tool.Registry is a named GenServer shared across tests.
  # async:false ensures serial execution to avoid race conditions.

  setup do
    registry_state = :sys.get_state(Registry)

    on_exit(fn -> :sys.replace_state(Registry, fn _current -> registry_state end) end)
  end

  describe "register/1" do
    test "registers a tool module" do
      mod = Handbeam.Tool.Builtin.Read
      assert Registry.register(mod) == :ok
    end

    test "overwrites duplicate registration" do
      Registry.register(Handbeam.Tool.Builtin.Read)
      # Second registration should succeed (with warning log)
      assert Registry.register(Handbeam.Tool.Builtin.Read) == :ok
    end

    test "override: true replaces description and schema" do
      assert :ok = Registry.register(__MODULE__.OverrideProbeA)
      assert {:ok, first} = Registry.get("override_probe")
      assert first.description == "a"

      assert :ok = Registry.register(__MODULE__.OverrideProbeB)
      assert {:ok, kept} = Registry.get("override_probe")
      assert kept.description == "a"

      assert :ok = Registry.register(__MODULE__.OverrideProbeB, override: true)
      assert {:ok, replaced} = Registry.get("override_probe")
      assert replaced.description == "b"
      assert replaced.module == __MODULE__.OverrideProbeB
    after
      Registry.unregister("override_probe")
    end
  end

  describe "owner-aware replacement" do
    test "an owner cannot remove or replace another owner's tool" do
      assert :ok = Registry.replace_owner(:owner_a, [__MODULE__.OverrideProbeA])

      assert {:error, {:tool_name_collision, "override_probe", :owner_a}} =
               Registry.replace_owner(:owner_b, [__MODULE__.OverrideProbeB])

      assert {:ok, entry} = Registry.get("override_probe")
      assert entry.meta.owner == :owner_a

      assert :ok = Registry.remove_owner(:owner_b)
      assert {:ok, _} = Registry.get("override_probe")
    after
      Registry.remove_owner(:owner_a)
      Registry.remove_owner(:owner_b)
    end
  end

  describe "host_tool_modules/0" do
    setup do
      previous = Application.get_env(:handbeam, :host)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:handbeam, :host, previous),
          else: Application.delete_env(:handbeam, :host)
      end)

      :ok
    end

    test "desktop host seeds browser and not preview_serve" do
      Application.delete_env(:handbeam, :host)
      names = Enum.map(Registry.host_tool_modules(), & &1.name())
      assert "browser" in names
      refute "mix_project" in names
      refute "git" in names
      assert "bash" in names
      for tool <- ~w(web_fetch skill task job_status job_cancel), do: assert(tool in names)
      refute "preview_serve" in names
      assert :ok = Registry.register(Handbeam.Tool.Builtin.Browser)
      assert {:ok, entry} = Registry.get("browser")
      assert entry.module == Handbeam.Tool.Builtin.Browser
      refute "run_elixir_script" in names
    end

    test "webview host seeds browser and preview_serve only for declared backends" do
      Handbeam.Host.put!(%{
        shell: false,
        browser_backend: :webview,
        artifact_delivery_backend: Handbeam.ArtifactDelivery,
        host_script: true,
        beam_eval: false,
        packaged_mix_toolchain: true
      })

      mods = Registry.host_tool_modules()
      names = Enum.map(mods, & &1.name())
      assert "browser" in names
      assert "preview_serve" in names
      assert "open_url" in names
      assert "open_file" in names
      assert "share_file" in names
      assert "run_elixir_script" in names
      for tool <- ~w(web_fetch skill task job_status job_cancel create_thread send_thread_message),
          do: assert(tool in names)

      assert "mix_project" in names
      refute "git" in names
      refute "bash" in names

      Enum.each(mods, &Registry.register/1)
      assert match?({:ok, %{module: Handbeam.Tool.Builtin.Browser}}, Registry.get("browser"))

      assert match?(
               {:ok, %{module: Handbeam.Tool.Builtin.PreviewServe}},
               Registry.get("preview_serve")
             )

      assert match?(
               {:ok, %{module: Handbeam.Tool.Builtin.OpenUrl}},
               Registry.get("open_url")
             )

      assert match?(
               {:ok, %{module: Handbeam.Tool.Builtin.RunElixirScript}},
               Registry.get("run_elixir_script")
             )
    end

    test "host-provided Git backend enables the builtin git tool" do
      Handbeam.Host.put!(%{
        shell: false,
        browser_backend: :webview,
        git_backend: Handbeam.Git.CLI
      })

      names = Enum.map(Registry.host_tool_modules(), & &1.name())
      assert "git" in names
      refute "bash" in names
    end
  end

  describe "get/1" do
    test "retrieves a registered tool by name" do
      Registry.register(Handbeam.Tool.Builtin.Read)
      {:ok, tool} = Registry.get("read")
      assert tool.module == Handbeam.Tool.Builtin.Read
      assert tool.name == "read"
      assert is_function(tool.executor, 2)
    end

    test "returns :error for unregistered tool" do
      assert Registry.get("nonexistent") == :error
    end
  end

  describe "list/0" do
    test "returns all registered tool names" do
      Registry.register(Handbeam.Tool.Builtin.Read)
      Registry.register(Handbeam.Tool.Builtin.Bash)

      names = Registry.list()
      assert "read" in names
      assert "bash" in names
    end

    test "returns names when tools are registered" do
      names = Registry.list()
      # At minimum, should be a list (may have tools from other tests)
      assert is_list(names)
    end
  end

  describe "tool_defs/0" do
    test "returns tool definitions for providers" do
      Registry.register(Handbeam.Tool.Builtin.Read)

      defs = Registry.tool_defs()
      assert length(defs) >= 1

      read_def = Enum.find(defs, &(&1.name == "read"))
      assert read_def != nil
      assert is_binary(read_def.description)
      assert is_map(read_def.input_schema)
    end
  end

  describe "tool_fns/0" do
    test "returns function lookup map" do
      Registry.register(Handbeam.Tool.Builtin.Read)
      Registry.register(Handbeam.Tool.Builtin.Bash)

      fns = Registry.tool_fns()

      {:ok, read_tool} = Map.fetch(fns, "read")
      assert read_tool.module == Handbeam.Tool.Builtin.Read
      assert read_tool.name == "read"
      assert is_function(read_tool.executor, 2)

      {:ok, bash_tool} = Map.fetch(fns, "bash")
      assert bash_tool.module == Handbeam.Tool.Builtin.Bash
      assert bash_tool.name == "bash"
      assert is_function(bash_tool.executor, 2)
    end
  end

  describe "BEAM tool registration from workspace settings" do
    defp tmp_workspace do
      dir =
        Path.join(System.tmp_dir!(), "sigil_registry_beam_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf(dir) end)

      dir
    end

    defp write_settings(workspace, content) do
      path = Handbeam.WorkspaceSettings.path(workspace)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    setup do
      Registry.reset()
      :ok
    end

    test "registers docs/source/sql for Elixir projects by default" do
      workspace = tmp_workspace()
      File.write!(Path.join(workspace, "mix.exs"), "defmodule Demo.MixProject do end")

      assert {:ok, _state} =
               Handbeam.Agent.run("hello",
                 provider: Handbeam.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      names = Registry.list()
      assert "ext__beam__docs" in names
      assert "ext__beam__source" in names
      assert "ext__beam__sql" in names
      refute "ext__beam__eval" in names
    end

    test "does not auto-register BEAM tools when tools.beam.auto is false" do
      workspace = tmp_workspace()
      File.write!(Path.join(workspace, "mix.exs"), "defmodule Demo.MixProject do end")

      write_settings(workspace, """
      {
        "tools": {
          "beam": {
            "auto": false,
            "eval": false,
          },
        },
      }
      """)

      assert {:ok, _state} =
               Handbeam.Agent.run("hello",
                 provider: Handbeam.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      names = Registry.list()
      refute "ext__beam__docs" in names
      refute "ext__beam__source" in names
      refute "ext__beam__sql" in names
      refute "ext__beam__eval" in names
    end

    test "registers eval only when enabled or explicitly listed" do
      previous_host = Application.get_env(:handbeam, :host)
      Handbeam.Host.put!(Map.put(previous_host || %{}, :beam_eval, true))

      on_exit(fn ->
        if previous_host,
          do: Application.put_env(:handbeam, :host, previous_host),
          else: Application.delete_env(:handbeam, :host)
      end)

      workspace = tmp_workspace()

      write_settings(workspace, """
      {
        "tools": {
          "beam": {
            "auto": false,
            "eval": true,
          },
        },
      }
      """)

      assert {:ok, _state} =
               Handbeam.Agent.run("hello",
                 provider: Handbeam.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 model: "fake",
                 working_directory: workspace,
                 mcp: false
               )

      assert "ext__beam__eval" in Registry.list()
    end
  end

  defmodule OverrideProbeA do
    @behaviour Handbeam.Agent.Tool

    def name, do: "override_probe"
    def description, do: "a"
    def input_schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_input, _context), do: {:ok, "a"}
  end

  defmodule OverrideProbeB do
    @behaviour Handbeam.Agent.Tool

    def name, do: "override_probe"
    def description, do: "b"
    def input_schema, do: %{"type" => "object", "properties" => %{"x" => %{}}}
    def execute(_input, _context), do: {:ok, "b"}
  end
end
