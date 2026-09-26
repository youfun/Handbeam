defmodule HandbeamWeb.ThreadHandoff do
  @moduledoc "Read-only projection of persisted handoffs. Rendering never dispatches work."
  use HandbeamWeb, :html

  attr :entry, :map, required: true
  attr :conversation_id, :string, required: true
  attr :workspace_id, :string, required: true

  def card(assigns) do
    context = %{conversation_id: assigns.conversation_id, workspace_id: assigns.workspace_id}
    origin = assigns.entry["origin"] || %{}
    target_id = assigns.entry["target"] || origin["conversation_id"]

    target =
      case Handbeam.Threads.authorize(context, target_id) do
        {:ok, target} -> target
        _ -> nil
      end

    messages =
      if target do
        [assigns.conversation_id, target_id]
        |> Enum.flat_map(fn id ->
          case Handbeam.ConversationTranscriptStore.list(id) do
            {:ok, entries} ->
              Enum.filter(entries, fn e ->
                get_in(e, ["origin", "kind"]) == "thread" and
                  get_in(e, ["origin", "conversation_id"]) in [assigns.conversation_id, target_id] and
                  association(e) == association(assigns.entry)
              end)

            _ ->
              []
          end
        end)
        |> Enum.sort_by(&{get_in(&1, ["origin", "sent_at"]) || &1["created_at"] || "", &1["id"]})
        |> Enum.take(-20)
      else
        []
      end

    assigns =
      assigns
      |> assign(:target, target)
      |> assign(:messages, messages)
      |> assign(:handoff_id, association(assigns.entry))
      |> assign(:important, origin["important"] == true)

    ~H"""
    <section
      class="rounded-lg border border-base-300 bg-base-200/50 p-3 text-sm"
      data-thread-handoff={@handoff_id}
    >
      <div class="flex flex-wrap items-center gap-2 text-xs opacity-80">
        <span>↗ {if @important, do: "Thread result", else: "Thread handoff"}</span>
        <a
          :if={@target}
          class="underline font-medium"
          href={"/w/#{URI.encode_www_form(@workspace_id)}/c/#{URI.encode_www_form(@target["id"])}"}
        >
          {String.slice(@target["title"] || "Thread", 0, 200)}
        </a>
        <span :if={!@target}>Source unavailable</span>
        <span :if={@entry["delivery_status"]}>{@entry["delivery_status"]} · not completion</span>
      </div>
      <div :if={@important && @target} class="mt-2 break-words">
        <p class="whitespace-pre-wrap">{@entry["content"]}</p>
      </div>
      <details :if={@target && !@important} class="mt-2">
        <summary class="cursor-pointer">View exchange (read-only)</summary>
        <p class="mt-2 text-xs opacity-60">
          Latest 20 reports. Open the task thread to read all messages or give instructions.
        </p>
        <p :if={@messages == []} class="mt-2 whitespace-pre-wrap break-words">
          {@entry["content"] || "No confirmed delivery yet."}
        </p>
        <article :for={message <- @messages} class="mt-3 border-l-2 border-base-300 pl-3">
          <span class="text-xs opacity-60">{if get_in(message, ["origin", "conversation_id"]) ==
                                                 @conversation_id, do: "Sent", else: "Received"} · {message[
            "created_at"
          ]}</span>
          <p class="whitespace-pre-wrap break-words">{body(message)}</p>
        </article>
      </details>
    </section>
    """
  end

  defp body(message) do
    text = message["content"] || ""

    String.slice(text, 0, 2000) <>
      if(String.length(text) > 2000, do: "… (open thread for full message)", else: "")
  end

  def show?(entry, timeline) do
    origin = entry["origin"] || %{}
    peer = entry["target"] || origin["conversation_id"]
    handoff? = entry["content_type"] == "thread_handoff" or origin["kind"] == "thread"

    first =
      Enum.find(timeline, fn item ->
        (item["content_type"] == "thread_handoff" or get_in(item, ["origin", "kind"]) == "thread") and
          (item["target"] == peer or get_in(item, ["origin", "conversation_id"]) == peer) and
          association(item) == association(entry)
      end)

    handoff? and (origin["important"] == true or is_nil(first) or first["id"] == entry["id"])
  end

  # Older records have no task association: never guess one from the peer alone.
  defp association(entry) do
    entry["handoff_id"] || get_in(entry, ["origin", "handoff_id"]) ||
      get_in(entry, ["origin", "request_id"]) || entry["id"]
  end
end
