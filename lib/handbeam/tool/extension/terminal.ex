defmodule Handbeam.Tool.Extension.Terminal do
  @moduledoc """
  Terminal introspection tools for LLM agents.

  Provides ext__term_list, ext__term_output, and ext__term_send tools
  for listing, reading, and sending input to workspace terminal sessions.
  """

  alias Handbeam.Terminal.Supervisor, as: TermSup

  @max_output_bytes 50_000

  @doc """
  Registers terminal tools in the Tool.Registry.

  ext__term_list and ext__term_output are read-only (safe).
  ext__term_send is a write tool (requires prompt by default).
  """
  def register do
    tools()
    |> Map.values()
    |> Enum.each(fn %{name: name, description: desc, input_schema: schema, execute: exec} ->
      Handbeam.Tool.Registry.register_virtual(
        name,
        desc,
        schema,
        exec
      )
    end)

    :ok
  end

  @doc """
  Returns tool name to tool module map for registration.
  """
  def tools do
    %{
      "ext__term_list" => %{
        name: "ext__term_list",
        description: "列出当前工作区所有终端",
        input_schema: %{"type" => "object", "properties" => %{}, "required" => []},
        execute: &ext_term_list/2
      },
      "ext__term_output" => %{
        name: "ext__term_output",
        description: "读取指定终端的输出",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "terminal" => %{"type" => "string", "description" => "终端名称"},
            "tail" => %{"type" => "integer", "description" => "返回最后 N 行（默认: 全部）"},
            "grep" => %{"type" => "string", "description" => "大小写不敏感正则过滤"}
          },
          "required" => ["terminal"]
        },
        execute: &ext_term_output/2
      },
      "ext__term_send" => %{
        name: "ext__term_send",
        description: "向指定终端发送输入",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "terminal" => %{"type" => "string", "description" => "终端名称"},
            "input" => %{"type" => "string", "description" => "要发送的输入"}
          },
          "required" => ["terminal", "input"]
        },
        execute: &ext_term_send/2
      }
    }
  end

  @doc false
  def ext_term_list(_input, context) do
    workspace_id = Map.get(context, :workspace_id, Map.get(context, "workspace_id"))

    if is_nil(workspace_id) do
      {:error, "workspace_id is required in context"}
    else
      terminals =
        TermSup.list_terminals(workspace_id)
        |> Enum.map(fn t ->
          %{
            name: t.name,
            status: t.status,
            cmd: t.cmd,
            args: t.args,
            cwd: t.cwd
          }
        end)

      {:ok, Handbeam.JSON.encode!(terminals, pretty: true)}
    end
  end

  @doc false
  def ext_term_output(input, context) do
    workspace_id = Map.get(context, :workspace_id, Map.get(context, "workspace_id"))
    terminal_name = Map.get(input, "terminal")
    tail = Map.get(input, "tail")
    grep = Map.get(input, "grep")

    cond do
      is_nil(workspace_id) ->
        {:error, "workspace_id is required in context"}

      is_nil(terminal_name) or terminal_name == "" ->
        {:error, "terminal name is required"}

      true ->
        case TermSup.lookup(workspace_id, terminal_name) do
          {:ok, pid} ->
            opts =
              [tail: tail, grep: grep]
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)

            case Handbeam.Terminal.Session.snapshot(pid, opts) do
              {:ok, text} ->
                %{content: content} =
                  Handbeam.Utils.Truncate.truncate(text, :tail, max_bytes: @max_output_bytes)

                {:ok, content}

              {:error, reason} ->
                {:error, "failed to read terminal output: #{inspect(reason)}"}
            end

          {:error, :not_found} ->
            {:error, "terminal '#{terminal_name}' not found in workspace"}
        end
    end
  end

  @doc false
  def ext_term_send(input, context) do
    workspace_id = Map.get(context, :workspace_id, Map.get(context, "workspace_id"))
    terminal_name = Map.get(input, "terminal")
    text_input = Map.get(input, "input")

    if is_nil(workspace_id) do
      {:error, "workspace_id is required in context"}
    else
      cond do
        is_nil(terminal_name) or terminal_name == "" ->
          {:error, "terminal name is required"}

        is_nil(text_input) or text_input == "" ->
          {:error, "input is required"}

        true ->
          case TermSup.lookup(workspace_id, terminal_name) do
            {:ok, pid} ->
              case Handbeam.Terminal.Session.send_input(pid, text_input) do
                :ok -> {:ok, "input sent to terminal '#{terminal_name}'"}
                {:error, reason} -> {:error, "failed to send input: #{inspect(reason)}"}
              end

            {:error, :not_found} ->
              {:error, "terminal '#{terminal_name}' not found in workspace"}
          end
      end
    end
  end
end
