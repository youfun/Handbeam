defmodule Handbeam.Agent.Auth.Subscriptions do
  @moduledoc """
  Catalog of subscription / OAuth login methods that Settings can list.

  The menu is generic like pi's `/login` selector: each entry has a
  provider id, display name, and login label. Only xAI is implemented
  in this slice; later subscriptions register here without changing
  the LiveView entry point.
  """

  alias Handbeam.Agent.Auth.XaiCredential

  @type method :: %{
          id: String.t(),
          name: String.t(),
          login_label: String.t(),
          auth_type: :oauth,
          subscription?: boolean()
        }

  @spec methods() :: [method()]
  def methods do
    [
      %{
        id: "xai",
        name: "xAI",
        login_label: "xAI (Grok/X subscription)",
        auth_type: :oauth,
        subscription?: true,
        preset: XaiCredential.provider_preset()
      }
    ]
  end

  @spec get(String.t()) :: {:ok, method()} | {:error, String.t()}
  def get(provider_id) when is_binary(provider_id) do
    case Enum.find(methods(), &(&1.id == provider_id)) do
      nil -> {:error, "Subscription provider #{provider_id} is not available"}
      method -> {:ok, method}
    end
  end
end
