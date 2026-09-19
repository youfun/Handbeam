defmodule Handbeam.Tool.Builtin.AndroidIntentTest do
  use ExUnit.Case, async: false

  alias Handbeam.ExportSnapshot
  alias Handbeam.ExportSnapshot.Binding
  alias Handbeam.Tool.Builtin.{AndroidOpenFile, AndroidOpenUrl, AndroidShareFile}

  setup do
    previous = Application.get_env(:handbeam, :android_intent)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :android_intent, previous),
        else: Application.delete_env(:handbeam, :android_intent)
    end)

    :ok
  end

  test "open url rejects extra intent fields and non-http schemes" do
    Application.put_env(:handbeam, :android_intent, fn _cmd, _ctx ->
      flunk("must not dispatch")
    end)

    assert {:error, _} =
             AndroidOpenUrl.execute(%{"url" => "https://a.com", "action" => "VIEW"}, %{})

    assert {:error, _} = AndroidOpenUrl.execute(%{"url" => "file:///tmp/x"}, %{})
  end

  test "open url reports ui_presented without claiming the page was read" do
    Application.put_env(:handbeam, :android_intent, fn cmd, _ctx ->
      assert cmd.op == :open_url
      assert cmd.url == "https://example.com/order"
      {:ok, %{outcome: "ui_presented", url: cmd.url}}
    end)

    assert {:ok, text, %{outcome: "ui_presented"}} =
             AndroidOpenUrl.execute(%{"url" => "https://example.com/order"}, %{})

    assert text =~ "界面已出现"
    assert text =~ "不表示对方已阅读"
  end

  test "file tools reject traversal and bind the approved snapshot" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "report.pdf"), "pdf")

    Binding.put("conv-1", "call-1", %{
      snapshot_id: "snap-1",
      owner_request_id: "owner-1",
      relative_path: "report.pdf",
      workspace_path: dir,
      action: :share_file
    })

    Application.put_env(:handbeam, :android_intent, fn cmd, _ctx ->
      assert cmd.op == :share_file
      assert cmd.snapshot_id == "snap-1"
      refute Map.has_key?(cmd, :action)
      {:ok, %{outcome: "chooser_presented", snapshot_id: "snap-1"}}
    end)

    assert {:ok, text, %{outcome: "chooser_presented"}} =
             AndroidShareFile.execute(%{"path" => "report.pdf"}, %{
               working_directory: dir,
               conversation_id: "conv-1",
               tool_call_id: "call-1"
             })

    assert text =~ "选择器已出现"
    assert text =~ "不表示文件已发送"
    assert :error = Binding.fetch("conv-1", "call-1")

    assert {:error, _} =
             AndroidOpenFile.execute(%{"path" => "../secret"}, %{working_directory: dir})

    File.rm_rf!(dir)
  end

  test "missing binding fails and never recopies the source" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "ok.txt"), "ok")

    Application.put_env(:handbeam, :android_intent, fn cmd, _ ->
      flunk("must not dispatch #{inspect(cmd)}")
    end)

    assert {:error, text} =
             AndroidOpenFile.execute(%{"path" => "ok.txt"}, %{
               working_directory: dir,
               conversation_id: "conv-x",
               tool_call_id: "missing"
             })

    assert text =~ "导出副本不可用"
    assert {:error, :invalid_path} = ExportSnapshot.authorize(dir, "/etc/passwd")
    File.rm_rf!(dir)
  end

  test "execute uses the approved snapshot after the source file is deleted" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gone.txt"), "bytes")

    Binding.put("conv-2", "call-2", %{
      snapshot_id: "snap-gone",
      owner_request_id: "owner-2",
      relative_path: "gone.txt",
      workspace_path: dir,
      action: :open_file
    })

    File.rm!(Path.join(dir, "gone.txt"))

    Application.put_env(:handbeam, :android_intent, fn cmd, _ctx ->
      assert cmd.op == :open_file
      assert cmd.snapshot_id == "snap-gone"
      refute Map.has_key?(cmd, :path)
      {:ok, %{outcome: "ui_presented", snapshot_id: "snap-gone"}}
    end)

    assert {:ok, _, %{outcome: "ui_presented"}} =
             AndroidOpenFile.execute(%{"path" => "gone.txt"}, %{
               working_directory: dir,
               conversation_id: "conv-2",
               tool_call_id: "call-2"
             })

    File.rm_rf!(dir)
  end

  test "binding must match conversation workspace path and action" do
    dir = Path.join(System.tmp_dir!(), "android_intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Binding.put("conv-3", "call-3", %{
      snapshot_id: "snap-3",
      owner_request_id: "owner-3",
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    Application.put_env(:handbeam, :android_intent, fn cmd, _ ->
      flunk("must not dispatch #{inspect(cmd)}")
    end)

    assert {:error, _} =
             AndroidShareFile.execute(%{"path" => "a.txt"}, %{
               working_directory: dir,
               conversation_id: "conv-3",
               tool_call_id: "call-3"
             })

    File.rm_rf!(dir)
  end
end
