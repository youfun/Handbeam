defmodule Handbeam.WorkspaceFiles do
  @moduledoc """
  Workspace path resolve, name routing, and single-directory listing.

  Rejects every symlink on the workspace root and each relative component.
  Root ancestors are not walked. Bytes are not read here; Android opens one fd.

  `File.ls/1` materializes the whole directory before hide/sort/cap.
  """

  @type kind :: :file | :directory | :any

  @image_exts ~w(.png .jpg .jpeg .gif .webp)
  @external_exts ~w(.pdf .zip .gz .tgz .jar .apk .so .exe .docx .xlsx .pptx)
  @text_exts ~w(
    .txt .md .markdown .json .csv .html .htm .css .xml .yml .yaml .toml
    .ex .exs .erl .hrl .js .ts .tsx .jsx .py .rb .go .rs .c .h .cpp .hpp
    .java .kt .kts .swift .sh .sql .gitignore .dockerignore .env.example
  )
  @default_max 256

  @spec resolve(String.t(), String.t(), kind()) :: {:ok, String.t()} | {:error, term()}
  def resolve(workspace_root, relative_path, kind \\ :file)

  def resolve(workspace_root, relative_path, kind)
      when is_binary(workspace_root) and is_binary(relative_path) and
             kind in [:file, :directory, :any] do
    with {:ok, root} <- normalize_root(workspace_root),
         {:ok, names} <- relative_names(relative_path) do
      walk(root, names, kind, root)
    end
  end

  def resolve(_, _, _), do: {:error, :invalid_path}

  @spec kind_from_name(String.t() | nil) :: {:ok, :text | :image | :external, String.t()}
  def kind_from_name(display_name) do
    ext = display_name |> to_string() |> Path.extname() |> String.downcase()

    cond do
      ext in @image_exts -> {:ok, :image, image_mime(ext)}
      ext in @external_exts -> {:ok, :external, external_mime(ext)}
      true -> {:ok, :text, text_mime(ext)}
    end
  end

  @spec list(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(workspace_root, relative_dir \\ "", opts \\ [])
      when is_binary(workspace_root) and is_binary(relative_dir) and is_list(opts) do
    max = Keyword.get(opts, :max_entries, @default_max)
    show_hidden = Keyword.get(opts, :show_hidden, false)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)

    with {:ok, dir} <- resolve(workspace_root, relative_dir, :directory),
         {:ok, names} <- File.ls(dir),
         {:ok, root} <- resolve(workspace_root, "", :directory) do
      entries =
        names
        |> Enum.reject(&hidden?(&1, show_hidden))
        |> Enum.flat_map(&entry(dir, &1, root))
        |> Enum.sort_by(&{&1.kind != :directory, String.downcase(&1.name)})

      {_skipped, remaining} = Enum.split(entries, offset)
      {kept, rest} = Enum.split(remaining, max)

      {:ok,
       %{
         relative_dir: relative_dir,
         entries: kept,
         truncated: rest != [],
         scanned: length(names),
         max_entries: max,
         offset: offset,
         next_offset: offset + length(kept)
       }}
    end
  end

  defp normalize_root(root) do
    path = Path.expand(root)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, path}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp relative_names(""), do: {:ok, []}

  defp relative_names(relative) when is_binary(relative) do
    cond do
      String.contains?(relative, <<0>>) ->
        {:error, :invalid_path}

      Path.type(relative) == :absolute ->
        {:error, :invalid_path}

      true ->
        names =
          relative
          |> Path.split()
          |> Enum.reject(&(&1 in ["", "."]))

        if Enum.any?(names, &(&1 == "..")) do
          {:error, :invalid_path}
        else
          {:ok, names}
        end
    end
  end

  defp walk(current, [], kind, root), do: finish(current, kind, root)

  defp walk(current, [name | rest], kind, root) do
    next = Path.join(current, name)

    case File.lstat(next) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink}

      {:ok, %File.Stat{type: :directory}} ->
        if rest == [] do
          finish(next, kind, root)
        else
          walk(next, rest, kind, root)
        end

      {:ok, %File.Stat{type: :regular}} ->
        if rest == [] do
          finish(next, kind, root)
        else
          {:error, :not_directory}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsupported_type, type}}
    end
  end

  defp finish(path, kind, root) do
    if contained?(path, root) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} when kind in [:file, :any] ->
          {:ok, path}

        {:ok, %File.Stat{type: :directory}} when kind in [:directory, :any] ->
          {:ok, path}

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :symlink}

        {:ok, %File.Stat{type: type}} ->
          {:error, {:unexpected_type, type}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :outside_workspace}
    end
  end

  @doc false
  @spec contained?(String.t(), String.t()) :: boolean()
  def contained?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)

    # Component-wise containment: `/tmp/ws2/x` is not under `/tmp/ws`.
    # Symlinks are rejected per component in walk/4, not here.
    path == root or
      match?(
        {:ok, _},
        Path.safe_relative_to(Path.relative_to(path, root, force: true), root)
      )
  end

  defp hidden?("." <> _, false), do: true
  defp hidden?(_, _), do: false

  defp entry(dir, name, root) do
    path = Path.join(dir, name)

    kind =
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> :directory
        {:ok, %File.Stat{type: :regular}} -> :file
        {:ok, %File.Stat{type: :symlink}} -> :symlink
        _ -> nil
      end

    if kind do
      [%{name: name, kind: kind, relative_path: relative_to(path, root)}]
    else
      []
    end
  end

  defp relative_to(path, root) do
    prefix = root <> "/"

    cond do
      path == root -> ""
      String.starts_with?(path, prefix) -> String.replace_prefix(path, prefix, "")
      true -> Path.basename(path)
    end
  end

  defp image_mime(".jpg"), do: "image/jpeg"
  defp image_mime(".jpeg"), do: "image/jpeg"
  defp image_mime(".gif"), do: "image/gif"
  defp image_mime(".webp"), do: "image/webp"
  defp image_mime(_), do: "image/png"

  defp external_mime(".pdf"), do: "application/pdf"
  defp external_mime(".zip"), do: "application/zip"
  defp external_mime(_), do: "application/octet-stream"

  defp text_mime(".md"), do: "text/markdown"
  defp text_mime(".markdown"), do: "text/markdown"
  defp text_mime(".json"), do: "application/json"
  defp text_mime(".csv"), do: "text/csv"
  defp text_mime(ext) when ext in [".html", ".htm"], do: "text/html"
  defp text_mime(ext) when ext in @text_exts, do: "text/plain"
  defp text_mime(_), do: "text/plain"
end
