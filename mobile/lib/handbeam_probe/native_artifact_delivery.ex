defmodule HandbeamProbe.NativeArtifactDelivery do
  @moduledoc """
  Product entry for system-browser open and artifact open / share
  (formerly `HandbeamProbe.NativeDelivery`; renamed so it is not confused with
  `Handbeam.Delivery`, the outbound channel adapter).

  There is one artifact sequence, and both the UI tap and the Agent tool walk
  it through the same `HandbeamProbe.Platform` functions:

      Platform.export_file/5  →  snapshot (Inbound.Snapshot)  →  Platform.present/6

    * UI tap (`HomeScreen.Delivery`, `NativeWorkspaceOpen`): `start_file_action/3`
      exports, the `:delivery_export` reply continues into `present/6`.
    * Agent tool (`android_open_file` / `android_share_file`):
      `start_approval_exports/2` exports at approval time and stores the
      snapshot in `Handbeam.ExportSnapshot.Binding`; `HandbeamProbe.AndroidIntent`
      later builds the present step with `Platform.present_request/6` from
      that snapshot.

  HomeScreen routes taps; this module owns copy and request construction.
  Requests are tracked in `HandbeamProbe.PendingRequests` through
  `HandbeamProbe.HomeScreen.Requests` (composer scope, 20 s deadline).
  """

  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI

  alias Handbeam.Android.{Intent, Url}
  alias Handbeam.ExportSnapshot.Binding
  alias Handbeam.Security.PathValidator
  alias Handbeam.TranscriptEntry
  alias HandbeamProbe.Bridge.{Inbound, Payload}
  alias HandbeamProbe.HomeScreen.{Notice, Requests}
  alias HandbeamProbe.{NativeComposer, Platform}

  @delivery_kinds [
    :approval_export,
    :delivery_export,
    :open_url,
    :open_snapshot,
    :share_snapshot,
    :share_text
  ]

  def delivery_kinds, do: @delivery_kinds

  def render_entries(assigns) do
    [
      text(gettext("Attachments"), text_size: 16, padding_top: 16),
      text(
        gettext(
          "Pick up to 4 photos from the gallery and add them to the current draft. Nothing is sent to a model until you tap send; only then can a cloud model receive them."
        ),
        text_size: 12,
        padding_top: 8,
        padding_bottom: 8
      ),
      button(gettext("Choose photos"), {:platform, :begin, :pick_photos}, fill_width: true),
      text(gettext("Open a web page (system browser)"), text_size: 16, padding_top: 20),
      text(
        gettext(
          "View pages, documents, orders, or login screens the Agent found in the system browser. This is not the Agent WebView in the conversation; for in-app viewing ask the Agent to use the browser tool."
        ),
        text_size: 12,
        padding_top: 8,
        padding_bottom: 8
      ),
      node(:text_field,
        id: "open-url-draft",
        value: Map.get(assigns, :open_url_draft, ""),
        placeholder: "https://…",
        background: color(:card),
        plain: true,
        multiline: false,
        fill_width: true,
        padding: 8,
        on_change: {self(), :open_url_draft}
      ),
      button(gettext("Open in system browser"), {:delivery, :open_url}, fill_width: true),
      text(gettext("Share or open an artifact file"), text_size: 16, padding_top: 20),
      text(
        gettext(
          "Enter a path relative to the current workspace. Sharing first pins an export copy and hands it to apps such as WeChat, mail, or cloud storage; opening uses the system PDF/image/text/archive app. Arbitrary local paths are never handed to other apps."
        ),
        text_size: 12,
        padding_top: 8,
        padding_bottom: 8
      ),
      node(:text_field,
        id: "artifact-path",
        value: Map.get(assigns, :artifact_path, ""),
        placeholder: gettext("e.g. reports/summary.pdf"),
        background: color(:card),
        plain: true,
        multiline: false,
        fill_width: true,
        padding: 8,
        on_change: {self(), :artifact_path}
      ),
      button(gettext("Open with a system app"), {:delivery, :open_file}, fill_width: true),
      button(gettext("Share to another app"), {:delivery, :share_file}, fill_width: true)
    ]
  end

  def outcome_notice("ui_presented"), do: Intent.format_outcome("ui_presented")
  def outcome_notice("chooser_presented"), do: Intent.format_outcome("chooser_presented")
  def outcome_notice(other), do: Intent.format_outcome(to_string(other || "outcome_unknown"))

  def start_open_url(socket, url) do
    case Url.parse(url) do
      {:ok, parsed} ->
        request_id = Ecto.UUID.generate()
        generation = Requests.composer_generation(socket)

        case Platform.open_url(self(), request_id, generation, parsed) do
          {:ok, _} ->
            track(socket, request_id, :open_url, %{url: parsed})

          {:error, reason} ->
            assign_error(socket, reason)
        end

      {:error, reason} ->
        assign_error(socket, reason)
    end
  end

  def start_share_text(socket, text) do
    request_id = Ecto.UUID.generate()
    generation = Requests.composer_generation(socket)

    case Platform.share_text(self(), request_id, generation, text) do
      {:ok, _} ->
        track(socket, request_id, :share_text, %{})

      {:error, reason} ->
        assign_error(socket, reason)
    end
  end

  @doc """
  Export step of the artifact sequence for a user tap. `spec` is the
  `NativeWorkspaceOpen.spec/4` map (timeline / tree target) or a bare
  workspace-relative path typed on the delivery page.
  """
  def start_file_action(socket, kind, spec)
      when kind in [:open_file, :share_file] and is_map(spec) do
    workspace = socket.assigns.workspace
    chat = socket.assigns[:chat]
    workspace_id = Map.get(spec, :workspace_id)
    conversation_id = Map.get(spec, :conversation_id)

    cond do
      not is_binary(workspace_id) or workspace_id != workspace["id"] ->
        assign_error(socket, :stale_workspace)

      Map.get(spec, :source) == :timeline and
          not match?(%{conversation: %{"id" => ^conversation_id}}, chat) ->
        assign_error(socket, :stale_conversation)

      true ->
        start_file_action(socket, kind, Map.get(spec, :relative_path))
    end
  end

  def start_file_action(socket, kind, relative_path) when kind in [:open_file, :share_file] do
    workspace = socket.assigns.workspace["path"]
    relative = String.trim(relative_path || "")
    request_id = Ecto.UUID.generate()
    generation = Requests.composer_generation(socket)

    # `Platform.export_file/5` runs `Handbeam.ExportSnapshot.authorize/2` once and
    # returns its `{:error, reason}` unchanged; do not authorize again here.
    case Platform.export_file(self(), request_id, generation, workspace, relative) do
      {:ok, _} ->
        track(socket, request_id, :delivery_export, %{next: kind, relative_path: relative})

      {:error, reason} ->
        assign_error(socket, reason)
    end
  end

  @doc """
  Export step of the artifact sequence for the Agent tool path: pin one
  snapshot per pending `android_open_file` / `android_share_file` request so
  approval never reads a source file that is rewritten afterwards.
  """
  def start_approval_exports(socket, chat) do
    workspace = socket.assigns.workspace["path"]
    conversation_id = chat.conversation["id"]
    seq = chat.approval_seq

    chat.pending_approval
    |> requests()
    |> Enum.filter(&file_tool?/1)
    |> Enum.reduce(socket, fn req, acc ->
      tool_call_id = req["tool_call_id"]
      key = export_key(conversation_id, seq, tool_call_id)
      inflight = acc.assigns[:approval_export_inflight] || MapSet.new()
      snapshots = acc.assigns[:approval_snapshots] || %{}

      cond do
        not is_binary(tool_call_id) ->
          acc

        MapSet.member?(inflight, key) ->
          acc

        Map.has_key?(snapshots, tool_call_id) ->
          acc

        true ->
          args = req["arguments"] || %{}
          path = args["path"]
          request_id = Ecto.UUID.generate()
          generation = Requests.composer_generation(acc)

          case Platform.export_file(self(), request_id, generation, workspace, path || "") do
            {:ok, _} ->
              acc
              |> assign_socket(approval_export_inflight: MapSet.put(inflight, key))
              |> track(request_id, :approval_export, %{
                tool_call_id: tool_call_id,
                conversation_id: conversation_id,
                approval_seq: seq,
                workspace_path: workspace,
                relative_path: path,
                action: file_action(req["tool_name"])
              })

            {:error, reason} ->
              assign_error(acc, reason)
          end
      end
    end)
  end

  def export_key(conversation_id, seq, tool_call_id),
    do: {conversation_id, seq, tool_call_id}

  def current_export_target?(socket, ctx) when is_map(ctx) do
    chat = socket.assigns[:chat]
    workspace = socket.assigns[:workspace]["path"]

    match?(%{conversation: %{"id" => _}}, chat) and
      chat.conversation["id"] == ctx[:conversation_id] and
      chat.approval_seq == ctx[:approval_seq] and
      same_workspace?(workspace, ctx[:workspace_path])
  end

  def current_export_target?(_, _), do: false

  @doc """
  Apply the reply of a tracked delivery request. `result` is an
  `Inbound.body/0` (or `{:error, :timeout}` from the deadline).
  """
  def handle_result(socket, ctx, result) do
    case ctx.kind do
      :approval_export ->
        bind_approval(socket, ctx, result)

      :delivery_export ->
        continue_delivery(socket, ctx, result)

      # The deadline is ours, not a host outcome: say so instead of formatting
      # an unknown outcome string.
      kind
      when kind in [:open_url, :open_snapshot, :share_snapshot, :share_text] and
             result == {:error, :timeout} ->
        assign_error(socket, :timeout)

      kind when kind in [:open_url, :open_snapshot, :share_snapshot, :share_text] ->
        assign_notice(socket, outcome_notice(Inbound.outcome(result)))

      _ ->
        socket
    end
  end

  def cleanup_bindings(socket, mode \\ :pending_only)

  def cleanup_bindings(socket, mode) when mode in [:pending_only, :force] do
    pending? =
      match?(%{pending_approval: pending} when not is_nil(pending), socket.assigns[:chat])

    if mode == :force or pending? do
      drop_bindings(socket)
    else
      socket
    end
  end

  def timeline_target(entry, workspace \\ nil)

  def timeline_target(entry, workspace) when is_map(entry) do
    name = TranscriptEntry.tool_name(entry) || ""
    input = TranscriptEntry.input(entry)
    details = entry["details"] || %{}
    workspace = if is_binary(workspace), do: workspace, else: entry["workspace_path"]

    cond do
      name == "android_open_url" or name == "browser" ->
        url = Enum.find_value([input, details], & &1["url"])
        if is_binary(url), do: {:url, url}, else: nil

      name in ["write", "edit", "android_open_file", "android_share_file"] ->
        path =
          Payload.first(input, ["path", "file_path"]) ||
            Payload.first(details, ["file_path", "relative_path"])

        case workspace_file_target(path, workspace) do
          {:ok, rel} -> {:file, rel}
          _ -> nil
        end

      true ->
        nil
    end
  end

  def timeline_target(_, _), do: nil

  def workspace_file_target(path, workspace)
      when is_binary(path) and path != "" and is_binary(workspace) and workspace != "" do
    abs =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(Path.join(workspace, path))
      end

    ws = Path.expand(workspace)

    with :ok <- PathValidator.validate_within_workspace(abs, ws) do
      rel = Path.relative_to(abs, ws)
      if rel == abs or rel == "", do: :error, else: {:ok, rel}
    end
  end

  def workspace_file_target(_, _), do: :error

  defp bind_approval(socket, ctx, {:ok, doc}) when is_map(doc) do
    socket = clear_inflight(socket, ctx)
    snap = Inbound.snapshot(doc)
    snapshots = socket.assigns[:approval_snapshots] || %{}

    cond do
      not current_export_target?(socket, ctx) ->
        socket

      Map.has_key?(snapshots, ctx.tool_call_id) ->
        socket

      is_binary(snap.snapshot_id) and is_binary(ctx.tool_call_id) ->
        meta = %{
          snapshot_id: snap.snapshot_id,
          owner_request_id: snap.owner_request_id || ctx.request_id,
          relative_path: ctx[:relative_path] || snap.relative_path,
          workspace_path: ctx[:workspace_path],
          action: ctx[:action],
          display_name: snap.display_name,
          size_bytes: snap.size_bytes
        }

        _ = Binding.put(ctx.conversation_id, ctx.tool_call_id, meta)

        socket
        |> assign_socket(approval_snapshots: Map.put(snapshots, ctx.tool_call_id, meta))
        |> clear_error()

      true ->
        assign_error(socket, :file_unavailable)
    end
  end

  defp bind_approval(socket, ctx, {:error, reason}) do
    socket
    |> clear_inflight(ctx)
    |> assign_error(reason)
  end

  defp bind_approval(socket, ctx, :cancelled), do: clear_inflight(socket, ctx)

  defp bind_approval(socket, ctx, _),
    do: socket |> clear_inflight(ctx) |> assign_error(:file_unavailable)

  # Present step of the artifact sequence after the UI export reply.
  defp continue_delivery(socket, ctx, {:ok, doc}) when is_map(doc) do
    snap = Inbound.snapshot(doc)
    owner = snap.owner_request_id || ctx.request_id
    request_id = Ecto.UUID.generate()
    generation = Requests.composer_generation(socket)
    kind = if ctx.next == :share_file, do: :share_snapshot, else: :open_snapshot

    case Platform.present(ctx.next, self(), request_id, generation, snap.snapshot_id, owner) do
      {:ok, _} -> track(socket, request_id, kind, %{})
      {:error, reason} -> assign_error(socket, reason)
    end
  end

  defp continue_delivery(socket, _ctx, {:error, reason}), do: assign_error(socket, reason)
  defp continue_delivery(socket, _ctx, :cancelled), do: socket
  defp continue_delivery(socket, _ctx, _), do: assign_error(socket, :file_unavailable)

  defp track(socket, request_id, kind, extra) do
    ctx = Map.merge(NativeComposer.context(socket), extra)

    socket
    |> Requests.track(request_id, kind, ctx)
    |> clear_error()
  end

  defp requests(nil), do: []
  defp requests(pending), do: pending["action_requests"] || []

  defp file_tool?(req), do: Handbeam.Android.Tools.file_action?(req["tool_name"] || "")

  defp file_action("android_share_file"), do: :share_file
  defp file_action(_), do: :open_file

  defp same_workspace?(a, b) when is_binary(a) and is_binary(b),
    do: Path.expand(a) == Path.expand(b)

  defp same_workspace?(_, _), do: false

  defp clear_inflight(socket, ctx) do
    key = export_key(ctx[:conversation_id], ctx[:approval_seq], ctx[:tool_call_id])
    inflight = MapSet.delete(socket.assigns[:approval_export_inflight] || MapSet.new(), key)
    assign_socket(socket, approval_export_inflight: inflight)
  end

  defp drop_bindings(socket) do
    case socket.assigns[:chat] do
      %{conversation: %{"id" => id}} -> Binding.clear_conversation(id)
      _ -> :ok
    end

    generation = Requests.composer_generation(socket)

    socket.assigns
    |> Map.get(:approval_snapshots, %{})
    |> Enum.each(fn {_call_id, snap} ->
      if is_binary(snap.owner_request_id) and is_binary(snap.snapshot_id) do
        _ =
          Platform.cleanup_snapshot(
            self(),
            Ecto.UUID.generate(),
            generation,
            snap.snapshot_id,
            snap.owner_request_id
          )
      end
    end)

    assign_socket(socket,
      approval_snapshots: %{},
      approval_export_inflight: MapSet.new()
    )
  end

  defp assign_error(socket, reason), do: Notice.put_error(socket, human_error(reason))

  defp assign_notice(socket, text), do: Notice.put_info(socket, text)

  defp clear_error(socket),
    do: Notice.put(socket, Notice.clear_kind(socket.assigns[:notice], :error))

  defp assign_socket(%Mob.Socket{} = socket, keywords) do
    Enum.reduce(keywords, socket, fn {key, value}, acc ->
      Mob.Socket.assign(acc, key, value)
    end)
  end

  defp assign_socket(%{assigns: assigns} = socket, keywords) do
    %{
      socket
      | assigns:
          Enum.reduce(keywords, assigns, fn {key, value}, acc -> Map.put(acc, key, value) end)
    }
  end

  @doc "User-facing text for a delivery failure. Never raises on tuple reasons."
  def human_error(:empty), do: gettext("There is no text to share.")
  def human_error(:too_long), do: gettext("The text is too long to share.")

  def human_error(:invalid_url),
    do: gettext("Only http or https URLs are supported; file and script links cannot be opened.")

  def human_error(:userinfo), do: gettext("The URL must not contain a username or password.")
  def human_error(:invalid_path), do: gettext("Enter a path relative to the current workspace.")
  def human_error(:too_large), do: gettext("The file exceeds the export size limit.")

  def human_error(:unavailable),
    do: gettext("The system UI cannot be opened in this environment.")

  def human_error(:stale_workspace), do: gettext("This file is not in the current workspace.")

  def human_error(:stale_conversation),
    do: gettext("This message is no longer in the open conversation.")

  def human_error(:timeout),
    do: gettext("The system operation did not answer in time and was cancelled.")

  def human_error(reason) when is_binary(reason), do: Intent.format_outcome(reason)
  def human_error(reason) when is_atom(reason), do: Intent.format_outcome(Atom.to_string(reason))
  def human_error(reason), do: Intent.format_outcome(inspect(reason))
end
