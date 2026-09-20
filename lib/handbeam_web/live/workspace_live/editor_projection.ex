defmodule HandbeamWeb.WorkspaceLive.EditorProjection do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4, stream_insert: 3]

  alias HandbeamWeb.ChangeHelper

  def open_diff(socket, entry) do
    change = ChangeHelper.change_from_entry(entry)
    diff_lines = Map.get(change, "diff_lines")
    path = Map.get(change, "file_path")

    if is_binary(path) and is_list(diff_lines) and diff_lines != [] do
      socket
      |> assign(:active_file, path)
      |> assign(:show_diff, true)
      |> assign(:diff_lines, diff_lines)
      |> assign(:active_change, change)
      |> assign(:revert_confirm_change_id, nil)
      |> assign(:revert_message, nil)
    else
      socket
    end
  end

  def close_diff(socket) do
    socket
    |> assign(:show_diff, false)
    |> assign(:diff_lines, nil)
    |> assign(:active_change, nil)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, nil)
  end

  def apply_revert_result(socket, change, result, workspace_root) do
    {status, result} = normalize_revert_result(result)
    message = Map.get(result, "message") || "Revert #{status}"
    change_id = Map.get(result, "change_id") || Map.get(change, "change_id")
    file_path = Map.get(result, "file_path") || Map.get(change, "file_path")

    revert_entry = %{
      "id" => "change-revert-#{System.unique_integer([:positive, :monotonic])}",
      "content_type" => "change_revert",
      "message_type" => "change_revert",
      "role" => "system",
      "change_id" => change_id,
      "file_path" => file_path,
      "status" => status,
      "message" => message,
      "inserted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    socket
    |> update_timeline_change_status(change_id, status)
    |> update_active_change_status(change_id, status)
    |> assign(:revert_confirm_change_id, nil)
    |> assign(:revert_message, %{"status" => status, "message" => message})
    |> append_revert_transcript(revert_entry)
    |> append_timeline(revert_entry)
    |> refresh_active_file_preview(file_path, workspace_root)
    |> persist_revert_status(change_id, status)
  end

  def maybe_add_diff_file(socket, file_path, diff_lines, workspace_root)
      when is_binary(file_path) and is_list(diff_lines) and diff_lines != [] do
    case Handbeam.Security.PathValidator.validate_within_workspace(
           Path.expand(file_path),
           workspace_root
         ) do
      :ok ->
        abs_path = Path.expand(file_path)

        if File.exists?(abs_path),
          do: add_editor_file(socket, abs_path, workspace_root),
          else: socket

      {:error, _reason} ->
        socket
    end
  end

  def maybe_add_diff_file(socket, _file_path, _diff_lines, _workspace_root), do: socket

  defp normalize_revert_result({:ok, result}), do: {"reverted", result}
  defp normalize_revert_result({:conflict, result}), do: {"conflict", result}
  defp normalize_revert_result({:error, result}), do: {"error", result}

  defp add_editor_file(socket, abs_path, workspace_root) do
    existing = socket.assigns.editor_files

    if Enum.any?(existing, &(HandbeamWeb.WorkspaceHelper.file_value(&1, "path", nil) == abs_path)) do
      socket
    else
      relative = Path.relative_to(abs_path, workspace_root)
      socket = assign(socket, :editor_files, existing ++ [%{path: abs_path, name: relative}])

      if socket.assigns.active_file == nil do
        socket
        |> assign(:active_file, abs_path)
        |> assign(:file_preview_error, load_file_error(abs_path, workspace_root))
      else
        socket
      end
    end
  end

  defp update_timeline_change_status(socket, change_id, status) do
    timeline =
      Enum.map(socket.assigns.timeline, fn entry ->
        change = ChangeHelper.change_from_entry(entry)

        if Map.get(change, "change_id") == change_id do
          details = Map.get(entry, "details") || %{}
          change = Map.put(change, "revert_status", status)

          entry
          |> Map.put("revert_status", status)
          |> Map.put("change", change)
          |> Map.put(
            "details",
            ChangeHelper.stringify_keys(details)
            |> Map.put("change", change)
            |> Map.put("revert_status", status)
          )
        else
          entry
        end
      end)

    socket |> assign(:timeline, timeline) |> stream(:timeline, timeline, reset: true)
  end

  defp update_active_change_status(socket, change_id, status) do
    case socket.assigns.active_change do
      %{"change_id" => ^change_id} = change ->
        assign(socket, :active_change, Map.put(change, "revert_status", status))

      _ ->
        socket
    end
  end

  defp append_timeline(socket, entry) do
    socket
    |> assign(:timeline, socket.assigns.timeline ++ [entry])
    |> stream_insert(:timeline, entry)
  end

  defp append_revert_transcript(socket, entry) do
    if is_binary(socket.assigns.current_conversation_id) do
      _ =
        Handbeam.ConversationTranscriptStore.append(
          socket.assigns.current_conversation_id,
          entry,
          []
        )
    end

    socket
  end

  defp persist_revert_status(socket, change_id, status) do
    conv_id = socket.assigns.current_conversation_id

    if is_binary(conv_id) and is_binary(change_id) do
      case Enum.find(socket.assigns.timeline, fn entry ->
             Map.get(ChangeHelper.change_from_entry(entry), "change_id") == change_id
           end) do
        %{"id" => entry_id} ->
          _ =
            Handbeam.ConversationTranscriptStore.update(
              conv_id,
              entry_id,
              %{
                "revert_status" => status,
                "change" => %{"revert_status" => status},
                "details" => %{
                  "revert_status" => status,
                  "change" => %{"revert_status" => status}
                }
              },
              []
            )

        _ ->
          :ok
      end
    end

    socket
  end

  defp refresh_active_file_preview(socket, file_path, workspace_root)
       when is_binary(file_path) do
    if socket.assigns.active_file == Path.expand(file_path) do
      assign(socket, :file_preview_error, load_file_error(file_path, workspace_root))
    else
      socket
    end
  end

  defp refresh_active_file_preview(socket, _file_path, _workspace_root), do: socket

  defp load_file_error(path, workspace_root) do
    with {:ok, _} <- Handbeam.Workspace.resolve(path, workspace_root),
         {:error, reason} <- File.read(path) do
      reason
    else
      {:ok, _contents} -> nil
      {:error, reason} -> reason
    end
  end
end
