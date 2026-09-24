defmodule HandbeamProbe.GitBackendTest do
  use ExUnit.Case, async: false

  alias Handbeam.Tool.Builtin.Git

  setup do
    previous = Application.get_env(:handbeam, :host)
    work = Path.join(System.tmp_dir!(), "probe-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    git_config = Path.join(work, "git.json")
    previous_config = Application.get_env(:handbeam, :git_user_config_path)
    Application.put_env(:handbeam, :git_user_config_path, git_config)

    Handbeam.Host.put!(%{
      shell: false,
      terminal: false,
      desktop_browser: false,
      webview_browser: true,
      system_intents: true,
      git_backend: Handbeam.Git.ExGit
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)

      if previous_config,
        do: Application.put_env(:handbeam, :git_user_config_path, previous_config),
        else: Application.delete_env(:handbeam, :git_user_config_path)

      File.rm_rf(work)
    end)

    {:ok, work: work, ctx: %{working_directory: work}}
  end

  test "phone host injects ExGit instead of the Git CLI" do
    assert Handbeam.Git.backend() == Handbeam.Git.ExGit
    assert Handbeam.Git.backend_kind() == :ex_git_libgit2
    assert Handbeam.Tool.Builtin.Git in Handbeam.Tool.Registry.host_tool_modules()
    assert Code.ensure_loaded?(ExGit)
    beam = :code.which(Handbeam.Git.ExGit) |> to_string()
    assert beam =~ "handbeam_probe"
    refute beam =~ "/handbeam/ebin/"
  end

  test "ExGit backend preserves init/status/commit/log contracts", %{work: work, ctx: ctx} do
    case Handbeam.Git.ExGit.available() do
      :ok ->
        :ok

      {:error, reason} ->
        flunk("mobile Git tests need the host ExGit NIF, not libex_git_nif.so: #{reason}")
    end

    assert {:ok, init_out, %{action: :init}} = Git.execute(%{"action" => "init"}, ctx)
    assert init_out =~ "initialized"
    File.write!(Path.join(work, "demo.txt"), "ok\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["demo.txt"]}, ctx)

    assert {:ok, _, %{oid: oid}} =
             Git.execute(%{"action" => "commit", "message" => "add demo"}, ctx)

    assert {:ok, log_out, %{commits: [commit | _]}} = Git.execute(%{"action" => "log"}, ctx)
    assert log_out =~ "add demo"
    assert commit.summary == "add demo"
    assert oid == commit.oid
  end
end
