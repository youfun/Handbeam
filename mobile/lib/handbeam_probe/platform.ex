defmodule HandbeamProbe.Platform do
  @moduledoc """
  Typed import/export lifecycle. JNI sees only request_id, generation, and a small JSON payload.
  """

  alias Handbeam.ExportSnapshot
  alias Handbeam.Security.PathValidator
  alias HandbeamProbe.Platform.{Nif, Request}

  @spec start(Request.t(), keyword()) :: {:ok, :async} | {:ok, map()} | {:error, term()}
  def start(%Request{} = req, opts \\ []) do
    case Application.get_env(:handbeam_probe, :platform_fake) do
      fun when is_function(fun, 2) -> fun.(req, opts)
      _ -> Nif.command(req, opts)
    end
  end

  @spec request(Request.t() | term(), keyword()) ::
          {:ok, :async} | {:ok, map()} | {:error, term()}
  def request(req, opts \\ [])
  def request(%Request{} = req, opts), do: start(req, opts)
  def request(_, _), do: {:error, :invalid_platform_request}

  @spec import_file(pid(), String.t(), integer(), String.t(), map()) ::
          {:ok, :async} | {:error, term()}
  def import_file(caller, request_id, generation, path, extra \\ %{})
      when is_pid(caller) and is_binary(request_id) and is_binary(path) do
    payload =
      extra
      |> stringify_keys()
      |> Map.take(["display_name", "mime", "workspace_id", "conversation_id"])
      |> Map.merge(%{"op" => "platform_import", "path" => path})

    start(Request.new("platform_import", request_id, generation, caller, payload))
  end

  @spec export_request(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def export_request(caller, request_id, generation, workspace_path, relative_path)
      when is_pid(caller) and is_binary(workspace_path) and is_binary(relative_path) do
    case ExportSnapshot.authorize(workspace_path, relative_path) do
      {:ok, authorized} ->
        {:ok,
         Request.new("platform_export", request_id, generation, caller, %{
           "op" => "platform_export",
           "workspace_path" => workspace_path,
           "path" => authorized.path,
           "relative_path" => authorized.relative_path,
           "owner_request_id" => request_id
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec export_file(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def export_file(caller, request_id, generation, workspace_path, relative_path) do
    case export_request(caller, request_id, generation, workspace_path, relative_path) do
      {:ok, req} -> start(req)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The `platform_open_url` request. Both the UI tap and the Agent tool build it here."
  @spec open_url_request(pid(), String.t(), integer(), String.t()) :: Request.t()
  def open_url_request(caller, request_id, generation, url)
      when is_pid(caller) and is_binary(url) do
    Request.new("platform_open_url", request_id, generation, caller, %{
      "op" => "platform_open_url",
      "url" => url,
      "deadline_ms" => deadline_ms()
    })
  end

  @spec open_url(pid(), String.t(), integer(), String.t()) :: {:ok, :async} | {:error, term()}
  def open_url(caller, request_id, generation, url),
    do: start(open_url_request(caller, request_id, generation, url))

  @doc "User-tapped text share. Wraps host `MobBridge.shareText`; not an Agent tool."
  @spec share_text_request(pid(), String.t(), integer(), String.t()) ::
          {:ok, Request.t()} | {:error, term()}
  def share_text_request(caller, request_id, generation, text)
      when is_pid(caller) and is_binary(request_id) do
    case HandbeamProbe.WritingPhotoReviews.shareable_text(text) do
      {:ok, body} ->
        {:ok,
         Request.new("platform_share_text", request_id, generation, caller, %{
           "op" => "platform_share_text",
           "text" => body,
           "deadline_ms" => deadline_ms()
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec share_text(pid(), String.t(), integer(), String.t()) :: {:ok, :async} | {:error, term()}
  def share_text(caller, request_id, generation, text) do
    case share_text_request(caller, request_id, generation, text) do
      {:ok, req} -> start(req)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The present step of the artifact sequence (`export` → snapshot → present):
  `platform_open_snapshot` or `platform_share_snapshot` for a pinned snapshot.
  Both the UI tap and the Agent tool build it here.
  """
  @spec present_request(
          :open_file | :share_file,
          pid(),
          String.t(),
          integer(),
          String.t(),
          String.t()
        ) :: {:ok, Request.t()} | {:error, :file_unavailable}
  def present_request(action, caller, request_id, generation, snapshot_id, owner_request_id)
      when action in [:open_file, :share_file] and is_pid(caller) do
    if is_binary(snapshot_id) and snapshot_id != "" and is_binary(owner_request_id) and
         owner_request_id != "" do
      op = if action == :share_file, do: "platform_share_snapshot", else: "platform_open_snapshot"

      {:ok,
       Request.new(op, request_id, generation, caller, %{
         "op" => op,
         "snapshot_id" => snapshot_id,
         "owner_request_id" => owner_request_id,
         "deadline_ms" => deadline_ms()
       })}
    else
      {:error, :file_unavailable}
    end
  end

  @spec share_snapshot(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def share_snapshot(caller, request_id, generation, snapshot_id, owner_request_id),
    do: present(:share_file, caller, request_id, generation, snapshot_id, owner_request_id)

  @spec open_snapshot(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def open_snapshot(caller, request_id, generation, snapshot_id, owner_request_id),
    do: present(:open_file, caller, request_id, generation, snapshot_id, owner_request_id)

  @doc "Start the present step of the artifact sequence."
  @spec present(:open_file | :share_file, pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def present(action, caller, request_id, generation, snapshot_id, owner_request_id) do
    case present_request(action, caller, request_id, generation, snapshot_id, owner_request_id) do
      {:ok, req} -> start(req)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup_snapshot(pid(), String.t(), integer(), String.t(), String.t()) ::
          {:ok, :async} | {:error, term()}
  def cleanup_snapshot(caller, request_id, generation, snapshot_id, owner_request_id)
      when is_pid(caller) and is_binary(snapshot_id) and is_binary(owner_request_id) do
    start(
      Request.new("platform_cleanup", request_id, generation, caller, %{
        "op" => "platform_cleanup",
        "snapshot_id" => snapshot_id,
        "owner_request_id" => owner_request_id
      })
    )
  end

  @spec cancel(pid(), String.t(), integer()) :: {:ok, :async} | {:error, term()}
  def cancel(caller, target_request_id, generation)
      when is_pid(caller) and is_binary(target_request_id) do
    command_id = Ecto.UUID.generate()

    start(
      Request.new("platform_cancel", command_id, generation, caller, %{
        "op" => "platform_cancel",
        "target_request_id" => target_request_id
      })
    )
  end

  @spec import_roots() :: [String.t()]
  def import_roots do
    :handbeam_probe
    |> Application.get_env(:staging_roots, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @spec safe_rm_controlled(term()) :: :ok | {:error, term()}
  def safe_rm_controlled(path) when is_binary(path) do
    abs = Path.expand(path)

    if import_owned?(abs) and File.regular?(abs) do
      File.rm(abs)
    else
      {:error, :outside_import_root}
    end
  end

  def safe_rm_controlled(_), do: {:error, :outside_import_root}

  @spec import_owned?(String.t()) :: boolean()
  def import_owned?(path) when is_binary(path) do
    abs = Path.expand(path)

    Enum.any?(import_roots(), fn root ->
      PathValidator.validate_within_workspace(abs, Path.expand(root)) == :ok
    end)
  end

  def import_owned?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp deadline_ms do
    System.system_time(:millisecond) +
      Application.get_env(:handbeam_probe, :android_intent_await_ms, 20_000)
  end
end
