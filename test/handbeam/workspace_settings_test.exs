defmodule Handbeam.WorkspaceSettingsTest do
  use ExUnit.Case, async: true

  alias Handbeam.WorkspaceSettings

  defp tmp_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_workspace_settings_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    dir
  end

  defp write_settings(workspace, content) do
    path = WorkspaceSettings.path(workspace)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  test "path points at workspace .handbeam/settings.jsonc" do
    workspace = tmp_workspace()
    assert WorkspaceSettings.path(workspace) == Path.join(workspace, ".handbeam/settings.jsonc")
  end

  test "missing settings file loads as empty unrestricted settings" do
    workspace = tmp_workspace()
    assert WorkspaceSettings.load(workspace) == {:ok, %{}}
    assert WorkspaceSettings.models_policy(workspace) == :unrestricted

    assert WorkspaceSettings.beam_tools_config(workspace) == %{
             auto: true,
             eval: false,
             explicit: []
           }
  end

  test "parses JSONC comments and trailing commas" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // models are workspace-local restrictions
      "models": {
        "default": {
          "provider": "local",
          "model": "qwen",
        },
        "allow": {
          "providers": {
            "local": {
              "models": ["qwen",],
            },
          },
        },
      },
      /*
       * BEAM tools are controlled separately from models.
       */
      "tools": {
        "beam": {
          "auto": false,
          "eval": true,
        },
        "explicit": ["ext__beam__eval",],
      },
    }
    """)

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["models", "default", "model"]) == "qwen"
    assert get_in(settings, ["models", "allow", "providers", "local", "models"]) == ["qwen"]

    assert WorkspaceSettings.models_policy(workspace) ==
             {:ok,
              %{
                "default" => %{"provider" => "local", "model" => "qwen"},
                "allow" => %{"providers" => %{"local" => %{"models" => ["qwen"]}}}
              }}

    assert WorkspaceSettings.beam_tools_config(workspace) == %{
             auto: false,
             eval: true,
             explicit: ["ext__beam__eval"]
           }
  end

  test "invalid JSONC returns an error" do
    workspace = tmp_workspace()
    write_settings(workspace, ~s({"models": ))

    assert {:error, reason} = WorkspaceSettings.load(workspace)
    assert reason =~ "Failed to parse"
  end

  test "ensure_file writes commented defaults without overwriting existing settings" do
    workspace = tmp_workspace()

    assert :ok = WorkspaceSettings.ensure_file(workspace)
    content = File.read!(WorkspaceSettings.path(workspace))

    assert content =~ "settings.jsonc"
    assert content =~ "\"eval\": false"
    assert content =~ "\"providers\": {}"

    File.write!(WorkspaceSettings.path(workspace), ~s({"custom": true}))
    assert :ok = WorkspaceSettings.ensure_file(workspace)
    assert File.read!(WorkspaceSettings.path(workspace)) == ~s({"custom": true})
  end

  test "update_default_mode/2 updates default tool mode and preserves JSONC comments" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // Some comment here
      "tools": {
        // Mode settings
        "default_mode": "auto",
        "beam": {
          "auto": true
        }
      }
    }
    """)

    assert :ok = WorkspaceSettings.update_default_mode(workspace, :prompt)

    content = File.read!(WorkspaceSettings.path(workspace))
    assert content =~ "// Some comment here"
    assert content =~ "// Mode settings"
    assert content =~ "\"default_mode\": \"prompt\""

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "prompt"
  end

  test "update_default_mode/2 creates default file and updates it if missing" do
    workspace = tmp_workspace()

    assert :ok = WorkspaceSettings.update_default_mode(workspace, :deny)

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "deny"
  end

  test "approvals_reviewer defaults to user and rejects unknown values" do
    assert WorkspaceSettings.approvals_reviewer_from_settings(%{}) == :user
    assert WorkspaceSettings.approvals_reviewer_from_settings(%{"tools" => %{}}) == :user

    assert WorkspaceSettings.approvals_reviewer_from_settings(%{
             "tools" => %{"approvals_reviewer" => "yolo"}
           }) == :user

    assert WorkspaceSettings.approvals_reviewer_from_settings(%{
             "tools" => %{"approvals_reviewer" => "auto_review"}
           }) == :auto_review

    assert WorkspaceSettings.auto_review_config(%{}) == %{model: nil, timeout_ms: 30_000}

    assert WorkspaceSettings.auto_review_config(%{
             "tools" => %{"auto_review" => %{"model" => "  ", "timeout_ms" => 1500}}
           }) == %{model: nil, timeout_ms: 1500}
  end

  test "update_approvals_reviewer preserves comments and default_mode" do
    workspace = tmp_workspace()

    write_settings(workspace, """
    {
      // keep this comment
      "tools": {
        "default_mode": "prompt",
        "allow": ["read"]
      }
    }
    """)

    assert :ok = WorkspaceSettings.update_approvals_reviewer(workspace, :auto_review)

    content = File.read!(WorkspaceSettings.path(workspace))
    assert content =~ "// keep this comment"
    assert content =~ "\"default_mode\": \"prompt\""
    assert content =~ "\"allow\": [\"read\"]"
    assert content =~ "\"approvals_reviewer\": \"auto_review\""

    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "default_mode"]) == "prompt"
    assert get_in(settings, ["tools", "allow"]) == ["read"]
    assert get_in(settings, ["tools", "approvals_reviewer"]) == "auto_review"

    assert :ok = WorkspaceSettings.update_approvals_reviewer(workspace, :user)
    assert {:ok, settings} = WorkspaceSettings.load(workspace)
    assert get_in(settings, ["tools", "approvals_reviewer"]) == "user"
    assert get_in(settings, ["tools", "default_mode"]) == "prompt"
    assert File.read!(WorkspaceSettings.path(workspace)) =~ "// keep this comment"
  end
end
