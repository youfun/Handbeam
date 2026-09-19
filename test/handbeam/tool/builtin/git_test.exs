defmodule Handbeam.Tool.Builtin.GitTest do
  use ExUnit.Case, async: false

  alias Handbeam.Tool.Builtin.Git

  setup do
    work = Path.join(System.tmp_dir!(), "sigil_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf(work) end)
    {:ok, work: work, ctx: %{working_directory: work}}
  end

  test "rejects missing workspace and unknown action", %{ctx: ctx} do
    assert {:error, "working_directory is required"} = Git.execute(%{"action" => "status"}, %{})
    assert {:error, message} = Git.execute(%{"action" => "rebase"}, ctx)
    assert message =~ "unsupported"
  end

  test "rejects commit without a message and checkout without a target", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:error, message} = Git.execute(%{"action" => "commit"}, ctx)
    assert message =~ "message"
    assert {:error, target} = Git.execute(%{"action" => "checkout"}, ctx)
    assert target =~ "target"
    assert {:error, name} = Git.execute(%{"action" => "create_branch"}, ctx)
    assert name =~ "name"
  end

  test "blocks paths outside the workspace", %{ctx: ctx} do
    outside = System.tmp_dir!()

    assert {:error, message} =
             Git.execute(%{"action" => "status", "path" => outside}, ctx)

    assert message =~ "outside" or message =~ "Path traversal"
  end

  test "init, edit, status, commit, log, and checkout stay inside the workspace", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, init_out, %{action: :init}} = Git.execute(%{"action" => "init"}, ctx)
    assert init_out =~ "initialized"
    assert File.dir?(Path.join(work, ".git"))

    File.mkdir_p!(Path.join(work, "lib"))
    File.write!(Path.join(work, "lib/demo.ex"), "defmodule Demo do\nend\n")

    assert {:ok, status_out, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert status_out =~ "lib/demo.ex"
    assert Enum.any?(entries, &(&1.path == "lib/demo.ex"))

    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["lib/demo.ex"]}, ctx)

    assert {:error, message} = Git.execute(%{"action" => "commit"}, ctx)
    assert message =~ "message"

    assert {:ok, commit_out, %{oid: oid}} =
             Git.execute(%{"action" => "commit", "message" => "add demo"}, ctx)

    assert commit_out =~ oid
    assert {:ok, log_out, %{commits: [commit | _]}} = Git.execute(%{"action" => "log"}, ctx)
    assert log_out =~ "add demo"
    assert commit.summary == "add demo"

    assert {:ok, _, _} = Git.execute(%{"action" => "create_branch", "name" => "feature"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "checkout", "target" => "feature"}, ctx)
    assert {:ok, branches_out, _} = Git.execute(%{"action" => "branches"}, ctx)
    assert branches_out =~ "feature"

    File.write!(Path.join(work, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: :ok\nend\n")
    assert {:ok, patch, _} = Git.execute(%{"action" => "diff"}, ctx)
    assert patch =~ "def ok"

    assert {:ok, _, _} = Git.execute(%{"action" => "add", "paths" => ["lib/demo.ex"]}, ctx)

    assert {:ok, _, _} =
             Git.execute(%{"action" => "commit", "message" => "feature work"}, ctx)

    assert {:ok, _, _} = Git.execute(%{"action" => "checkout", "target" => "main"}, ctx)
    assert File.read!(Path.join(work, "lib/demo.ex")) == "defmodule Demo do\nend\n"
  end

  test "add and path reset use the discovered worktree, not the discovery directory", %{
    work: work,
    ctx: ctx
  } do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    File.mkdir_p!(Path.join(work, "sub"))
    File.write!(Path.join(work, "file.txt"), "root\n")
    File.write!(Path.join(work, "sub/file.txt"), "nested\n")
    assert {:ok, _, _} = Git.execute(%{"action" => "add"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "commit", "message" => "baseline"}, ctx)
    File.write!(Path.join(work, "file.txt"), "changed root\n")
    File.write!(Path.join(work, "sub/file.txt"), "changed nested\n")

    input = %{"path" => "sub", "paths" => ["sub/file.txt"]}
    assert {:ok, _, _} = Git.execute(Map.put(input, "action", "add"), ctx)
    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert Enum.find(entries, &(&1.path == "sub/file.txt")).staged == :modified
    assert Enum.find(entries, &(&1.path == "file.txt")).staged == nil

    assert {:ok, _, _} = Git.execute(Map.put(input, "action", "reset"), ctx)
    assert {:ok, _, %{entries: entries}} = Git.execute(%{"action" => "status"}, ctx)
    assert Enum.all?(entries, &is_nil(&1.staged))
  end

  test "rejects an intermediate symlink that points outside the workspace", %{
    work: work,
    ctx: ctx
  } do
    outside =
      Path.join(System.tmp_dir!(), "sigil_git_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(work, "escape"))
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, message} =
             Git.execute(%{"action" => "init", "path" => "escape/repo"}, ctx)

    assert message =~ "outside" or message =~ "Path traversal"
    refute File.dir?(Path.join(outside, "repo/.git"))
  end

  test "clone rejects ssh urls and credentials embedded in the url", %{ctx: ctx} do
    assert {:error, ssh} =
             Git.execute(%{"action" => "clone", "url" => "ssh://git@example.com/repo.git"}, ctx)

    assert ssh =~ "http"

    assert {:error, creds} =
             Git.execute(
               %{"action" => "clone", "url" => "https://user:token@github.com/youfun/ex-git.git"},
               ctx
             )

    assert creds =~ "credentials"
  end

  test "remote_add rejects ssh urls and credentials embedded in the url", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)

    assert {:error, ssh} =
             Git.execute(
               %{"action" => "remote_add", "url" => "ssh://git@example.com/repo.git"},
               ctx
             )

    assert ssh =~ "http"

    assert {:error, creds} =
             Git.execute(
               %{
                 "action" => "remote_add",
                 "url" => "https://user:token@github.com/youfun/ex-git.git"
               },
               ctx
             )

    assert creds =~ "credentials"
  end

  test "remote_add requires a url", %{ctx: ctx} do
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:error, message} = Git.execute(%{"action" => "remote_add"}, ctx)
    assert message =~ "url"
  end

  test "init remotes is empty; remote_add and remote_set_url only write config", %{ctx: ctx} do
    url = "https://example.com/owner/repo.git"
    other = "https://example.com/owner/other.git"

    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:ok, empty, %{remotes: []}} = Git.execute(%{"action" => "remotes"}, ctx)
    assert empty =~ "no remotes"

    assert {:ok, added, %{name: "origin", url: ^url}} =
             Git.execute(%{"action" => "remote_add", "url" => url}, ctx)

    assert added =~ "origin"
    assert added =~ url

    assert {:ok, listed, %{remotes: [remote]}} = Git.execute(%{"action" => "remotes"}, ctx)
    assert listed =~ "origin"
    assert listed =~ url
    assert remote.name == "origin"
    assert remote.url == url

    assert {:ok, updated, %{url: ^other}} =
             Git.execute(%{"action" => "remote_set_url", "url" => other}, ctx)

    assert updated =~ other
    assert {:ok, _, %{remotes: [changed]}} = Git.execute(%{"action" => "remotes"}, ctx)
    assert changed.url == other
  end

  test "duplicate remote_add returns an exists error", %{ctx: ctx} do
    url = "https://example.com/owner/repo.git"
    assert {:ok, _, _} = Git.execute(%{"action" => "init"}, ctx)
    assert {:ok, _, _} = Git.execute(%{"action" => "remote_add", "url" => url}, ctx)

    assert {:error, message} = Git.execute(%{"action" => "remote_add", "url" => url}, ctx)
    assert message =~ "exists"
  end

  test "auth_opts keeps a password without a username" do
    assert Handbeam.Git.auth_opts(password: "ghp_test") == [password: "ghp_test"]

    assert Handbeam.Git.auth_opts(username: "me", password: "ghp_test") == [
             username: "me",
             password: "ghp_test"
           ]

    assert Handbeam.Git.auth_opts(username: "me") == [username: "me"]
    assert Handbeam.Git.auth_opts(username: "", password: "ghp_test") == [password: "ghp_test"]
  end

  test "raw credentials and unknown credential references are rejected before execution", %{
    ctx: ctx
  } do
    assert {:error, message} =
             Git.execute(%{"action" => "push", "password" => "fixture-secret"}, ctx)

    assert message =~ "raw Git credentials are not accepted"
    refute message =~ "fixture-secret"

    assert {:error, "Git credential is not configured by the host"} =
             Git.execute(%{"action" => "push", "credential" => "missing-review-credential"}, ctx)
  end

  test "host credential lookup preserves the authentication endpoint through the Git adapter" do
    previous = Application.fetch_env(:handbeam, :git_credentials)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:handbeam, :git_credentials, value)
        :error -> Application.delete_env(:handbeam, :git_credentials)
      end
    end)

    Application.put_env(:handbeam, :git_credentials, %{
      "review" => [endpoint: "https://example.com", password: "fixture-secret"],
      "insecure" => [endpoint: "http://example.com", password: "fixture-secret"],
      "path" => [endpoint: "https://example.com/repo.git", password: "fixture-secret"]
    })

    assert {:ok, opts} = Handbeam.Git.Credentials.resolve("review")
    assert opts[:credential_endpoint] == "https://example.com"
    assert opts[:password] == "fixture-secret"
    assert Handbeam.Git.auth_opts(opts) == opts
    assert {:error, _} = Handbeam.Git.Credentials.resolve("insecure")
    assert {:error, _} = Handbeam.Git.Credentials.resolve("path")
    assert {:ok, []} = Handbeam.Git.Credentials.resolve(nil)
  end

  test "schema advertises remote actions and credential references, not raw credentials" do
    schema = Git.input_schema()
    assert Map.has_key?(schema.properties, :credential)
    refute Map.has_key?(schema.properties, :password)
    refute Map.has_key?(schema.properties, :username)
    enum = schema.properties.action.enum
    assert "remotes" in enum
    assert "remote_add" in enum
    assert "remote_set_url" in enum
    refute "ssh" in enum
    description = Git.description()
    assert description =~ "remote_add"
    assert description =~ "PAT"
    assert description =~ "fast-forward"
    refute description =~ "GitHub App"
  end
end
