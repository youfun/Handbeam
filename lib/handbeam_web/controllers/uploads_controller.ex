defmodule HandbeamWeb.UploadsController do
  use HandbeamWeb, :controller

  alias Handbeam.Uploads
  alias Handbeam.WorkspaceStore

  @doc """
  Serve a previously uploaded file for a given conversation.

  Route:
    GET /uploads/:conversation_id/:file?ws_id=<workspace_id>
  """
  def show(conn, %{"conversation_id" => conversation_id, "file" => file} = params) do
    ws_id = Map.get(params, "ws_id")

    with {:ok, workspace_path} <- workspace_path_from_ws_id(ws_id),
         {:ok, full_path} <-
           Uploads.validate_served_upload_path(workspace_path, conversation_id, file),
         {:ok, %File.Stat{type: :regular}} <- File.stat(full_path) do
      content_type = MIME.from_path(full_path)

      conn
      |> put_resp_content_type(content_type)
      |> send_file(200, full_path)
    else
      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp workspace_path_from_ws_id(ws_id) when is_binary(ws_id) and ws_id != "" do
    case WorkspaceStore.get(ws_id) do
      {:ok, ws} -> {:ok, ws["path"]}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp workspace_path_from_ws_id(_), do: {:error, :missing_workspace_id}
end
