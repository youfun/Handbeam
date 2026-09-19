defmodule Handbeam.Skills.Loader do
  @moduledoc """
  Skill Loader — discovers and loads skills from filesystem locations.

  Discovery rules:
  1. If a directory contains SKILL.md, it is a skill root — stop recursion.
  2. Supports recursive discovery of SKILL.md in subdirectories.
  3. Skips hidden directories, node_modules, unreadable files.
  4. .gitignore / .ignore / .fdignore support is P1 — not yet implemented.
  """

  alias Handbeam.Skills.Skill

  defmodule LoadResult do
    @moduledoc false
    defstruct skills: [], diagnostics: []
  end

  @type load_result :: %LoadResult{
          skills: [Skill.t()],
          diagnostics: [map()]
        }

  @doc """
  Load skills from configured workspace and user locations.

  Project skill directories are loaded before user-level directories so a project
  skill wins when it has the same name as a global skill.
  """
  @spec load(keyword()) :: load_result()
  def load(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    user_home = Keyword.get(opts, :user_home, Handbeam.Home.path())

    dirs = [
      {Path.join(workspace, ".handbeam/skills"), :project},
      {Path.join(workspace, ".agents/skills"), :project},
      {Path.join(user_home, ".handbeam/skills"), :user},
      {Path.join(user_home, ".agents/skills"), :user}
    ]

    Enum.reduce(dirs, %LoadResult{}, fn {dir, source}, acc ->
      sub = load_from_dir(dir, source)
      merge_result(acc, sub)
    end)
  end

  @doc "Load skills from a single directory."
  @spec load_from_dir(String.t(), Skill.source()) :: load_result()
  def load_from_dir(dir, source) do
    do_load_from_dir(dir, source)
  end

  # ── Internal ──

  defp do_load_from_dir(dir, source) do
    result = %LoadResult{}

    if not File.dir?(dir) do
      result
    else
      entries = File.ls!(dir)

      if "SKILL.md" in entries do
        full_path = Path.join(dir, "SKILL.md")

        try do
          if File.stat!(full_path).type == :regular do
            case load_skill_file(full_path, source) do
              {:ok, skill, diagnostics} ->
                %LoadResult{skills: [skill], diagnostics: diagnostics}

              {:error, diagnostics} ->
                %LoadResult{diagnostics: diagnostics}
            end
          else
            result
          end
        rescue
          _ -> result
        end
      else
        Enum.reduce(entries, result, fn entry, acc ->
          next = Path.join(dir, entry)

          if String.starts_with?(entry, ".") || entry == "node_modules" do
            acc
          else
            if File.dir?(next) do
              sub = do_load_from_dir(next, source)
              merge_result(acc, sub)
            else
              acc
            end
          end
        end)
      end
    end
  end

  defp load_skill_file(file_path, source) do
    case File.read(file_path) do
      {:error, reason} ->
        {:error,
         [
           %{
             type: :error,
             message: "failed to read skill file: #{inspect(reason)}",
             path: file_path
           }
         ]}

      {:ok, content} ->
        {frontmatter, _} = parse_frontmatter(content)
        parent_dir_name = file_path |> Path.dirname() |> Path.basename()
        Skill.build(frontmatter, file_path, parent_dir_name, source)
    end
  end

  @doc false
  def parse_frontmatter(content) do
    case String.split(content, "\n---\n", parts: 2) do
      [maybe_front, _body] ->
        front_str =
          maybe_front
          |> String.trim_leading("---\n")
          |> String.trim_leading("---")

        parsed = parse_yaml_like(front_str)
        {parsed, []}

      _ ->
        {%{}, []}
    end
  end

  defp parse_yaml_like(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          trimmed_key = String.trim(key)
          trimmed_val = String.trim(value)

          trimmed_val =
            if (String.starts_with?(trimmed_val, "\"") and String.ends_with?(trimmed_val, "\"")) or
                 (String.starts_with?(trimmed_val, "'") and String.ends_with?(trimmed_val, "'")) do
              String.slice(trimmed_val, 1..-2//1)
            else
              trimmed_val
            end

          cond do
            trimmed_val == "true" -> Map.put(acc, trimmed_key, true)
            trimmed_val == "false" -> Map.put(acc, trimmed_key, false)
            true -> Map.put(acc, trimmed_key, trimmed_val)
          end

        _ ->
          acc
      end
    end)
  end

  @doc false
  def merge_result(%LoadResult{} = acc, %LoadResult{} = sub) do
    existing_names = MapSet.new(acc.skills, & &1.name)

    {new_skills, collision_diags} =
      Enum.reduce(sub.skills, {acc.skills, []}, fn skill, {skills, diags} ->
        if MapSet.member?(existing_names, skill.name) do
          existing = Enum.find(acc.skills, &(&1.name == skill.name))

          collision_diag = %{
            type: :collision,
            message: ~s(name "#{skill.name}" collision),
            path: skill.location,
            winner_path: existing.location
          }

          {skills, [collision_diag | diags]}
        else
          {[skill | skills], diags}
        end
      end)

    new_skills = Enum.reverse(new_skills)

    %LoadResult{
      skills: new_skills,
      diagnostics: acc.diagnostics ++ sub.diagnostics ++ collision_diags
    }
  end
end
