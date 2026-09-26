defmodule Handbeam.Settings.ModelRefsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Handbeam.Agent.ModelConfig
  alias Handbeam.Settings
  alias Handbeam.Settings.{ModelAIOverride, ModelPolicy, ModelRefs}
  alias Handbeam.WorkspaceStore

  @env ~w(HANDBEAM_MODELS_FILE HANDBEAM_WORKSPACES_FILE HANDBEAM_GLOBAL_SETTINGS_FILE HANDBEAM_WORKSPACE)

  setup do
    dir = Path.join(System.tmp_dir!(), "sigil_model_refs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    System.put_env("HANDBEAM_MODELS_FILE", Path.join(dir, "models.json"))
    System.put_env("HANDBEAM_WORKSPACES_FILE", Path.join(dir, "workspaces.json"))
    System.put_env("HANDBEAM_GLOBAL_SETTINGS_FILE", Path.join(dir, "settings.json"))
    System.put_env("HANDBEAM_WORKSPACE", Path.join(dir, "ws_a"))

    {:ok, ws_a} = WorkspaceStore.ensure_default!()
    File.mkdir_p!(Path.join(dir, "ws_b"))
    {:ok, ws_b} = WorkspaceStore.add(Path.join(dir, "ws_b"), name: "B")

    :ok =
      ModelConfig.write_config(%{
        "defaultProvider" => "alpha",
        "defaultModel" => "one",
        "providers" => %{
          "alpha" => %{"models" => [%{"id" => "one", "name" => "One"}]},
          "beta" => %{"models" => [%{"id" => "two", "name" => "Two"}]}
        }
      })

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir, ws_a: ws_a, ws_b: ws_b}
  end

  test "finds catalog defaults, global and workspace Model/AI fields, and policy default", %{
    ws_a: ws_a,
    ws_b: ws_b
  } do
    global = %{Settings.global_model_ai() | default_model: "alpha/one"}
    :ok = ModelAIOverride.save(:global, global)

    :ok =
      ModelAIOverride.save({:workspace, ws_b["path"]}, %{global | om_observer_model: "alpha/one"})

    :ok =
      ModelPolicy.save(ws_a["path"], %{
        mode: :restricted,
        allowed: %{"alpha" => MapSet.new(["one"])},
        default_model: "alpha/one"
      })

    %{refs: refs, errors: []} = ModelRefs.find(:model, "alpha", "one")
    sources = Enum.map(refs, & &1.source)

    assert :catalog_default_model in sources
    assert :catalog_default_provider in sources
    assert %{source: :global_model_ai, field: :default_model} = find_ref(refs, :global_model_ai)

    assert %{source: :workspace_model_ai, field: :om_observer_model, workspace_id: id} =
             find_ref(refs, :workspace_model_ai)

    assert id == ws_b["id"]

    assert %{source: :workspace_policy_default, path: path} =
             find_ref(refs, :workspace_policy_default)

    assert path == ws_a["path"]

    # Catalog defaults are reassigned by ModelConfig; only settings block deletion.
    blocking = ModelRefs.blocking(refs)

    assert Enum.map(blocking, & &1.source) |> Enum.sort() ==
             [:global_model_ai, :workspace_model_ai, :workspace_policy_default]

    assert %{refs: [], errors: []} = ModelRefs.find(:model, "beta", "two")
  end

  test "provider refs match any model of that provider", %{ws_b: ws_b} do
    :ok =
      ModelAIOverride.save({:workspace, ws_b["path"]}, %{
        Settings.global_model_ai()
        | om_reflector_model: "beta/two"
      })

    %{refs: refs} = ModelRefs.find(:provider, "beta", nil)
    assert [%{source: :workspace_model_ai, field: :om_reflector_model}] = refs
  end

  test "replace_all rewrites every reference and catalog defaults", %{ws_a: ws_a} do
    :ok =
      ModelAIOverride.save(:global, %{Settings.global_model_ai() | default_model: "alpha/one"})

    :ok =
      ModelPolicy.save(ws_a["path"], %{
        mode: :restricted,
        allowed: %{"alpha" => MapSet.new(["one"]), "beta" => MapSet.new(["two"])},
        default_model: "alpha/one"
      })

    %{refs: refs} = ModelRefs.find(:model, "alpha", "one")
    assert :ok = ModelRefs.replace_all(refs, "beta/two")

    assert Settings.global_model_ai().default_model == "beta/two"
    assert ModelPolicy.form(ws_a["path"]).default_model == "beta/two"
    {:ok, config} = ModelConfig.read_config()
    assert config["defaultProvider"] == "beta"
    assert config["defaultModel"] == "two"
    assert %{refs: []} = ModelRefs.find(:model, "alpha", "one")
  end

  test "replace_all rejects a non-composite replacement for catalog defaults" do
    %{refs: refs} = ModelRefs.find(:model, "alpha", "one")
    assert refs != []
    assert {:error, :invalid_replacement} = ModelRefs.replace_all(refs, "not-composite")
  end

  test "a workspace with an unreadable settings file is skipped and reported", %{
    ws_a: ws_a,
    ws_b: ws_b
  } do
    :ok =
      ModelAIOverride.save({:workspace, ws_a["path"]}, %{
        Settings.global_model_ai()
        | default_model: "alpha/one"
      })

    File.write!(Handbeam.WorkspaceSettings.path(ws_b["path"]), "{ this is not jsonc")

    log =
      capture_log(fn ->
        %{refs: refs, errors: errors} = ModelRefs.find(:model, "alpha", "one")

        # The healthy workspace is still scanned.
        assert Enum.any?(refs, &(&1.source == :workspace_model_ai and &1.path == ws_a["path"]))
        refute Enum.any?(refs, &(&1[:path] == ws_b["path"]))

        assert [%{workspace_id: id, path: path, reason: reason}] = errors
        assert id == ws_b["id"]
        assert path == ws_b["path"]
        assert reason =~ "Failed to parse"
      end)

    assert log =~ "[ModelRefs] Skipping workspace"
  end

  defp find_ref(refs, source), do: Enum.find(refs, &(&1.source == source))
end
