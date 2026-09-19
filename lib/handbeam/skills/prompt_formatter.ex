defmodule Handbeam.Skills.PromptFormatter do
  @moduledoc """
  Formats available skills for inclusion in the system prompt.

  Uses XML format per the Agent Skills specification:
  https://agentskills.io/integrate-skills

  Skills with disable_model_invocation: true are excluded.
  Does NOT include SKILL.md body content.
  """

  alias Handbeam.Skills.Skill

  @doc """
  Format skills as an XML available_skills block.
  Returns empty string when all skills are disabled or list is empty.
  """
  @spec format_available_skills([Skill.t()]) :: String.t()
  def format_available_skills(skills) do
    visible = Enum.reject(skills, & &1.disable_model_invocation)

    if visible == [] do
      ""
    else
      header = [
        "\n\nThe following skills provide specialized instructions for specific tasks.",
        "Use the read tool to load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
        "",
        "<available_skills>"
      ]

      body = Enum.flat_map(visible, &format_one/1)

      footer = ["</available_skills>"]

      (header ++ body ++ footer) |> Enum.join("\n")
    end
  end

  defp format_one(skill) do
    [
      "  <skill>",
      "    <name>#{escape_xml(skill.name)}</name>",
      "    <description>#{escape_xml(skill.description)}</description>",
      "    <location>#{escape_xml(skill.location)}</location>",
      "  </skill>"
    ]
  end

  @doc false
  def escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
