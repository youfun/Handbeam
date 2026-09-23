defmodule HandbeamProbe.NativeArtifactDeliveryTest do
  use ExUnit.Case, async: false

  alias Handbeam.ExportSnapshot.Binding
  alias HandbeamProbe.{NativeArtifactDelivery, PendingRequests}

  setup do
    unless Process.whereis(Binding) do
      {:ok, _} = Binding.start_link([])
    end

    previous = Application.get_env(:handbeam_probe, :platform_fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam_probe, :platform_fake, previous),
        else: Application.delete_env(:handbeam_probe, :platform_fake)
    end)

    :ok
  end

  test "repeat approval export for the same seq is deduped" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "a.txt"), "a")

    Application.put_env(:handbeam_probe, :platform_fake, fn req, _ ->
      send(test, {:export, req.request_id})
      {:ok, :async}
    end)

    chat =
      chat(dir, "c1", 1, [
        %{
          "tool_call_id" => "t1",
          "tool_name" => "android_open_file",
          "arguments" => %{"path" => "a.txt"}
        }
      ])

    socket = socket(dir, chat)

    socket = NativeArtifactDelivery.start_approval_exports(socket, chat)
    socket = NativeArtifactDelivery.start_approval_exports(socket, chat)

    assert_received {:export, _}
    refute_received {:export, _}
    assert MapSet.size(socket.assigns.approval_export_inflight) == 1
  end

  test "stale export results cannot overwrite the current binding" do
    dir = tmp_ws()
    chat = chat(dir, "c-now", 9, [])

    socket =
      socket(dir, chat)
      |> Map.update!(
        :assigns,
        &Map.put(&1, :approval_snapshots, %{"t1" => %{snapshot_id: "keep"}})
      )

    stale = %{
      conversation_id: "c-old",
      approval_seq: 1,
      tool_call_id: "t1",
      workspace_path: dir,
      request_id: "old"
    }

    refute NativeArtifactDelivery.current_export_target?(socket, stale)

    socket =
      NativeArtifactDelivery.handle_result(
        socket,
        Map.put(stale, :kind, :approval_export),
        {:ok, %{"snapshot_id" => "stale"}}
      )

    assert socket.assigns.approval_snapshots["t1"].snapshot_id == "keep"
    assert :error = Binding.fetch("c-old", "t1")
  end

  test "cleanup keeps approved snapshots until consume" do
    dir = tmp_ws()

    Binding.put("c-keep", "t-keep", %{
      snapshot_id: "snap",
      relative_path: "a.txt",
      workspace_path: dir,
      action: :open_file
    })

    chat = %{conversation: %{"id" => "c-keep"}, pending_approval: nil, approval_seq: nil}
    socket = socket(dir, chat)

    socket = %{
      socket
      | assigns:
          Map.put(socket.assigns, :approval_snapshots, %{
            "t-keep" => %{snapshot_id: "snap", owner_request_id: "o"}
          })
    }

    Application.put_env(:handbeam_probe, :platform_fake, fn req, _ ->
      flunk("must not cleanup #{inspect(req)}")
    end)

    socket = NativeArtifactDelivery.cleanup_bindings(socket)
    assert {:ok, _} = Binding.fetch("c-keep", "t-keep")
    assert socket.assigns.approval_snapshots["t-keep"].snapshot_id == "snap"
  end

  test "file action authorizes once through Platform and tracks the trimmed path" do
    test = self()
    dir = tmp_ws()
    File.write!(Path.join(dir, "report.pdf"), "%PDF")

    Application.put_env(:handbeam_probe, :platform_fake, fn req, _ ->
      send(test, {:platform_export, req})
      {:ok, :async}
    end)

    socket = socket(dir, chat(dir, "c1", 1, []))
    socket = NativeArtifactDelivery.start_file_action(socket, :open_file, "  report.pdf  ")

    assert socket.assigns.notice == nil
    assert_received {:platform_export, %{op: "platform_export", payload: payload} = req}
    refute_received {:platform_export, _}
    assert payload["relative_path"] == "report.pdf"
    assert payload["path"] == Path.join(dir, "report.pdf")
    assert payload["workspace_path"] == dir

    assert %{kind: :delivery_export, next: :open_file, relative_path: "report.pdf"} =
             PendingRequests.ctx(socket.assigns.pending_requests, req.request_id)
  end

  test "file action rejects an unauthorized path without a platform request" do
    dir = tmp_ws()

    Application.put_env(:handbeam_probe, :platform_fake, fn req, _ ->
      flunk("must not export #{inspect(req)}")
    end)

    socket = socket(dir, chat(dir, "c1", 1, []))

    missing = NativeArtifactDelivery.start_file_action(socket, :share_file, "missing.txt")
    assert is_binary(missing.assigns.notice.text)
    assert PendingRequests.empty?(missing.assigns.pending_requests)

    traversal = NativeArtifactDelivery.start_file_action(socket, :open_file, "../etc/passwd")
    assert is_binary(traversal.assigns.notice.text)
    assert PendingRequests.empty?(traversal.assigns.pending_requests)
  end

  test "human_error never raises on tuple or unexpected reasons" do
    for reason <- [{:not_regular, :directory}, {:error, :enoent}, %{code: 1}, :unknown_reason] do
      assert is_binary(NativeArtifactDelivery.human_error(reason))
    end

    assert NativeArtifactDelivery.human_error(:invalid_url) =~ "http"
  end

  test "timeline_target converts an absolute path with the current workspace" do
    ws = "/tmp/native-delivery-ws"
    abs = Path.join(ws, "out/report.pdf")

    assert {:file, "out/report.pdf"} =
             NativeArtifactDelivery.timeline_target(
               %{"tool_name" => "write", "input" => %{"file_path" => abs}},
               ws
             )

    assert NativeArtifactDelivery.timeline_target(
             %{"tool_name" => "write", "input" => %{"file_path" => "/etc/passwd"}},
             ws
           ) == nil
  end

  defp tmp_ws do
    dir = Path.join(System.tmp_dir!(), "ndel_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp chat(dir, id, seq, requests) do
    %{
      conversation: %{"id" => id},
      approval_seq: seq,
      pending_approval: %{"action_requests" => requests},
      workspace_path: dir
    }
  end

  defp socket(dir, chat) do
    %{
      assigns: %{
        chat: chat,
        workspace: %{"id" => "ws", "path" => dir},
        pending_requests: PendingRequests.new(),
        approval_snapshots: %{},
        approval_export_inflight: MapSet.new()
      }
    }
  end
end
