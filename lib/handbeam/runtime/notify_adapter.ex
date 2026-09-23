defmodule Handbeam.Runtime.NotifyAdapter do
  @moduledoc """
  Host-facing notification actions. Desktop and tests use `Noop`.
  """

  alias Handbeam.Runtime.Notify

  @callback app_visible?() :: boolean()
  @callback apply(Notify.action()) :: :ok

  defmodule Noop do
    @moduledoc false
    @behaviour Handbeam.Runtime.NotifyAdapter

    @impl true
    def app_visible?, do: true

    @impl true
    def apply(_action), do: :ok
  end

  @spec adapter() :: module()
  def adapter do
    Application.get_env(:handbeam, :runtime_notify_adapter, Noop)
  end

  @spec app_visible?() :: boolean()
  def app_visible?, do: adapter().app_visible?()

  @spec apply(Notify.action()) :: :ok
  def apply(action), do: adapter().apply(action)
end
