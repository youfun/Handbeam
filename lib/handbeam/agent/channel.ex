defmodule Handbeam.Agent.Channel do
  @moduledoc """
  Channel classification for a run source.

  Unattended channels share the turn cap and progress guard. Interactive
  channels are the only place a person can change a schedule.
  """

  @unattended [:sns, :webhook, :cli, :schedule]
  @interactive [:live_view, :native]

  @spec unattended?(term()) :: boolean()
  def unattended?(source) when source in @unattended, do: true
  def unattended?(source) when is_binary(source), do: unattended?(atom(source))
  def unattended?(_source), do: false

  @spec interactive?(term()) :: boolean()
  def interactive?(source) when source in @interactive, do: true
  def interactive?(source) when is_binary(source), do: interactive?(atom(source))
  def interactive?(_source), do: false

  defp atom(source) do
    String.to_existing_atom(source)
  rescue
    ArgumentError -> source
  end
end
