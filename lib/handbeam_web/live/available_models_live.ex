defmodule HandbeamWeb.AvailableModelsLive do
  use HandbeamWeb, :live_view

  alias Handbeam.Agent.Auth.{Storage, Subscriptions, XaiOAuth}
  alias Handbeam.Agent.ModelConfig
  alias Handbeam.LlmDbDefaults

  # ── Lifecycle ──────────────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Handbeam.PubSub, "models:updated")

    ModelConfig.ensure_config()
    config = load_raw_config()
    providers = parse_providers(config)
    embedded = Map.get(session, "embedded") == "true"
    selected_id = if embedded, do: nil, else: Map.get(config, "defaultProvider", "")

    socket =
      socket
      |> assign(:page_title, gettext("设置 / 可用模型"))
      |> assign(:embedded, embedded)
      |> assign(:config, config)
      |> assign(:providers, providers)
      |> assign(:selected_provider_id, selected_id)
      |> assign(:selected_provider, find_provider(selected_id, providers))
      |> assign(:show_add_provider, false)
      |> assign(:show_edit_provider, false)
      |> assign(:show_add_model, false)
      |> assign(:show_delete_confirm, false)
      |> assign(:delete_target, nil)
      |> assign(:add_provider_form, reset_add_provider_form())
      |> assign(:edit_provider_form, %{})
      |> assign(:add_model_form, reset_add_model_form())
      |> assign(:form_error, nil)
      |> assign(:toast, nil)
      |> assign(:xai_oauth, nil)
      |> assign(:show_subscription_login, false)
      |> assign(:subscription_methods, Subscriptions.methods())

    {:ok, socket}
  end

  @impl true
  def handle_info({:models_updated}, socket) do
    config = load_raw_config()
    providers = parse_providers(config)
    selected_id = maybe_reselect(socket.assigns.selected_provider_id, providers)

    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:providers, providers)
     |> assign(:selected_provider_id, selected_id)
     |> assign(:selected_provider, find_provider(selected_id, providers))}
  end

  @impl true
  def handle_info(:clear_toast, socket) do
    {:noreply, assign(socket, :toast, nil)}
  end

  def handle_info(:poll_xai_oauth, socket) do
    {:noreply, poll_xai_oauth(socket)}
  end

  # ── xAI subscription OAuth ─────────────────────────────────────────────

  def handle_event("open_subscription_login", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_subscription_login, true)
     |> assign(:form_error, nil)}
  end

  def handle_event("close_subscription_login", _params, socket) do
    {:noreply, assign(socket, :show_subscription_login, false)}
  end

  def handle_event("start_subscription_oauth", %{"id" => provider_id}, socket) do
    {:noreply, start_subscription_oauth(socket, provider_id)}
  end

  def handle_event("cancel_xai_oauth", _params, socket) do
    {:noreply, assign(socket, :xai_oauth, nil)}
  end

  # ── Provider selection ─────────────────────────────────────────────────

  @impl true
  def handle_event("select_provider", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider_id, id)
     |> assign(:selected_provider, find_provider(id, socket.assigns.providers))}
  end

  def handle_event("clear_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider_id, nil)
     |> assign(:selected_provider, nil)}
  end

  # ── Default provider toggle ────────────────────────────────────────────

  @impl true
  def handle_event("toggle_default_provider", %{"id" => id, "value" => value}, socket) do
    if value == "true" do
      case ModelConfig.write_config(Map.put(socket.assigns.config, "defaultProvider", id)) do
        :ok ->
          toast = %{
            type: :success,
            message: gettext("默认供应商已更改"),
            id: System.unique_integer([:positive])
          }

          Process.send_after(self(), :clear_toast, 3000)
          {:noreply, assign(socket, :toast, toast)}

        {:error, reason} ->
          {:noreply, assign(socket, :form_error, reason)}
      end
    else
      # Cannot uncheck default — at least for now, require one default
      {:noreply, socket}
    end
  end

  # ── Add provider ───────────────────────────────────────────────────────

  @impl true
  def handle_event("open_add_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_provider, true)
     |> assign(:form_error, nil)
     |> assign(:add_provider_form, reset_add_provider_form())}
  end

  def handle_event("close_add_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_provider, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_add_provider", %{"add_provider" => params}, socket) do
    previous = socket.assigns.add_provider_form
    force? = provider_source_changed?(previous, params)

    form =
      previous
      |> Map.merge(params)
      |> hydrate_add_provider_form(force?)

    {:noreply, assign(socket, :add_provider_form, form)}
  end

  def handle_event("update_add_provider", _params, socket) do
    # Form change with partial params (e.g., only _target)
    {:noreply, socket}
  end

  def handle_event("submit_add_provider", %{"add_provider" => params}, socket) do
    params = Map.merge(socket.assigns.add_provider_form, params)
    provider_id = params["id"] |> to_string() |> String.trim()
    name = params["name"] |> to_string() |> String.trim()
    api = params["api"] |> to_string() |> String.trim()
    base_url = params["base_url"] |> to_string() |> String.trim()
    api_key = params["api_key"] |> to_string() |> String.trim()
    model_id = params["model_id"] |> to_string() |> String.trim()
    model_name = params["model_name"] |> to_string() |> String.trim()

    cond do
      provider_id == "" ->
        {:noreply, assign(socket, :form_error, gettext("Provider ID 不能为空"))}

      not String.match?(provider_id, ~r/^[a-z0-9_-]+$/) ->
        {:noreply, assign(socket, :form_error, gettext("Provider ID 只能包含小写字母、数字、横线和下划线"))}

      model_id == "" ->
        {:noreply, assign(socket, :form_error, gettext("需要至少一个模型"))}

      true ->
        model_cost = build_cost_map(params)

        provider_attrs = %{
          "provider" => runtime_provider(params, provider_id),
          "baseUrl" => base_url,
          "api" => api,
          "apiKey" => api_key,
          "name" => present_or(name, display_name(provider_id)),
          "models" => [
            %{
              "id" => model_id,
              "name" => present_or(model_name, model_id),
              "input" => ["text"],
              "contextWindow" => parse_int(params["context_window"], 128_000),
              "maxTokens" => parse_int(params["max_tokens"], 8192),
              "cost" => model_cost
            }
            |> maybe_drop_empty_cost()
          ]
        }

        case ModelConfig.add_provider(provider_id, provider_attrs) do
          :ok ->
            toast = %{
              type: :success,
              message: gettext("供应商已成功添加"),
              id: System.unique_integer([:positive])
            }

            Process.send_after(self(), :clear_toast, 3000)

            {:noreply,
             socket
             |> assign(:show_add_provider, false)
             |> assign(:form_error, nil)
             |> assign(:add_provider_form, reset_add_provider_form())
             |> assign(:toast, toast)}

          {:error, reason} ->
            {:noreply, assign(socket, :form_error, reason)}
        end
    end
  end

  def handle_event("submit_add_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  # ── Edit provider ──────────────────────────────────────────────────────

  @impl true
  def handle_event("open_edit_provider", %{"id" => id}, socket) do
    provider = find_provider(id, socket.assigns.providers)

    {:noreply,
     socket
     |> assign(:show_edit_provider, true)
     |> assign(:form_error, nil)
     |> assign(:edit_provider_form, %{
       "name" => provider.name,
       "api" => provider.api,
       "base_url" => provider.base_url,
       "api_key" => form_api_key(provider.api_key)
     })}
  end

  def handle_event("close_edit_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_provider, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_edit_provider", %{"edit_provider" => params}, socket) do
    form = Map.merge(socket.assigns.edit_provider_form, params)
    {:noreply, assign(socket, :edit_provider_form, form)}
  end

  def handle_event("update_edit_provider", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("submit_edit_provider", %{"edit_provider" => params}, socket) do
    provider_id = socket.assigns.selected_provider_id
    params = Map.merge(socket.assigns.edit_provider_form, params)

    attrs =
      %{
        "name" => params["name"],
        "api" => params["api"],
        "baseUrl" => params["base_url"]
      }
      |> maybe_put_api_key(params["api_key"])

    case ModelConfig.update_provider(provider_id, attrs) do
      :ok ->
        toast = %{
          type: :success,
          message: gettext("供应商已成功更新"),
          id: System.unique_integer([:positive])
        }

        Process.send_after(self(), :clear_toast, 3000)

        {:noreply,
         socket
         |> assign(:show_edit_provider, false)
         |> assign(:form_error, nil)
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply, assign(socket, :form_error, reason)}
    end
  end

  def handle_event("submit_edit_provider", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  # ── Delete provider / model ────────────────────────────────────────────

  @impl true
  def handle_event("confirm_delete_provider", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, true)
     |> assign(:delete_target, %{type: :provider, id: socket.assigns.selected_provider_id})}
  end

  def handle_event("confirm_delete_model", %{"id" => model_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, true)
     |> assign(:delete_target, %{
       type: :model,
       provider_id: socket.assigns.selected_provider_id,
       model_id: model_id
     })}
  end

  def handle_event("close_delete_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_confirm, false)
     |> assign(:delete_target, nil)}
  end

  def handle_event("execute_delete", _params, socket) do
    target = socket.assigns.delete_target

    result =
      case target do
        %{type: :provider, id: id} -> ModelConfig.remove_provider(id)
        %{type: :model, provider_id: pid, model_id: mid} -> ModelConfig.remove_model(pid, mid)
        _ -> {:error, "无效的删除目标"}
      end

    case result do
      :ok ->
        toast = %{
          type: :success,
          message: gettext("已成功删除"),
          id: System.unique_integer([:positive])
        }

        Process.send_after(self(), :clear_toast, 3000)

        {:noreply,
         socket
         |> assign(:show_delete_confirm, false)
         |> assign(:delete_target, nil)
         |> assign(:toast, toast)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_delete_confirm, false)
         |> assign(:delete_target, nil)
         |> assign(:form_error, reason)}
    end
  end

  # ── Add model ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_add_model", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_model, true)
     |> assign(:form_error, nil)
     |> assign(:add_model_form, reset_add_model_form())}
  end

  def handle_event("close_add_model", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_model, false)
     |> assign(:form_error, nil)}
  end

  def handle_event("update_add_model", %{"add_model" => params}, socket) do
    form = Map.merge(socket.assigns.add_model_form, params)
    {:noreply, assign(socket, :add_model_form, form)}
  end

  def handle_event("update_add_model", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("submit_add_model", %{"add_model" => params}, socket) do
    provider_id = socket.assigns.selected_provider_id

    model_id = params["id"] |> to_string() |> String.trim()
    model_name = params["name"] |> to_string() |> String.trim()
    type = params["type"] |> to_string() |> String.trim()

    if model_id == "" do
      {:noreply, assign(socket, :form_error, gettext("模型 ID 不能为空"))}
    else
      model_cost = build_cost_map(params)

      model_attrs =
        %{
          "name" => present_or(model_name, model_id),
          "input" => [type || "text"],
          "contextWindow" => parse_int(params["context_window"], 128_000),
          "maxTokens" => parse_int(params["max_tokens"], 8192),
          "cost" => model_cost
        }
        |> maybe_drop_empty_cost()

      case ModelConfig.add_model(provider_id, model_id, model_attrs) do
        :ok ->
          toast = %{
            type: :success,
            message: gettext("模型已成功添加"),
            id: System.unique_integer([:positive])
          }

          Process.send_after(self(), :clear_toast, 3000)

          {:noreply,
           socket
           |> assign(:show_add_model, false)
           |> assign(:form_error, nil)
           |> assign(:add_model_form, reset_add_model_form())
           |> assign(:toast, toast)}

        {:error, reason} ->
          {:noreply, assign(socket, :form_error, reason)}
      end
    end
  end

  def handle_event("submit_add_model", _params, socket) do
    {:noreply, assign(socket, :form_error, gettext("表单数据无效"))}
  end

  # ── Clear error ───────────────────────────────────────────────────────

  @impl true
  def handle_event("clear_error", _params, socket) do
    {:noreply, assign(socket, :form_error, nil)}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  def obscured_api_key(key) when is_binary(key) do
    cond do
      key == "" -> "—"
      String.starts_with?(key, "env:") -> "••••••••"
      String.length(key) > 12 -> String.slice(key, 0, 6) <> "..." <> String.slice(key, -4, 4)
      true -> String.slice(key, 0, 4) <> "..."
    end
  end

  def obscured_api_key(nil), do: "—"

  defp form_api_key("env:" <> _var), do: ""
  defp form_api_key(key) when is_binary(key), do: key
  defp form_api_key(_), do: ""

  defp maybe_put_api_key(attrs, api_key) do
    case api_key |> to_string() |> String.trim() do
      "" -> attrs
      key -> Map.put(attrs, "apiKey", key)
    end
  end

  def format_context(nil), do: "—"
  def format_context(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  def format_context(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  def format_context(n) when is_integer(n), do: Integer.to_string(n)

  def format_price(%{"input" => input, "output" => output})
      when is_number(input) and is_number(output) do
    "in #{format_price_number(input)} / out #{format_price_number(output)}"
  end

  def format_price(%{input: input, output: output}) when is_number(input) and is_number(output) do
    "in #{format_price_number(input)} / out #{format_price_number(output)}"
  end

  def format_price(_), do: "—"

  def delete_confirm_title(%{type: :provider}), do: gettext("删除供应商")
  def delete_confirm_title(%{type: :model}), do: gettext("删除模型")
  def delete_confirm_title(_), do: gettext("确认删除")

  def delete_confirm_message(%{type: :provider, id: id}, providers) do
    name =
      case Enum.find(providers, &(&1.id == id)) do
        nil -> id
        p -> p.name
      end

    gettext("确认删除供应商「%{name}」(ID: %{id})？这将同时删除其下所有模型。", name: name, id: id)
  end

  def delete_confirm_message(%{type: :model, model_id: mid}, _providers) do
    gettext("确认删除模型「%{id}」？", id: mid)
  end

  def delete_confirm_message(_, _), do: gettext("确认删除？")

  defp start_subscription_oauth(socket, provider_id) do
    with {:ok, method} <- Subscriptions.get(provider_id),
         :ok <- ensure_subscription_provider(method),
         {:ok, device} <- start_device_flow(method) do
      interval_ms = poll_interval_ms(device)
      Process.send_after(self(), :poll_xai_oauth, interval_ms)

      socket
      |> assign(:show_subscription_login, false)
      |> reload_providers()
      |> assign(:selected_provider_id, method.id)
      |> assign(
        :selected_provider,
        find_provider(method.id, parse_providers(load_raw_config()))
      )
      |> assign(:form_error, nil)
      |> assign(:xai_oauth, %{
        provider_id: method.id,
        login_label: method.login_label,
        device: device,
        verification_uri: XaiOAuth.browser_verification_uri(device),
        status: :waiting
      })
    else
      {:error, message} ->
        socket
        |> assign(:show_subscription_login, false)
        |> assign(:form_error, message)
    end
  end

  defp start_device_flow(%{id: "xai"}), do: XaiOAuth.start()

  defp start_device_flow(%{id: id}),
    do: {:error, "Subscription login for #{id} is not implemented yet"}

  defp poll_xai_oauth(%{assigns: %{xai_oauth: %{device: device} = oauth}} = socket) do
    case XaiOAuth.poll_once(device) do
      {:pending, updated} ->
        schedule_xai_poll(updated)

        assign(socket, :xai_oauth, %{
          oauth
          | device: updated,
            status: :waiting
        })

      {:slow_down, updated} ->
        schedule_xai_poll(updated)

        assign(socket, :xai_oauth, %{
          oauth
          | device: updated,
            status: :waiting
        })

      {:authorized, credential} ->
        provider_id = oauth[:provider_id] || "xai"

        case Storage.put(provider_id, credential) do
          :ok ->
            toast = %{
              type: :success,
              message: "已连接 xAI / Grok 订阅",
              id: System.unique_integer([:positive])
            }

            Process.send_after(self(), :clear_toast, 3000)

            socket
            |> assign(:xai_oauth, nil)
            |> assign(:toast, toast)
            |> reload_providers()

          {:error, message} ->
            socket
            |> assign(:xai_oauth, nil)
            |> assign(:form_error, message)
        end

      {:error, message} ->
        socket
        |> assign(:xai_oauth, nil)
        |> assign(:form_error, message)
    end
  end

  defp poll_xai_oauth(socket), do: socket

  defp schedule_xai_poll(device) do
    Process.send_after(self(), :poll_xai_oauth, poll_interval_ms(device))
  end

  defp poll_interval_ms(device) do
    seconds = device[:interval_seconds] || XaiOAuth.default_poll_interval_seconds()
    max(1, seconds) * 1000
  end

  defp ensure_subscription_provider(%{id: provider_id, preset: preset}) do
    case ModelConfig.add_provider(provider_id, preset) do
      :ok ->
        :ok

      {:error, message} ->
        if String.contains?(message, "already exists") do
          ModelConfig.update_provider(provider_id, Map.drop(preset, ["models"]))
        else
          {:error, message}
        end
    end
  end

  defp reload_providers(socket) do
    config = load_raw_config()
    providers = parse_providers(config)
    selected_id = maybe_reselect(socket.assigns.selected_provider_id, providers)

    socket
    |> assign(:config, config)
    |> assign(:providers, providers)
    |> assign(:selected_provider_id, selected_id)
    |> assign(:selected_provider, find_provider(selected_id, providers))
  end

  defp load_raw_config do
    path = ModelConfig.config_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, json} when is_map(json) -> json
          _ -> empty_config()
        end

      _ ->
        empty_config()
    end
  end

  defp empty_config, do: %{"defaultProvider" => "", "providers" => %{}}

  defp parse_providers(config) do
    providers = Map.get(config, "providers", %{})
    default = Map.get(config, "defaultProvider", "")

    Enum.map(providers, fn {id, pc} ->
      %{
        id: id,
        name: Map.get(pc, "name", display_name(id)),
        api: Map.get(pc, "api", ""),
        base_url: Map.get(pc, "baseUrl", ""),
        api_key: Map.get(pc, "apiKey", ""),
        auth_type: Map.get(pc, "authType", "api_key"),
        is_default: id == default,
        provider: Map.get(pc, "provider", id),
        models:
          Map.get(pc, "models", [])
          |> Enum.map(fn m ->
            %{
              id: Map.get(m, "id", ""),
              name: Map.get(m, "name", ""),
              type: List.first(Map.get(m, "input", ["text"])) || "text",
              context_window: Map.get(m, "contextWindow"),
              max_tokens: Map.get(m, "maxTokens"),
              cost: Map.get(m, "cost", %{})
            }
          end)
      }
    end)
  end

  defp display_name(id) do
    id |> String.capitalize()
  end

  defp find_provider(id, providers) do
    Enum.find(providers, &(&1.id == id))
  end

  defp maybe_reselect(current_id, providers) do
    if current_id && Enum.any?(providers, &(&1.id == current_id)) do
      current_id
    else
      providers |> List.first() |> then(&if(&1, do: &1.id))
    end
  end

  defp reset_add_provider_form do
    %{
      "name" => "",
      "id" => "",
      "api" => "openai",
      "base_url" => "",
      "api_key" => "",
      "provider_runtime" => "",
      "model_id" => "",
      "model_name" => "",
      "context_window" => "128000",
      "max_tokens" => "8192",
      "price_input" => "",
      "price_output" => "",
      "price_cache_read" => "",
      "price_cache_write" => "",
      "price_reasoning" => ""
    }
  end

  defp reset_add_model_form do
    %{
      "id" => "",
      "name" => "",
      "type" => "text",
      "context_window" => "128000",
      "max_tokens" => "8192",
      "price_input" => "",
      "price_output" => "",
      "price_cache_read" => "",
      "price_cache_write" => "",
      "price_reasoning" => ""
    }
  end

  defp hydrate_add_provider_form(form, force?) do
    defaults = LlmDbDefaults.defaults_for(form["id"], form["model_id"])

    form
    |> put_default("name", defaults.provider[:provider_name], force?)
    |> put_default("base_url", defaults.provider[:base_url], force?)
    |> put_default("api", defaults.provider[:api], force?)
    |> put_default("provider_runtime", defaults.provider[:provider_runtime], force?)
    |> put_default("model_name", defaults.model[:model_name], force?)
    |> put_default("context_window", to_string_or_nil(defaults.model[:context_window]), force?)
    |> put_default("max_tokens", to_string_or_nil(defaults.model[:max_tokens]), force?)
    |> put_default("price_input", to_string_or_nil(defaults.model[:price_input]), force?)
    |> put_default("price_output", to_string_or_nil(defaults.model[:price_output]), force?)
    |> put_default(
      "price_cache_read",
      to_string_or_nil(defaults.model[:price_cache_read]),
      force?
    )
    |> put_default(
      "price_cache_write",
      to_string_or_nil(defaults.model[:price_cache_write]),
      force?
    )
    |> put_default("price_reasoning", to_string_or_nil(defaults.model[:price_reasoning]), force?)
  end

  defp runtime_provider(params, provider_id) do
    params
    |> Map.get("provider_runtime")
    |> present_or(provider_id)
  end

  defp build_cost_map(params) do
    %{}
    |> maybe_put_cost("input", params["price_input"])
    |> maybe_put_cost("output", params["price_output"])
    |> maybe_put_cost("cache_read", params["price_cache_read"])
    |> maybe_put_cost("cache_write", params["price_cache_write"])
    |> maybe_put_cost("reasoning", params["price_reasoning"])
  end

  defp maybe_put_cost(costs, _key, nil), do: costs

  defp maybe_put_cost(costs, key, value) do
    case parse_float(value) do
      nil -> costs
      number -> Map.put(costs, key, number)
    end
  end

  defp maybe_drop_empty_cost(%{"cost" => cost} = model) when map_size(cost) == 0,
    do: Map.delete(model, "cost")

  defp maybe_drop_empty_cost(model), do: model

  defp provider_source_changed?(previous, params) do
    present_or(params["id"], previous["id"]) != previous["id"] or
      present_or(params["model_id"], previous["model_id"]) != previous["model_id"]
  end

  defp put_default(form, _key, nil, _force?), do: form

  defp put_default(form, key, value, true), do: Map.put(form, key, value)

  defp put_default(form, key, value, false) do
    case Map.get(form, key) do
      nil -> Map.put(form, key, value)
      "" -> Map.put(form, key, value)
      _existing -> form
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)

  defp present_or(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: value
  end

  defp present_or(nil, fallback), do: fallback
  defp present_or(value, _fallback), do: value

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(int, _default) when is_integer(int), do: int

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_float(value) when is_integer(value), do: value * 1.0
  defp parse_float(value) when is_float(value), do: value

  defp format_price_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_price_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end
end
