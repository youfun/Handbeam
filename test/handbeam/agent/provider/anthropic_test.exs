defmodule Handbeam.Agent.Provider.AnthropicTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.Message
  alias Handbeam.Agent.Provider.Anthropic

  setup do
    Req.Test.stub(__MODULE__, nil)
    :ok
  end

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end
  end

  describe "complete/3 with tool_use response" do
    test "returns normalized tool_use response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_02",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me read that file."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_01",
                  "name" => "read",
                  "input" => %{"file_path" => "mix.exs"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            })
        })

      assert {:ok, result} =
               Anthropic.complete(
                 [Message.user("Read mix.exs")],
                 [%{name: "read", description: "Read a file", input_schema: %{}}],
                 config
               )

      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages
      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "complete/3 message formatting" do
    test "formats user messages correctly" do
      config = config_that_captures_request()

      Anthropic.complete(
        [Message.user("Hello"), Message.assistant("Hi"), Message.user("How?")],
        [],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert length(decoded["messages"]) == 3
      assert hd(decoded["messages"])["role"] == "user"
    end

    test "includes system prompt" do
      config = config_that_captures_request() |> Map.put(:system_prompt, "You are helpful.")
      Anthropic.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      assert Jason.decode!(body)["system"] == "You are helpful."
    end

    test "includes tool definitions" do
      config = config_that_captures_request()

      Anthropic.complete(
        [Message.user("Hi")],
        [%{name: "read", description: "Read", input_schema: %{type: "object", properties: %{}}}],
        config
      )

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert hd(decoded["tools"])["name"] == "read"
    end

    test "formats tool_result messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read"),
        Message.assistant_blocks([
          %{type: "text", text: "Reading..."},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([Message.tool_result_block("toolu_01", "file contents")])
      ]

      Anthropic.complete(messages, [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      tool_result_msg = List.last(decoded["messages"])
      assert tool_result_msg["role"] == "user"
      assert hd(tool_result_msg["content"])["type"] == "tool_result"
    end
  end

  describe "complete/3 error handling" do
    test "returns error on 500" do
      config = config_with_response(%{status: 500, body: "Server Error"})
      assert {:error, _} = Anthropic.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "invalid_request_error", "message" => "bad request"}
            })
        })

      assert {:error, reason} = Anthropic.complete([Message.user("Hi")], [], config)
      assert reason =~ "invalid_request_error"
    end
  end

  describe "complete/3 with cache: true" do
    test "system prompt with cache_control" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "Helpful")
        |> Map.put(:cache, true)

      Anthropic.complete([Message.user("Hi")], [], config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert is_list(decoded["system"])
      assert hd(decoded["system"])["cache_control"] == %{"type" => "ephemeral"}
    end

    test "last tool gets cache_control" do
      config = config_that_captures_request() |> Map.put(:cache, true)

      tool_defs = [
        %{name: "read", description: "R", input_schema: %{}},
        %{name: "write", description: "W", input_schema: %{}}
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)
      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      refute Map.has_key?(hd(decoded["tools"]), "cache_control")
      assert List.last(decoded["tools"])["cache_control"] == %{"type" => "ephemeral"}
    end
  end

  # ── stream/4 ──

  describe "stream/4" do
    test "emits text chunks" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => " world"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end
      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert Message.text(hd(result.messages)) == "Hello world"
      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
    end

    test "accumulates tool call stream" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 20, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_01",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"file_path\""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ": \"mix.exs\"}"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 15}
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} =
               Anthropic.stream([Message.user("Read mix.exs")], [], config, fn _ -> :ok end)

      assert result.stop_reason == :tool_use
      tool_call = Enum.find(hd(result.messages).content, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  # ── Extended Thinking ──

  describe "complete/3 with thinking" do
    test "preserves thinking block" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_t",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "thinking", "thinking" => "Reasoning...", "signature" => "sig123"},
                %{"type" => "text", "text" => "Answer: 42"}
              ],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 30}
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Q")], [], config)
      [thinking, _] = hd(result.messages).content
      assert thinking.type == "thinking"
      assert thinking.signature == "sig123"
    end

    test "extended_thinking in request" do
      config = config_that_captures_request() |> Map.put(:extended_thinking, budget_tokens: 5000)
      Anthropic.complete([Message.user("Think")], [], config)
      assert_received {:request_body, body}
      assert Jason.decode!(body)["thinking"] == %{"type" => "enabled", "budget_tokens" => 5000}
    end

    test "raises without budget_tokens" do
      config = config_that_captures_request() |> Map.put(:extended_thinking, [])

      assert_raise ArgumentError, ~r/budget_tokens/, fn ->
        Anthropic.complete([Message.user("Hi")], [], config)
      end
    end
  end

  # ── Retry behavior ──

  describe "retry behavior" do
    test "no retry on 429" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "Too Many") end)

      config = %{
        api_key: "sk-test",
        model: "claude-sonnet-4-6",
        max_tokens: 4096,
        req_options: [plug: {Req.Test, __MODULE__}]
      }

      assert {:error, "HTTP 429: Too Many"} = Anthropic.complete([Message.user("Hi")], [], config)
    end
  end

  # ── Helpers ──

  defp config_with_response(response) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, response.status, response.body)
      end)
    end)
  end

  defp ant_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end)
  end

  defp config_that_captures_request do
    test_pid = self()

    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      cache: false,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "msg_cap",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        )
      end)
    end)
  end
end
