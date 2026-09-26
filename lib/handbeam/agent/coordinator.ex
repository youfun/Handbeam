defmodule Handbeam.Agent.Coordinator do
  @moduledoc """
  Facade for agent run lifecycle operations.

  Entry points such as LiveView, CLI, webhook, MCP, or extension code should
  express intent here instead of directly starting `Handbeam.Agent.run/2`.
  """

  require Logger

  alias Handbeam.PubSub.Session

  @type source :: :live_view | :sns | :webhook | :cli | :mcp | atom()
  @type action :: :started | :enqueued
  @type ack :: %{action: action(), run_id: String.t() | nil, run_pid: pid() | nil}

  @required_opts [:model, :provider_config, :tools, :source]

  @spec add_message(String.t(), String.t() | Handbeam.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def add_message(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbeam.Agent.Message)) and
             is_list(opts) do
    {content, opts} = stamp_message_ids(content, opts)

    with :ok <- validate_conversation_access(conversation_id, opts),
         :ok <- validate_required_opts(opts),
         :ok <- validate_model_policy(opts),
         :ok <- validate_advisor_policy(opts),
         opts <- ensure_run_id(opts),
         {:ok, _pid} <- Session.start_or_get(session_id: conversation_id, model: opts[:model]) do
      case status(conversation_id) do
        {:ok, %{running?: true}} ->
          cond do
            present_task_instructions?(opts) ->
              {:error, :run_in_progress}

            true ->
              opts = Keyword.put_new(opts, :deliver_as, :steer)

              with {:ok, _entry} <-
                     Handbeam.Agent.TranscriptPersistence.append_inbound(
                       conversation_id,
                       content,
                       opts
                     ),
                   {:ok, ack} <- enqueue_candidate(conversation_id, content, opts) do
                maybe_resume_stall(conversation_id)
                {:ok, ack}
              end
          end

        {:ok, %{running?: false}} ->
          if Keyword.get(opts, :require_running?, false) do
            {:error, :no_active_run}
          else
            start_run(conversation_id, content, opts)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec start_run(String.t(), String.t() | Handbeam.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, :run_in_progress | term()}
  def start_run(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbeam.Agent.Message)) and
             is_list(opts) do
    with :ok <- validate_conversation_access(conversation_id, opts),
         :ok <- validate_required_opts(opts),
         :ok <- validate_model_policy(opts),
         :ok <- validate_advisor_policy(opts),
         opts <- ensure_run_id(opts),
         {:ok, _pid} <- Session.start_or_get(session_id: conversation_id, model: opts[:model]),
         {:ok, %{running?: false}} <- status(conversation_id),
         :ok <- persist_inbound_before_start(conversation_id, content, opts) do
      run_opts = agent_run_opts(conversation_id, opts)

      case Handbeam.Agent.Runner.start_run(conversation_id, content, run_opts) do
        {:ok, pid} ->
          runner_pid = wait_until_registered(conversation_id)

          {:ok,
           %{
             action: :started,
             run_id: Keyword.fetch!(run_opts, :run_id),
             run_pid: runner_pid || pid
           }}

        {:error, reason} ->
          normalize_start_run_error(reason)
      end
    else
      {:ok, %{running?: true}} -> {:error, :run_in_progress}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec enqueue_candidate(String.t(), String.t() | Handbeam.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def enqueue_candidate(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbeam.Agent.Message)) and
             is_list(opts) do
    {content, opts} = stamp_message_ids(content, opts)

    case Session.enqueue_candidate(conversation_id, content, opts) do
      :ok -> {:ok, %{action: :enqueued, run_id: nil, run_pid: nil}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(conversation_id) when is_binary(conversation_id) do
    case Handbeam.Agent.Runner.status(conversation_id) do
      {:ok, status} ->
        {:ok, status}

      {:error, :not_found} ->
        session_status(conversation_id)

      {:error, _reason} ->
        session_status(conversation_id)
    end
  end

  @spec cancel(String.t()) :: :ok | {:error, :not_running | term()}
  def cancel(conversation_id) when is_binary(conversation_id) do
    Handbeam.Agent.Runner.cancel(conversation_id)
  end

  @spec delete_pending_message(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_pending_message(conversation_id, message_id)
      when is_binary(conversation_id) and is_binary(message_id) do
    with {:ok, _info} <- Session.delete_pending_message(conversation_id, message_id) do
      Handbeam.ConversationTranscriptStore.delete(conversation_id, message_id)
    end
  end

  @spec resume(String.t(), [map()]) :: :ok | {:error, term()}
  def resume(conversation_id, decisions)
      when is_binary(conversation_id) and is_list(decisions) do
    if Handbeam.ConversationStore.internal?(conversation_id) do
      {:error, :internal_conversation}
    else
      Handbeam.Agent.Runner.resume(conversation_id, decisions)
    end
  end

  defp validate_required_opts(opts) do
    missing = Enum.reject(@required_opts, &Keyword.has_key?(opts, &1))

    missing =
      if free_chat?(opts) or present_workspace_path?(opts) do
        missing
      else
        [:workspace_path | missing]
      end

    if missing == [] do
      :ok
    else
      {:error, {:missing_opts, missing}}
    end
  end

  defp free_chat?(opts), do: Keyword.get(opts, :chat_scope) == :free

  defp present_workspace_path?(opts) do
    case Keyword.get(opts, :workspace_path) do
      path when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp validate_conversation_access(id, opts) do
    if Handbeam.ConversationStore.internal?(id) and
         not (opts[:delegated?] == true and is_pid(opts[:delegation_owner]) and
                opts[:delegation_owner] == Process.whereis(Handbeam.Agent.Delegation)) do
      {:error, :internal_conversation}
    else
      :ok
    end
  end

  defp validate_model_policy(opts) do
    cond do
      explicit_provider_with_raw_model?(opts) -> :ok
      free_chat?(opts) -> :ok
      true -> validate_workspace_model_policy(opts)
    end
  end

  defp explicit_provider_with_raw_model?(opts) do
    Keyword.has_key?(opts, :provider) and
      opts
      |> Keyword.fetch!(:model)
      |> String.contains?("/")
      |> Kernel.not()
  end

  defp validate_workspace_model_policy(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    model = Keyword.fetch!(opts, :model)

    if Handbeam.Agent.ModelConfig.model_allowed_for_workspace?(workspace_path, model) do
      validate_om_model_policy(opts)
    else
      {:error,
       Gettext.dgettext(
         HandbeamWeb.Gettext,
         "errors",
         "Model %{model} is not allowed in this workspace. Check Settings → Model / AI → Default model.",
         model: model
       )}
    end
  end

  defp validate_om_model_policy(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    om = Keyword.get(opts, :om, %{})

    with :ok <- memory_model_allowed(workspace_path, om[:observer_model], :observer),
         :ok <- memory_model_allowed(workspace_path, om[:reflector_model], :reflector) do
      :ok
    end
  end

  # A removed catalog entry is not a workspace restriction. "Unrestricted" and
  # an allowlist that simply does not name the model both mean "do not use it
  # for memory", so the chat model can still start. An explicit allowlist that
  # excludes a model still present in the catalog remains a hard error.
  defp memory_model_allowed(_workspace_path, model, _role)
       when model in [nil, ""],
       do: :ok

  defp memory_model_allowed(workspace_path, model, role) do
    cond do
      Handbeam.Agent.ModelConfig.model_allowed_for_workspace?(workspace_path, model) ->
        :ok

      Handbeam.Agent.ModelConfig.model_in_catalog?(model) ->
        {:error, memory_model_rejected(role, model)}

      true ->
        :ok
    end
  end

  defp memory_model_rejected(:observer, model) do
    Gettext.dgettext(
      HandbeamWeb.Gettext,
      "errors",
      "Observational Memory observer model (%{model}) is not allowed in this workspace. Check Settings → Model / AI → Observational Memory → Observer model.",
      model: model
    )
  end

  defp memory_model_rejected(:reflector, model) do
    Gettext.dgettext(
      HandbeamWeb.Gettext,
      "errors",
      "Observational Memory reflector model (%{model}) is not allowed in this workspace. Check Settings → Model / AI → Observational Memory → Reflector model.",
      model: model
    )
  end

  defp validate_advisor_policy(opts) do
    if free_chat?(opts) do
      :ok
    else
      {:ok, _pin} =
        Handbeam.Agent.Advisor.validate_start(Keyword.fetch!(opts, :workspace_path), opts)

      :ok
    end
  end

  defp maybe_resume_stall(conversation_id) do
    case status(conversation_id) do
      {:ok, %{running?: true, interrupt_type: :stall_check}} ->
        Handbeam.Agent.Runner.resume(conversation_id, %{"action" => "continue"})

      _ ->
        :ok
    end
  end

  defp agent_run_opts(conversation_id, opts) do
    opts =
      case Handbeam.ConversationStore.get_metadata(conversation_id) do
        {:ok, %{"collaboration" => %{"read_only" => true}}} ->
          Keyword.put(opts, :delegated_read_only, true)

        _ ->
          opts
      end

    opts
    |> Keyword.put(:session_id, conversation_id)
    |> Keyword.put(:conversation_id, conversation_id)
    |> ensure_run_id()
    |> put_transcript_history(conversation_id)
    |> put_working_directory()
    |> put_skills()
    |> put_advisor_pin()
  end

  defp put_working_directory(opts) do
    cond do
      free_chat?(opts) ->
        Keyword.delete(opts, :working_directory)

      true ->
        Keyword.put(opts, :working_directory, Keyword.fetch!(opts, :workspace_path))
    end
  end

  defp put_skills(opts) do
    if free_chat?(opts),
      do: Keyword.put(opts, :skills, false),
      else: Keyword.put(opts, :skills, true)
  end

  defp put_advisor_pin(opts) do
    if free_chat?(opts) do
      Keyword.put(opts, :advisor, Handbeam.Agent.Advisor.unavailable())
    else
      {:ok, pin} =
        Handbeam.Agent.Advisor.validate_start(Keyword.fetch!(opts, :workspace_path), opts)

      Keyword.put(opts, :advisor, pin)
    end
  end

  defp present_task_instructions?(opts) do
    case Keyword.get(opts, :task_instructions) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  defp persist_inbound_before_start(conversation_id, content, opts) do
    # Task instructions are persisted inside Runner.init after exclusive acceptance.
    if Keyword.get(opts, :persist_inbound?, true) and not present_task_instructions?(opts) do
      case Handbeam.Agent.TranscriptPersistence.append_inbound(
             conversation_id,
             content,
             Keyword.put(opts, :deliver_as, :new_run)
           ) do
        {:ok, _entry} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp normalize_start_run_error({:already_started, _pid}), do: {:error, :run_in_progress}

  defp normalize_start_run_error({:inbound_persist_failed, reason}),
    do: {:error, {:inbound_persist_failed, reason}}

  defp normalize_start_run_error({:shutdown, {:failed_to_start_child, _mod, reason}}),
    do: normalize_start_run_error(reason)

  defp normalize_start_run_error(reason), do: {:error, reason}

  defp ensure_run_id(opts), do: Keyword.put_new(opts, :run_id, Ecto.UUID.generate())

  defp stamp_message_ids(content, opts) do
    struct_id = message_id(content)
    opt_message_id = present_id(Keyword.get(opts, :message_id))
    opt_transcript_id = present_id(Keyword.get(opts, :transcript_id))

    canonical = opt_message_id || opt_transcript_id || struct_id || Ecto.UUID.generate()

    content =
      case content do
        %Handbeam.Agent.Message{} = message -> %{message | id: canonical}
        other -> other
      end

    inbound_id = present_id(Keyword.get(opts, :inbound_id)) || canonical

    opts =
      opts
      |> Keyword.put(:message_id, canonical)
      |> Keyword.put(:transcript_id, canonical)
      |> Keyword.put(:inbound_id, inbound_id)

    {content, opts}
  end

  defp present_id(id) when is_binary(id) and id != "", do: id
  defp present_id(_), do: nil

  defp message_id(%Handbeam.Agent.Message{id: id}) when is_binary(id) and id != "", do: id
  defp message_id(_), do: nil

  defp put_transcript_history(opts, conversation_id) do
    Keyword.put_new_lazy(opts, :history_messages, fn ->
      transcript_history_messages(
        conversation_id,
        Keyword.get(opts, :run_id),
        history_workspace_path(opts)
      )
    end)
  end

  defp history_workspace_path(opts) do
    if free_chat?(opts), do: nil, else: opts[:workspace_path]
  end

  defp transcript_history_messages(conversation_id, current_run_id, workspace_path) do
    case Handbeam.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(current_run_id && Map.get(&1, "run_id") == current_run_id))
        |> Enum.flat_map(
          &Handbeam.Attachments.History.to_messages(&1, workspace_path, conversation_id)
        )

      {:error, reason} ->
        Logger.warning(fn ->
          "[Coordinator] failed to load transcript history conversation=#{conversation_id} " <>
            "reason=#{inspect(reason)}"
        end)

        []
    end
  end

  defp session_status(conversation_id) do
    case Session.whereis(conversation_id) do
      nil ->
        {:error, :not_found}

      _pid ->
        %{meta: meta} = Session.snapshot(conversation_id)

        {:ok,
         %{
           conversation_id: conversation_id,
           running?: Map.get(meta, :running?, false),
           run_pid: Map.get(meta, :agent_pid),
           queue_pid: Map.get(meta, :queue_pid),
           status: Map.get(meta, :status)
         }}
    end
  end

  defp wait_until_registered(conversation_id, attempts \\ 20)

  defp wait_until_registered(_conversation_id, 0), do: nil

  defp wait_until_registered(conversation_id, attempts) do
    case Registry.lookup(Handbeam.AgentRunRegistry, conversation_id) do
      [{pid, _metadata}] ->
        pid

      _ ->
        Process.sleep(1)
        wait_until_registered(conversation_id, attempts - 1)
    end
  end
end
