defmodule Handbeam.Agent.Middleware.Logger do
  @moduledoc """
  Logging middleware — records turn info.
  """

  @behaviour Handbeam.Agent.Middleware

  alias Handbeam.Agent.State

  require Logger

  @impl true
  def call(:session_start, %State{} = state) do
    Logger.info("[Handbeam] Session started (model: #{state.config.model})")
    state
  end

  @impl true
  def call(:session_end, %State{} = state) do
    Logger.info("[Handbeam] Session ended — status: #{state.status}, turns: #{state.turn}")
    state
  end

  @impl true
  def call(:before_completion, %State{} = state) do
    state
  end

  @impl true
  def call(:after_completion, %State{} = state) do
    state
  end

  @impl true
  def call(:after_compaction, %State{} = state), do: state

  @impl true
  def call(:after_tool_request, %State{} = state) do
    state
  end

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    state
  end

  @impl true
  def call(:on_error, %State{} = state) do
    Logger.error("[Handbeam] Error: #{state.error}")
    state
  end
end
