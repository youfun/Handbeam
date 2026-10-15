defmodule HandbeamWeb.WorkspaceMediaController do
  use HandbeamWeb, :controller

  alias Handbeam.Attachments.Access
  alias Handbeam.Attachments.Type
  alias Handbeam.Security.PathValidator
  alias Handbeam.WorkspaceFiles
  alias Handbeam.WorkspaceStore

  @max_bytes 25 * 1024 * 1024

  @doc """
  Serve a bounded workspace image through the browser access boundary.

  GET /workspace-files/:workspace_id/*path (each path segment URI-encoded)
  """
  def show(conn, params) do
    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")

    with %{"workspace_id" => workspace_id, "path" => segments} when is_list(segments) <- params,
         relative_path = Enum.join(segments, "/"),
         {:ok, %{"path" => root}} <- WorkspaceStore.get(workspace_id),
         {:ok, path} <- WorkspaceFiles.resolve(root, relative_path, :file),
         :ok <- PathValidator.validate_within_workspace(path, root),
         :ok <- PathValidator.reject_resolved(path),
         :ok <- PathValidator.validate_readable(path),
         {:ok, :image, mime} <- WorkspaceFiles.kind_from_name(path),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <-
           File.lstat(path),
         {:ok, bytes} <- Access.read_bounded(path, @max_bytes),
         :ok <- Type.match(mime, Path.basename(path), bytes) do
      conn
      |> put_resp_content_type(mime)
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end
end
