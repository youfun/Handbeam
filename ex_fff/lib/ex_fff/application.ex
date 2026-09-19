defmodule ExFff.Application do
  @moduledoc """
  OTP Application for ExFff.

  Starts the supervision tree with `ExFff.Index` as a child.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = []

    opts = [strategy: :one_for_one, name: ExFff.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
