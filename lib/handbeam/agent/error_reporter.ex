defmodule Handbeam.Agent.ErrorReporter do
  @moduledoc false

  alias Handbeam.Log.Redactor

  defmodule AgentRunError do
    @moduledoc false
    defexception [:message]
  end

  @failure_classes ~w(
    exception
    provider_overloaded
    provider_rate_limited
    provider_auth
    provider_timeout
    provider_server
    provider_error
    run_timeout
    run_inactivity_timeout
    run_tree_exit
    inbound_persist_failed
    subagent_stopped
    tool_error
    agent_error
  )a

  @provider_failure_classes ~w(
    provider_overloaded
    provider_rate_limited
    provider_auth
    provider_timeout
    provider_server
    provider_error
  )a

  @sensitive_keys MapSet.new(~w(
    api_key apikey token authorization cookie secret password pass openai_api_key
  ))

  @spec report(term(), map(), keyword()) :: :ok
  def report(reason, context, opts \\ []) when is_map(context) and is_list(opts) do
    provider_config = Keyword.get(opts, :provider_config) || %{}
    failure_class = failure_class(reason, Keyword.get(opts, :failure_class))

    context =
      context
      |> Map.put("failure_class", Atom.to_string(failure_class))
      |> put_provider_context(provider_config, Keyword.get(opts, :provider))

    do_report(reason, failure_class, context, provider_config)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_report({%_{} = exception, stacktrace}, failure_class, context, provider_config)
       when is_exception(exception) and is_list(stacktrace) do
    stacktrace =
      if failure_class in @provider_failure_classes,
        do: synthetic_stacktrace(failure_class, context) ++ stacktrace,
        else: stacktrace

    ErrorTracker.report(safe_exception(exception, provider_config), stacktrace, context)
  end

  defp do_report(%_{} = exception, failure_class, context, provider_config)
       when is_exception(exception) do
    ErrorTracker.report(
      safe_exception(exception, provider_config),
      synthetic_stacktrace(failure_class, context),
      context
    )
  end

  defp do_report(reason, failure_class, context, provider_config) do
    exception = AgentRunError.exception(safe_reason(reason, provider_config))
    ErrorTracker.report(exception, synthetic_stacktrace(failure_class, context), context)
  end

  defp safe_exception(exception, provider_config) do
    message = Exception.message(exception)
    safe = sanitize(message, provider_config)

    if safe == message do
      exception
    else
      AgentRunError.exception("#{inspect(exception.__struct__)}: #{safe}")
    end
  end

  defp safe_reason(reason, provider_config) do
    reason
    |> render_reason()
    |> sanitize(provider_config)
  end

  defp render_reason(reason) when is_binary(reason), do: reason
  defp render_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp render_reason(reason) do
    inspect(reason, limit: 50, printable_limit: 4_000)
  end

  defp sanitize(text, provider_config) do
    provider_config
    |> secret_values()
    |> Enum.reduce(text, fn secret, safe -> String.replace(safe, secret, "[REDACTED]") end)
    |> Redactor.redact()
    |> String.slice(0, 4_000)
  end

  defp secret_values(value), do: secret_values(value, nil)

  defp secret_values(map, _key) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> secret_values(value, key) end)
  end

  defp secret_values(list, _key) when is_list(list) do
    Enum.flat_map(list, &secret_values(&1, nil))
  end

  defp secret_values(value, key) when is_binary(value) do
    if sensitive_key?(key) and value != "", do: [value], else: []
  end

  defp secret_values(_value, _key), do: []

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  defp sensitive_key?(key) when is_binary(key) do
    MapSet.member?(@sensitive_keys, String.downcase(key))
  end

  defp sensitive_key?(_key), do: false

  defp failure_class(_reason, forced) when forced in @failure_classes, do: forced

  defp failure_class(reason, _forced) do
    text = reason |> render_reason() |> String.downcase()

    cond do
      contains?(text, ["server_is_overloaded", "overloaded", "capacity"]) ->
        :provider_overloaded

      contains?(text, ["rate_limit", "rate limit", "too many requests", "429"]) ->
        :provider_rate_limited

      contains?(text, ["unauthorized", "forbidden", "api key", "authentication", "401", "403"]) ->
        :provider_auth

      contains?(text, ["timeout", "timed out", "etimedout"]) ->
        :provider_timeout

      Regex.match?(~r/(?:http|status)[^0-9]{0,8}5\d\d|\b5\d\d\b/, text) ->
        :provider_server

      contains?(text, ["provider", "gateway", "transport", "connection", "socket", "dns", "tls"]) ->
        :provider_error

      exception_reason?(reason) ->
        :exception

      true ->
        :agent_error
    end
  end

  defp contains?(text, markers), do: Enum.any?(markers, &String.contains?(text, &1))

  defp exception_reason?({%_{} = exception, stacktrace}),
    do: is_exception(exception) and is_list(stacktrace)

  defp exception_reason?(%_{} = exception), do: is_exception(exception)
  defp exception_reason?(_reason), do: false

  defp put_provider_context(context, provider_config, provider_module) do
    provider = field(provider_config, :provider) || module_name(provider_module)
    gateway_host = provider_config |> field(:base_url) |> gateway_host()

    context
    |> put_present("provider", provider)
    |> put_present("gateway_host", gateway_host)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp module_name(module) when is_atom(module) and not is_nil(module) do
    module |> inspect() |> String.replace_prefix("Elixir.", "")
  end

  defp module_name(_module), do: nil

  defp gateway_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp gateway_host(_url), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp synthetic_stacktrace(failure_class, context) do
    source =
      context["gateway_host"] || context["provider"] || context["source"] || "agent_runtime"

    source =
      [source, context["tool"], context["subagent_type"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("/", &safe_source/1)

    file = "agent://#{source}"
    [{__MODULE__, failure_class, 0, file: file, line: 0}]
  end

  defp safe_source(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.slice(0, 120)
  end
end
