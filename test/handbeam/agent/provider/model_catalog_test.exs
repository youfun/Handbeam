defmodule Handbeam.Agent.Provider.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.ModelConfig
  alias Handbeam.Agent.Provider.ModelCatalog

  defmodule ReqMock do
    def get(url, opts) do
      send(self(), {:models_request, url, opts})
      Process.get(:model_catalog_response)
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "model_catalog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = System.get_env("HANDBEAM_MODELS_FILE")
    System.put_env("HANDBEAM_MODELS_FILE", Path.join(dir, "models.json"))

    on_exit(fn ->
      if previous,
        do: System.put_env("HANDBEAM_MODELS_FILE", previous),
        else: System.delete_env("HANDBEAM_MODELS_FILE")

      File.rm_rf!(dir)
    end)

    :ok
  end

  test "responses base without /v1 requests /v1/models" do
    assert ModelCatalog.models_url("http://127.0.0.1:3425", "openai-responses") ==
             "http://127.0.0.1:3425/v1/models"

    assert ModelCatalog.models_url("http://127.0.0.1:3425/v1", "openai-responses") ==
             "http://127.0.0.1:3425/v1/models"
  end

  test "chat completions base keeps its /v1 and appends /models" do
    assert ModelCatalog.models_url("http://127.0.0.1:3425/v1", "openai-chat-completions") ==
             "http://127.0.0.1:3425/v1/models"
  end

  test "discover merges remote ids and keeps a disappeared model unavailable" do
    :ok =
      ModelConfig.add_provider("magpie", %{
        "name" => "Magpie",
        "api" => "openai-responses",
        "baseUrl" => "http://127.0.0.1:3425",
        "apiKey" => "magpie",
        "models" => [
          %{
            "id" => "openai/gpt-4o-mini",
            "name" => "Custom mini",
            "input" => ["text"],
            "enabled" => false
          },
          %{"id" => "gone", "name" => "Gone", "input" => ["text"]}
        ]
      })

    Process.put(
      :model_catalog_response,
      {:ok,
       %{
         status: 200,
         body: %{
           "object" => "list",
           "data" => [
             %{"id" => "openai/gpt-4o-mini", "object" => "model"},
             %{"id" => "deepseek/deepseek-chat", "object" => "model"}
           ]
         }
       }}
    )

    assert {:ok, %{added: 1, total: 3}} =
             ModelCatalog.discover("magpie", req_module: ReqMock)

    assert_received {:models_request, "http://127.0.0.1:3425/v1/models", opts}
    assert {"authorization", "Bearer magpie"} in opts[:headers]

    {:ok, config} = ModelConfig.read_config()
    models = config["providers"]["magpie"]["models"]
    mini = Enum.find(models, &(&1["id"] == "openai/gpt-4o-mini"))
    deepseek = Enum.find(models, &(&1["id"] == "deepseek/deepseek-chat"))
    gone = Enum.find(models, &(&1["id"] == "gone"))

    assert mini["name"] == "Custom mini"
    assert mini["enabled"] == false
    assert mini["contextWindow"] == 128_000
    assert mini["maxTokens"] == 16_384
    assert deepseek["name"] == "DeepSeek-V3.2 (Non-thinking Mode)"
    assert is_integer(deepseek["contextWindow"])
    assert gone["unavailable"] == true
  end

  test "catalog enrichment survives an llm_db app dir failure" do
    assert Handbeam.LlmDbDefaults.enrich_model("provider/unknown-model", nil, fn ->
             raise ArgumentError, "unknown application: :llm_db"
           end) == %{
             "id" => "provider/unknown-model",
             "name" => "provider/unknown-model",
             "input" => ["text"]
           }
  end

  test "a failed list does not replace saved models" do
    :ok =
      ModelConfig.add_provider("magpie", %{
        "name" => "Magpie",
        "api" => "openai-chat-completions",
        "baseUrl" => "http://127.0.0.1:3425/v1",
        "apiKey" => "magpie",
        "models" => [%{"id" => "kept", "name" => "Kept", "input" => ["text"]}]
      })

    Process.put(:model_catalog_response, {:ok, %{status: 503, body: %{}}})

    assert {:error, message} = ModelCatalog.discover("magpie", req_module: ReqMock)
    assert message =~ "HTTP 503"

    {:ok, config} = ModelConfig.read_config()
    assert [%{"id" => "kept"}] = config["providers"]["magpie"]["models"]
  end

  test "anthropic and oauth providers are not fetched from /v1/models" do
    refute ModelCatalog.fetchable?(%{
             "api" => "anthropic-messages",
             "baseUrl" => "http://127.0.0.1:3425"
           })

    refute ModelCatalog.fetchable?(%{
             "api" => "openai-responses",
             "baseUrl" => "http://127.0.0.1:3425",
             "authType" => "oauth"
           })
  end
end
