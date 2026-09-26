defmodule HandbeamWeb.WorkspaceLive.MessageSubmission do
  @moduledoc false

  use Gettext, backend: HandbeamWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3, stream: 4]

  alias HandbeamWeb.WorkspaceLive.Composer
  alias HandbeamWeb.WorkspaceLive.ConversationState
  alias HandbeamWeb.WorkspaceLive.ConversationSwitching
  alias HandbeamWeb.WorkspaceLive.ModelSelection
  alias HandbeamWeb.WorkspaceLive.RuntimeProjection

  require Logger

  def send_message(socket, params) do
    message = String.trim(params["message"] || "")
    socket = ModelSelection.apply_submitted(socket, params)
    {socket, message} = ModelSelection.apply_command(socket, message)
    socket = assign(socket, :composer_error, nil)

    if dm = subagent_dm(socket, message) do
      send_subagent_dm(socket, dm)
    else
      send_conversation_message(socket, message)
    end
  end

  def steer_message(socket, params) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    socket =
      socket
      |> ModelSelection.apply_submitted(params)
      |> assign(:composer_error, nil)

    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      send_or_queue_current(socket, message, :steer)
    else
      {:noreply, socket}
    end
  end

  def queue_message(socket, params) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    socket =
      socket
      |> ModelSelection.apply_submitted(params)
      |> assign(:composer_error, nil)

    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      send_or_queue_current(socket, message, :follow_up)
    else
      {:noreply, socket}
    end
  end

  def cancel_pending(socket, id) do
    conv_id = socket.assigns.current_conversation_id
    item = Map.get(socket.assigns.pending_messages, id)

    case Handbeam.Agent.Coordinator.delete_pending_message(conv_id, id) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           :pending_messages,
           Handbeam.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> restore_pending_draft(item)
         |> ConversationState.sync_conv_state(
           Keyword.merge(ModelSelection.state_opts(), reload?: true)
         )
         |> assign(:composer_error, nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(
           :pending_messages,
           Handbeam.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> ConversationState.sync_conv_state(
           Keyword.merge(ModelSelection.state_opts(), reload?: true)
         )
         |> assign(:composer_error, gettext("Already inserted; cannot undo."))}

      {:error, _reason} ->
        {:noreply, assign(socket, :composer_error, gettext("Could not undo that message."))}
    end
  end

  def resend_pending(socket, id) do
    item = Map.get(socket.assigns.pending_messages, id)

    cond do
      is_nil(item) or item[:status] != :undelivered -> {:noreply, socket}
      true -> resend_pending_item(socket, id, item)
    end
  end

  def stop(socket) do
    conv_id = socket.assigns.current_conversation_id

    result =
      if is_binary(conv_id) do
        Handbeam.Agent.Coordinator.cancel(conv_id)
      else
        {:error, :not_running}
      end

    case result do
      :ok ->
        {:noreply, RuntimeProjection.mark_cancelled(socket)}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] stop_run could not cancel run: #{inspect(reason)}")
        {:noreply, RuntimeProjection.mark_cancelled(socket)}
    end
  end

  def start_free_chat_run(socket, conv_id, content, run_opts) do
    if socket.assigns.current_conversation_id == conv_id do
      start_agent_run_now(socket, conv_id, content, run_opts)
    else
      {:noreply, socket}
    end
  end

  defp persist_timeline(socket, entry, opts) do
    socket = RuntimeProjection.timeline_insert(socket, entry)

    if Keyword.get(opts, :persist?, true),
      do: ConversationState.sync_conv_to(socket),
      else: socket
  end

  defp tools_for(socket) do
    if ConversationState.free_chat?(socket),
      do: Handbeam.Agent.free_chat_tools(),
      else: Handbeam.Agent.default_tools()
  end

  def send_conversation_message(socket, message) do
    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      running_for_current? =
        ConversationState.running_for_current_conversation?(socket) or
          not is_nil(socket.assigns.pending_approval)

      socket = if running_for_current?, do: socket, else: ensure_current_conversation(socket)

      case prepare_outbound_message(socket, message) do
        {:ok, socket, content, attachments} ->
          conv_id = socket.assigns.current_conversation_id

          if running_for_current? do
            queue_running_agent_message(
              socket,
              conv_id,
              content,
              message,
              attachments,
              :steer
            )
          else
            start_new_agent_run(socket, conv_id, content, message, attachments)
          end

        {:error, socket} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def subagent_dm(socket, message) do
    with conv_id when is_binary(conv_id) <- socket.assigns.current_conversation_id,
         [] <- socket.assigns.pending_attachments,
         false <- has_upload_entries?(socket),
         [_, ref, text] <- Regex.run(~r/\A@([\w.-]+)\s+(\S.*)\z/s, message),
         {:ok, children} <- Handbeam.Agent.Delegation.status(conv_id, :list),
         true <- Enum.any?(children, &(ref in [&1.child_conversation_id, &1.subagent_type])) do
      %{conversation_id: conv_id, ref: ref, text: text}
    else
      _ -> nil
    end
  end

  def send_subagent_dm(socket, %{conversation_id: conv_id, ref: ref, text: text}) do
    case Handbeam.Agent.Delegation.message(conv_id, ref, text, source: :web) do
      {:ok, %{delivery: delivery}} ->
        note =
          if delivery == :steer,
            do: gettext("Sent to subagent %{ref}.", ref: ref),
            else: gettext("Subagent %{ref} is answering a follow-up.", ref: ref)

        {:noreply,
         socket
         |> assign(:input_value, "")
         |> put_flash(:info, note)
         |> push_event("user-message-sent", %{})}

      {:error, reason} ->
        reason = if is_binary(reason), do: reason, else: inspect(reason)
        {:noreply, assign(socket, :composer_error, reason)}
    end
  end

  def send_or_queue_current(socket, message, deliver_as) do
    running_for_current? =
      ConversationState.running_for_current_conversation?(socket) or
        not is_nil(socket.assigns.pending_approval)

    socket = if running_for_current?, do: socket, else: ensure_current_conversation(socket)

    case prepare_outbound_message(socket, message) do
      {:ok, socket, content, attachments} ->
        conv_id = socket.assigns.current_conversation_id

        if running_for_current? do
          queue_running_agent_message(
            socket,
            conv_id,
            content,
            message,
            attachments,
            deliver_as
          )
        else
          start_new_agent_run(socket, conv_id, content, message, attachments)
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def restore_pending_draft(socket, item) when is_map(item) do
    Composer.restore_draft(socket, item)
  end

  def restore_pending_draft(socket, _), do: socket

  def resend_pending_item(socket, id, item) do
    content_text = if is_binary(item[:content]), do: item[:content], else: ""
    attachments = List.wrap(item[:attachments])
    conv_id = socket.assigns.current_conversation_id

    if String.trim(content_text) == "" and attachments == [] do
      {:noreply, socket}
    else
      socket =
        assign_pending_messages(
          socket,
          Handbeam.Agent.PendingMessages.put_status(
            socket.assigns.pending_messages,
            id,
            :resending
          )
        )

      workspace_path = ConversationState.current_workspace_path(socket)

      case Handbeam.Attachments.MessageBuilder.build(
             content_text,
             attachments,
             Composer.build_opts(socket, workspace_path)
           ) do
        {:ok, content, persistable} ->
          msg_id = RuntimeProjection.unique_id("msg-user")
          content = put_inbound_message_id(content, msg_id)
          deliver_as = item[:deliver_as] || :steer

          case add_message_to_current_conversation(socket, conv_id, content,
                 deliver_as: deliver_as,
                 message_id: msg_id,
                 attachments: persistable
               ) do
            {:ok, ack} ->
              finish_resend_pending(
                socket,
                id,
                msg_id,
                content_text,
                persistable,
                ack,
                deliver_as
              )

            {:error, reason} ->
              {:noreply,
               socket
               |> assign_pending_messages(
                 Handbeam.Agent.PendingMessages.put_status(
                   socket.assigns.pending_messages,
                   id,
                   :undelivered
                 )
               )
               |> assign(:composer_error, resend_error(reason))}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> assign_pending_messages(
             Handbeam.Agent.PendingMessages.put_status(
               socket.assigns.pending_messages,
               id,
               :undelivered
             )
           )
           |> assign(:composer_error, outbound_error(reason))}
      end
    end
  end

  def finish_resend_pending(socket, old_id, msg_id, content_text, attachments, ack, deliver_as) do
    conv_id = socket.assigns.current_conversation_id
    draft = socket.assigns.input_value
    composer_atts = socket.assigns.pending_attachments

    delete_ok? =
      case drop_transcript_entry(conv_id, old_id) do
        :ok -> true
        {:ok, _} -> true
        _ -> false
      end

    pending =
      socket.assigns.pending_messages
      |> Handbeam.Agent.PendingMessages.drop(old_id)

    pending =
      if ack[:action] == :enqueued do
        Handbeam.Agent.PendingMessages.put_queued(pending, msg_id, deliver_as, %{
          content: content_text,
          attachments: attachments
        })
      else
        pending
      end

    socket =
      socket
      |> assign_pending_messages(pending)
      |> ConversationState.sync_conv_state(reload?: true)
      |> assign(:input_value, draft)
      |> assign(:pending_attachments, composer_atts)
      |> assign(
        :composer_error,
        if(delete_ok?,
          do: nil,
          else: gettext("Resent, but the previous copy could not be removed from history.")
        )
      )

    socket =
      if ack[:action] == :started do
        socket
        |> assign(:running, true)
        |> assign(:running_conversation_id, conv_id)
      else
        socket
      end

    {:noreply, socket}
  end

  def assign_pending_messages(socket, pending) do
    Composer.assign_pending(socket, pending)
  end

  def drop_transcript_entry(conversation_id, id),
    do: Composer.drop_transcript_entry(conversation_id, id)

  def put_inbound_message_id(content, id), do: Composer.put_message_id(content, id)

  def queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as) do
    msg_id = RuntimeProjection.unique_id("msg-user")
    content = put_inbound_message_id(content, msg_id)

    case add_message_to_current_conversation(socket, conv_id, content,
           deliver_as: deliver_as,
           message_id: msg_id,
           attachments: attachments
         ) do
      {:ok, %{action: :enqueued}} ->
        pending =
          Handbeam.Agent.PendingMessages.put_queued(
            socket.assigns.pending_messages,
            msg_id,
            deliver_as,
            %{content: message, attachments: attachments}
          )

        socket =
          socket
          |> assign(:input_value, "")
          |> append_user_message(message, attachments, msg_id)
          |> assign(:pending_attachments, [])
          |> assign(:pending_messages, pending)
          |> push_event("user-message-sent", %{})

        {:noreply, socket}

      {:ok, %{action: :started}} ->
        {:noreply,
         socket
         |> assign(:input_value, "")
         |> append_user_message(message, attachments, msg_id)
         |> assign(:pending_attachments, [])
         |> assign(:running, true)
         |> assign(:running_conversation_id, conv_id)
         |> push_event("user-message-sent", %{})}

      {:error, :queue_full} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: :queue_full")
        {:noreply, mark_stale_running_message_rejected(socket)}

      {:error, :sealed} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: :sealed")
        {:noreply, mark_stale_running_message_rejected(socket)}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: #{inspect(reason)}")
        {:noreply, mark_stale_running_message_rejected(socket)}
    end
  end

  def add_message_to_current_conversation(socket, conv_id, content, opts) do
    {selected_model, selected_reasoning_level} =
      ModelSelection.effective_model_and_reasoning(socket)

    workspace_path = ConversationState.current_workspace_path(socket)

    with {:ok, provider_config, model_id} <-
           ModelSelection.resolve_selected_model(workspace_path, selected_model) do
      model_entry =
        ModelSelection.model_entry_for(selected_model, socket.assigns.available_models)

      provider_config =
        Handbeam.Agent.Reasoning.apply_provider_options(
          provider_config,
          model_entry,
          selected_reasoning_level
        )

      msg_id = Keyword.get(opts, :message_id)

      om_opts = ModelSelection.om_from_effective(socket.assigns.effective_settings)

      Handbeam.Agent.Coordinator.add_message(
        conv_id,
        content,
        run_opts(socket,
          provider_config: provider_config,
          model: model_id,
          reasoning_level: selected_reasoning_level,
          workspace_path: workspace_path,
          deliver_as: Keyword.get(opts, :deliver_as, :steer),
          transcript_id: msg_id,
          message_id: msg_id,
          inbound_id: msg_id,
          attachments: Keyword.get(opts, :attachments, []),
          om: Keyword.get(om_opts, :om)
        )
      )
    end
  end

  def run_opts(socket, extra) do
    base =
      if ConversationState.free_chat?(socket) do
        [
          chat_scope: :free,
          tools: tools_for(socket),
          workspace_id: nil,
          workspace_path: nil,
          mcp: false,
          source: :live_view,
          streaming: true
        ]
      else
        [
          chat_scope: :workspace,
          tools: tools_for(socket),
          workspace_id: socket.assigns.current_workspace_id,
          workspace_path: ConversationState.current_workspace_path(socket),
          source: :live_view,
          streaming: true
        ]
      end

    Keyword.merge(base, extra)
  end

  def mark_stale_running_message_rejected(socket) do
    socket
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:stream_suppressed, false)
    |> assign(:tools_active, %{})
    |> ConversationState.sync_conv_state(reload?: true)
    |> RuntimeProjection.restore_active_session()
    |> assign(
      :composer_error,
      "The previous run is no longer accepting input. Send again to start a new run in this conversation."
    )
  end

  def start_new_agent_run(socket, conv_id, content, message, attachments) do
    {selected_model, selected_reasoning_level} =
      ModelSelection.effective_model_and_reasoning(socket)

    workspace_path = ConversationState.current_workspace_path(socket)

    case ModelSelection.resolve_selected_model(workspace_path, selected_model) do
      {:ok, provider_config, model_id} ->
        model_entry =
          ModelSelection.model_entry_for(selected_model, socket.assigns.available_models)

        provider_config =
          Handbeam.Agent.Reasoning.apply_provider_options(
            provider_config,
            model_entry,
            selected_reasoning_level
          )

        msg_id = RuntimeProjection.unique_id("msg-user")
        content = put_inbound_message_id(content, msg_id)

        socket =
          socket
          |> assign(:input_value, "")
          |> assign(:running, true)
          |> assign(:running_conversation_id, conv_id)
          |> assign(:stream_suppressed, false)
          |> assign(:tools_active, %{})
          |> assign(:timeline, socket.assigns.timeline)
          |> stream(:timeline, socket.assigns.timeline, reset: true)
          |> assign(:thinking_content, "")
          |> assign(:think_buffer, "")
          |> assign(:current_assistant_entry_id, nil)
          |> append_user_message(message, attachments, msg_id)
          |> assign(:pending_attachments, [])
          |> ConversationState.schedule_auto_title(message)
          |> RuntimeProjection.update_status(%{
            status: :running,
            input_tokens: 0,
            total_input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_write_tokens: 0,
            turns: 0
          })
          |> RuntimeProjection.subscribe_session()
          |> push_event("user-message-sent", %{})

        om_opts = ModelSelection.om_from_effective(socket.assigns.effective_settings)

        run_opts =
          run_opts(socket,
            provider_config: provider_config,
            model: model_id,
            reasoning_level: selected_reasoning_level,
            workspace_path: workspace_path,
            transcript_id: msg_id,
            message_id: msg_id,
            inbound_id: msg_id,
            attachments: attachments,
            om: Keyword.get(om_opts, :om)
          )

        if ConversationState.free_chat?(socket) do
          send(self(), {:start_free_chat_run, conv_id, content, run_opts})
          {:noreply, socket}
        else
          start_agent_run_now(socket, conv_id, content, run_opts)
        end

      {:error, reason} ->
        {:noreply, assign(socket, :composer_error, reason)}
    end
  end

  def start_agent_run_now(socket, conv_id, content, run_opts) do
    case Handbeam.Agent.Coordinator.add_message(conv_id, content, run_opts) do
      {:ok, _ack} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] Failed to start agent run: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:running, false)
         |> assign(:running_conversation_id, nil)
         |> assign(:stream_suppressed, true)
         |> assign(:composer_error, "Message not delivered: #{inspect(reason)}")}
    end
  end

  def ensure_current_conversation(socket) do
    socket
    |> ConversationSwitching.ensure_current_conversation(ModelSelection.state_opts())
    |> RuntimeProjection.subscribe_session()
  end

  def append_user_message(socket, message, attachments, id) do
    entry = %{
      "id" => id || RuntimeProjection.unique_id("msg-user"),
      "content_type" => "user_msg",
      "role" => "user",
      "content" => message,
      "attachments" => attachments
    }

    persist_timeline(socket, entry, persist?: false)
  end

  def prepare_outbound_message(socket, message) do
    Composer.prepare(socket, message, ConversationState.current_workspace_path(socket))
  end

  def has_upload_entries?(socket), do: Composer.has_upload_entries?(socket)
  def outbound_error(reason), do: Composer.outbound_error(reason)
  def resend_error(reason), do: Composer.resend_error(reason)
end
