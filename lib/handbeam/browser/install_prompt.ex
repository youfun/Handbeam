defmodule Handbeam.Browser.InstallPrompt do
  @moduledoc """
  User-facing install card when `agent-browser` is missing.

  This is presentation only. It never installs the binary.
  """

  @command "npm install -g agent-browser && agent-browser install"

  @type t :: %{title: String.t(), command: String.t(), hint: String.t()}

  @doc "Canonical install command shown to the user and the model."
  @spec command() :: String.t()
  def command, do: @command

  @doc "Build a card from tool result details, or nil."
  @spec from_details(map() | nil) :: t() | nil
  def from_details(details) when is_map(details) do
    if missing_binary?(details) do
      %{
        title: "Install agent-browser to use the browser tool",
        command: @command,
        hint: "Install once on this machine, then retry. Handbeam can keep running."
      }
    end
  end

  def from_details(_), do: nil

  @doc "Build a card from a timeline tool entry, or nil."
  @spec from_entry(map() | nil) :: t() | nil
  def from_entry(entry) when is_map(entry) do
    from_details(Map.get(entry, "details") || Map.get(entry, :details))
  end

  def from_entry(_), do: nil

  defp missing_binary?(details) do
    category(details) == "missing-binary" or
      Enum.any?(next_actions(details), &(action_id(&1) == "install-agent-browser"))
  end

  defp category(details) do
    details[:failure_category] || details["failure_category"]
  end

  defp next_actions(details) do
    details[:next_actions] || details["next_actions"] || []
  end

  defp action_id(%{id: id}), do: id
  defp action_id(%{"id" => id}), do: id
  defp action_id(_), do: nil
end
