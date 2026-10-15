defmodule Handbeam.ConversationArtifacts do
  @moduledoc """
  Filesystem owner for recoverable artifacts associated with a conversation.

  Transcript, metadata, receipts, and session snapshots do not live here; they
  are canonical SQLite data. This root is only for files such as large saved
  tool inputs, reversible change snapshots, and subagent descriptors.
  """

  @spec root() :: String.t()
  def root do
    Application.get_env(
      :handbeam,
      :conversation_artifact_root,
      Path.join(Handbeam.Host.data_dir(), ".handbeam/conversation-artifacts")
    )
  end
end
