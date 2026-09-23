defmodule Handbeam.Extension.ProviderSpec do
  @moduledoc """
  Extension-declared model provider metadata.

  Does NOT connect to ModelConfig.
  """

  alias Handbeam.Extension.Manifest
  alias Handbeam.Extension.Diagnostic

  defstruct [:extension, :name, :base_url, :api, :api_key_env, models: []]

  @type t :: %__MODULE__{
          extension: String.t(),
          name: String.t(),
          base_url: String.t() | nil,
          api: String.t() | nil,
          api_key_env: String.t() | nil,
          models: [map()]
        }

  @spec new(String.t(), String.t(), map()) :: {:ok, t()} | {:error, Diagnostic.t()}
  def new(_extension, "", _opts) do
    {:error, %Diagnostic{type: :validation_error, message: "provider name must not be empty"}}
  end

  def new(extension, provider_name, opts) do
    with :ok <- Manifest.validate_name(extension) do
      spec = %__MODULE__{
        extension: extension,
        name: provider_name,
        base_url: Map.get(opts, :base_url) || Map.get(opts, "base_url"),
        api: Map.get(opts, :api) || Map.get(opts, "api"),
        api_key_env: Map.get(opts, :api_key_env) || Map.get(opts, "api_key_env"),
        models: Map.get(opts, :models) || Map.get(opts, "models") || []
      }

      {:ok, spec}
    end
  end
end
