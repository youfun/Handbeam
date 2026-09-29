defmodule Handbeam.Agent.Tool.RecoveryTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.OperationReceipt
  alias Handbeam.Agent.Tool.{FileCommit, Result, ResultContract}
  alias Handbeam.Platform.ProcessRunner.Invocation
  alias Handbeam.Tool.Builtin.{Edit, Grep, Write}

  setup do
    root = Path.join(System.tmp_dir!(), "handbeam-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:handbeam, :conversation_root, root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: Path.join(root, "workspace")}
  end

  test "retry_of reuses a large write without sending the body again", %{workspace: workspace} do
    File.mkdir_p!(workspace)
    body = String.duplicate("saved-body\n", 2_000)
    context = %{working_directory: workspace, conversation_id: "conv-retry"}

    File.mkdir_p!(Path.join(workspace, "blocked"))

    assert {:error, reason, details} =
             Write.execute(%{"file_path" => "blocked", "content" => body}, context)

    assert reason =~ "directory"
    assert details.operation_id
    retry = %{"retry_of" => details.operation_id, "file_path" => "inside.txt"}
    assert byte_size(Handbeam.JSON.encode!(retry)) < 500
    assert {:ok, _text, meta} = Write.execute(retry, context)
    assert File.read!(Path.join(workspace, "inside.txt")) == body
    assert meta.side_effect == :committed
  end

  test "missing saved input artifact fails without writing empty content", %{
    root: root,
    workspace: workspace
  } do
    File.mkdir_p!(workspace)
    body = String.duplicate("saved-body\n", 2_000)
    context = %{working_directory: workspace, conversation_id: "conv-missing-artifact"}
    File.mkdir_p!(Path.join(workspace, "blocked"))

    assert {:error, _reason, details} =
             Write.execute(%{"file_path" => "blocked", "content" => body}, context)

    artifact =
      Path.join([
        root,
        "items",
        "conv-missing-artifact",
        "tool-inputs",
        "write",
        details.operation_id,
        "content.txt"
      ])

    File.rm!(artifact)

    assert {:error, reason, retry_details} =
             Write.execute(
               %{"retry_of" => details.operation_id, "file_path" => "recovered.txt"},
               context
             )

    assert reason =~ "artifact is unavailable"
    assert retry_details.code == :artifact_unavailable
    refute File.exists?(Path.join(workspace, "recovered.txt"))
  end

  test "edit retry reuses a large replacement and only overrides stale old text", %{
    workspace: workspace
  } do
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "edit.txt"), "current text\n")
    replacement = String.duplicate("replacement line\n", 1_000)
    context = %{working_directory: workspace, conversation_id: "conv-edit-retry"}

    assert {:error, reason, details} =
             Edit.execute(
               %{
                 "file_path" => "edit.txt",
                 "old_string" => "stale text",
                 "new_string" => replacement
               },
               context
             )

    assert reason =~ "Could not find text"

    retry = %{
      "retry_of" => details.operation_id,
      "file_path" => "edit.txt",
      "old_string" => "current text"
    }

    assert byte_size(Handbeam.JSON.encode!(retry)) < 500
    assert {:ok, _text, meta} = Edit.execute(retry, context)
    assert meta.side_effect == :committed
    assert File.read!(Path.join(workspace, "edit.txt")) == replacement <> "\n"
  end

  test "file commit reconciles a matching target and refuses a mismatch", %{workspace: workspace} do
    File.mkdir_p!(workspace)
    path = Path.join(workspace, "committed.txt")
    assert {:ok, commit} = FileCommit.commit(path, "expected", %{conversation_id: "conv-commit"})

    assert {:ok, reconciled} =
             FileCommit.reconcile(path, commit.after_sha256, commit.operation_id)

    assert reconciled.side_effect == :committed
    File.write!(path, "changed-later")

    assert {:error, _reason, details} =
             FileCommit.reconcile(path, commit.after_sha256, commit.operation_id)

    assert details.side_effect == :unknown
  end

  test "bounded details never retain original content" do
    body = String.duplicate("x", 20_000)

    projected =
      ResultContract.project(Result.new(body, %{original_content: body, exit_code: 0}), [])

    encoded = Handbeam.JSON.encode!(projected.details)
    refute encoded =~ body
    assert projected.details.exit_code == 0
  end

  test "invocation tail stays bounded while forwarding", %{workspace: workspace} do
    File.mkdir_p!(workspace)

    task =
      Task.async(fn ->
        Invocation.run(
          command: "printf '%1000000s' x",
          cwd: workspace,
          reply_to: self(),
          business_owner: self()
        )

        receive do
          {:invocation_result, _pid, result} -> result
        after
          5_000 -> :timeout
        end
      end)

    assert {:ok, output, _meta} = Task.await(task, 6_000)
    assert byte_size(output) < 80_000
  end

  test "invalid grep cursor does not restart at the first page", %{workspace: workspace} do
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "a.txt"), "marker\n")

    assert {:error, reason, details} =
             Grep.execute(
               %{"pattern" => "marker", "path" => ".", "cursor" => "not-a-cursor"},
               %{working_directory: workspace}
             )

    assert reason =~ "cursor"
    assert details.code == :cursor_invalid
  end

  test "delegated usage records do not replace an existing child", %{root: _root} do
    conversation = "parent-usage"

    assert {:ok, _} =
             Handbeam.ConversationStore.create("workspace", id: conversation, title: "parent")

    assert :ok =
             Handbeam.ConversationStore.record_delegated_usage(conversation, "child-a", %{
               "input_tokens" => 3
             })

    assert :ok =
             Handbeam.ConversationStore.record_delegated_usage(conversation, "child-b", %{
               "input_tokens" => 5
             })

    usage = Handbeam.ConversationStore.delegated_usage(conversation)
    assert usage["child-a"]["input_tokens"] == 3
    assert usage["child-b"]["input_tokens"] == 5

    assert :ok =
             Handbeam.ConversationStore.record_delegated_usage(conversation, "child-a", %{
               "input_tokens" => 99
             })

    assert Handbeam.ConversationStore.delegated_usage(conversation)["child-a"]["input_tokens"] ==
             3

    assert OperationReceipt.fingerprint("same") == OperationReceipt.fingerprint("same")
  end
end
