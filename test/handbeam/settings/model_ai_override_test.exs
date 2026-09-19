defmodule Handbeam.Settings.ModelAIOverrideTest do
  use ExUnit.Case, async: false

  alias Handbeam.Settings
  alias Handbeam.Settings.{ModelAIOverride, ModelAISettings}

  @env ~w(HANDBEAM_GLOBAL_SETTINGS_FILE)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_model_ai_override_#{System.unique_integer([:positive])}"
      )

    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("HANDBEAM_GLOBAL_SETTINGS_FILE", Path.join(dir, "settings.json"))

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{ws: ws}
  end

  test "save :global writes the full form; workspace save stores only the diff", %{ws: ws} do
    global = %{ModelAISettings.defaults() | default_model: "a/one", reasoning: "high"}
    assert :ok = ModelAIOverride.save(:global, global)
    assert Settings.global_model_ai().default_model == "a/one"

    assert :ok = ModelAIOverride.save({:workspace, ws}, %{global | reasoning: "low"})
    {:ok, raw} = Settings.load_workspace_model_ai(ws)
    assert raw == %{"reasoning" => "low"}

    assert ModelAIOverride.sources(ws) |> Map.take([:default_model, :reasoning]) ==
             %{default_model: :global, reasoning: :workspace}
  end

  test "inherit clears named fields; inherit_all clears everything", %{ws: ws} do
    global = %{ModelAISettings.defaults() | default_model: "a/one", reasoning: "high"}
    :ok = ModelAIOverride.save(:global, global)

    :ok =
      ModelAIOverride.save({:workspace, ws}, %{global | default_model: "b/two", reasoning: "low"})

    assert :ok = ModelAIOverride.inherit(ws, [:default_model])
    {:ok, raw} = Settings.load_workspace_model_ai(ws)
    assert raw == %{"reasoning" => "low"}
    assert Settings.effective_model_ai(ws).default_model == "a/one"

    assert :ok = ModelAIOverride.inherit_all(ws)
    assert {:ok, %{}} = Settings.load_workspace_model_ai(ws)
    assert Settings.effective_model_ai(ws).reasoning == "high"
  end

  test "sources treats an unreadable workspace file as no overrides", %{ws: ws} do
    path = Handbeam.WorkspaceSettings.path(ws)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{ broken")

    sources = ModelAIOverride.sources(ws)
    assert Enum.all?(sources, fn {_field, source} -> source == :global end)
    assert Map.keys(sources) |> Enum.sort() == Enum.sort(ModelAISettings.fields())
  end
end
