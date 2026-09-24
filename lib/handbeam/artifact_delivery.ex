defmodule Handbeam.ArtifactDelivery do
  @moduledoc """
  Host dispatch for typed system-UI actions.

  The public tools are `open_url`, `open_file`, and `share_file`. Success means
  the host presented system UI, not that a page loaded, a file was read, or a
  share completed. Raw platform intent fields are rejected.
  """

  alias Handbeam.Host

  @tool_names ~w(open_url open_file share_file)
  @file_tools ~w(open_file share_file)

  @doc "Public system-UI tool names. Registration still requires an artifact delivery backend."
  def tool_names, do: @tool_names

  def tool?(name), do: name in @tool_names

  def file_tool?(name), do: name in @file_tools

  @spec dispatch(map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(command, context) when is_map(command) and is_map(context) do
    if raw_intent?(command) do
      {:error, :raw_intent_rejected}
    else
      case Host.artifact_delivery_backend() do
        fun when is_function(fun, 2) -> fun.(command, context)
        Handbeam.ArtifactDelivery -> {:error, :unavailable}
        mod when is_atom(mod) and not is_nil(mod) -> mod.dispatch(command, context)
        _ -> {:error, :unavailable}
      end
    end
  end

  def dispatch(_, _), do: {:error, :invalid_command}

  def format_outcome("ui_presented"),
    do: "已打开系统界面。这只表示界面已出现，不表示对方已阅读或完成操作。"

  def format_outcome("chooser_presented"),
    do: "已打开系统分享界面。这只表示选择器已出现，不表示文件已发送或对方已接收。"

  def format_outcome("needs_foreground"),
    do: "应用不在前台，无法打开系统界面。请回到 Handbeam 后再试。"

  def format_outcome("no_handler"),
    do: "设备上没有可处理该请求的应用。"

  def format_outcome("cancelled_before_launch"),
    do: "系统界面启动前已取消。"

  def format_outcome("user_rejected"),
    do: "用户取消了系统界面。"

  def format_outcome("file_unavailable"),
    do: "导出副本不可用，请重新请求。"

  def format_outcome("invalid_input"),
    do: "输入无效。"

  def format_outcome("outcome_unknown"),
    do: "系统界面结果未知。未自动重试，不表示失败或已完成。"

  def format_outcome(other) when is_binary(other),
    do: "未能打开系统界面（#{other}）。"

  def format_outcome(_), do: "未能打开系统界面。"

  def presented?("ui_presented"), do: true
  def presented?("chooser_presented"), do: true
  def presented?(_), do: false

  defp raw_intent?(command) do
    Enum.any?(
      ~w(action component package flags extras intent),
      &(Map.has_key?(command, &1) or Map.has_key?(command, String.to_atom(&1)))
    )
  end
end
