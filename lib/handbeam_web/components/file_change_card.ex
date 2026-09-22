defmodule HandbeamWeb.FileChangeCard do
  @moduledoc """
  Shared file-change card for chat and the Changes list.

  Callers own expand/collapse. This component only renders one recorded
  edit or write: label, path, line counts, and the diff when open.
  """

  use Phoenix.Component

  alias Handbeam.TranscriptEntry
  alias HandbeamWeb.ChangeHelper

  attr :entry, :map, required: true
  attr :open?, :boolean, default: false
  attr :id, :string, default: nil
  attr :toggle_event, :string, default: "toggle_file_change"
  attr :class, :string, default: nil
  attr :confirm_change_id, :string, default: nil
  attr :message, :map, default: nil

  def card(assigns) do
    change = ChangeHelper.change_from_entry(assigns.entry)
    lines = ChangeHelper.normalize_diff_lines(Map.get(change, "diff_lines")) || []
    entry_id = entry_id(assigns.entry)

    assigns =
      assigns
      |> assign(:change, change)
      |> assign(:lines, numbered_lines(lines))
      |> assign(:entry_id, entry_id)
      |> assign(:card_id, assigns.id || "file-change-#{entry_id}")
      |> assign(:label, label(assigns.entry, lines))
      |> assign(:path, display_path(change, assigns.entry))
      |> assign(:added, count(lines, :add))
      |> assign(:removed, count(lines, :remove))
      |> assign(:reversible?, reversible?(change))
      |> assign(
        :confirming?,
        assigns.confirm_change_id == Map.get(change, "change_id") or
          assigns.entry["revert_confirming"] == true
      )
      |> assign(:message, message_for(assigns.message, change))

    ~H"""
    <article id={@card_id} class={["file-change-card", @class, @open? && "open"]}>
      <button
        type="button"
        id={"#{@card_id}-toggle"}
        class="file-change-card-toggle"
        phx-click={@toggle_event}
        phx-value-id={@entry_id}
        aria-expanded={to_string(@open?)}
      >
        <span class="file-change-chevron" aria-hidden="true">{if @open?, do: "⌄", else: "›"}</span>
        <span class="file-change-label">{@label}</span>
        <span class="file-change-path truncate" title={@path}>{@path}</span>
        <span :if={@added > 0} class="file-change-count added">+{@added}</span>
        <span :if={@removed > 0} class="file-change-count removed">−{@removed}</span>
      </button>
      <div :if={@open?} id={"#{@card_id}-diff"} class="file-change-diff">
        <div class="file-change-actions">
          <span class="file-change-status">{@change["revert_status"] || "review-only"}</span>
          <button
            :if={@reversible?}
            type="button"
            id={"#{@card_id}-revert"}
            class="file-change-revert"
            phx-click="confirm_revert_change"
            phx-value-change_id={@change["change_id"]}
          >
            {Gettext.gettext(HandbeamWeb.Gettext, "Revert")}
          </button>
        </div>
        <p :if={not @reversible?} class="file-change-note">
          {Gettext.gettext(
            HandbeamWeb.Gettext,
            "This change is review-only and cannot be reverted from Handbeam."
          )}
        </p>
        <p :if={@message} class={["file-change-note", @message["status"]]}>{@message["message"]}</p>
        <div :if={@confirming?} id={"#{@card_id}-confirm"} class="file-change-confirm">
          <span>{Gettext.gettext(HandbeamWeb.Gettext, "Revert this recorded change?")}</span>
          <button
            type="button"
            phx-click="revert_change"
            phx-value-change_id={@change["change_id"]}
          >
            {Gettext.gettext(HandbeamWeb.Gettext, "Confirm revert")}
          </button>
          <button type="button" phx-click="cancel_revert_change">
            {Gettext.gettext(HandbeamWeb.Gettext, "Cancel")}
          </button>
        </div>
        <div :for={line <- @lines} class={["diff-line", "diff-#{line.type}"]}>
          <span class="diff-lineno">{line.number}</span>
          <span class="diff-op">{HandbeamWeb.WorkspaceHelper.diff_prefix(line.type)}</span>
          <span class="diff-text">{line.text}</span>
        </div>
      </div>
    </article>
    """
  end

  @doc "True when the entry records an edit or write with visible diff lines."
  def change_entry?(%{} = entry) do
    TranscriptEntry.tool_name(entry) in ["edit", "write"] and diff_lines(entry) != []
  end

  def change_entry?(_), do: false

  @doc "Latest recorded file changes, newest first. One card per tool entry."
  def changes(entries) when is_list(entries) do
    entries
    |> Enum.filter(&change_entry?/1)
    |> Enum.reverse()
  end

  def changes(_), do: []

  defp message_for(%{"change_id" => id} = message, %{"change_id" => id}), do: message
  defp message_for(%{"change_id" => id} = message, %{change_id: id}), do: message
  defp message_for(_message, _change), do: nil

  defp reversible?(change) do
    Map.get(change, "reversible") == true and
      Map.get(change, "revert_status") not in ["reverted", "conflict"] and
      is_binary(Map.get(change, "change_id"))
  end

  defp label(entry, lines) do
    created? = TranscriptEntry.tool_name(entry) == "write" and count(lines, :remove) == 0

    if created?,
      do: Gettext.gettext(HandbeamWeb.Gettext, "Created"),
      else: Gettext.gettext(HandbeamWeb.Gettext, "Edited")
  end

  defp display_path(change, entry) do
    path = Map.get(change, "file_path") || TranscriptEntry.input_summary(entry) || ""
    name = Path.basename(path)
    if name == "", do: path, else: name
  end

  defp diff_lines(entry) do
    entry
    |> ChangeHelper.change_from_entry()
    |> Map.get("diff_lines")
    |> ChangeHelper.normalize_diff_lines() || []
  end

  defp numbered_lines(lines) do
    {numbered, _old, _new} =
      Enum.reduce(lines, {[], 1, 1}, fn line, {acc, old, new} ->
        type = line["type"]

        {number, old, new} =
          case type do
            "del" -> {old, old + 1, new}
            "ins" -> {new, old, new + 1}
            "skip" -> {nil, old, new}
            _ -> {new, old + 1, new + 1}
          end

        {acc ++ [%{type: type, text: line["text"], number: number}], old, new}
      end)

    numbered
  end

  defp entry_id(%{"id" => id}) when is_binary(id), do: id
  defp entry_id(%{id: id}) when is_binary(id), do: id
  defp entry_id(entry), do: to_string(Map.get(entry, "id") || Map.get(entry, :id) || "change")

  defp count(lines, :add), do: Enum.count(lines, &(&1["type"] in ["ins", "add", "added", "+"]))

  defp count(lines, :remove),
    do: Enum.count(lines, &(&1["type"] in ["del", "remove", "removed", "delete", "-"]))
end
