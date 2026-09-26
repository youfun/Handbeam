defmodule Handbeam.Preview.Files do
  @moduledoc """
  Serve only files inside a registered preview root.

  Rejects path traversal and symlink escape. Direct file responses carry
  CSP sandbox so skipping PreviewShell still cannot inherit workbench origin.
  """

  @csp "sandbox allow-scripts"

  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(root, rel) when is_binary(root) and is_binary(rel) do
    root = Path.expand(root)
    rel = normalize_rel(rel)
    candidate = Path.expand(Path.join(root, rel))
    resolve_existing(root, candidate)
  end

  def resolve(_root, _rel), do: {:error, :invalid_path}

  @spec content_type(String.t()) :: String.t()
  def content_type(path) do
    case Path.extname(path) do
      ".html" -> "text/html; charset=utf-8"
      ".htm" -> "text/html; charset=utf-8"
      ".css" -> "text/css; charset=utf-8"
      ".js" -> "text/javascript; charset=utf-8"
      ".json" -> "application/json; charset=utf-8"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".txt" -> "text/plain; charset=utf-8"
      _ -> "application/octet-stream"
    end
  end

  @spec csp() :: String.t()
  def csp, do: @csp

  defp resolve_existing(root, candidate) do
    with :ok <- inside?(root, candidate),
         {:ok, stat} <- File.lstat(candidate) do
      case stat.type do
        :directory ->
          resolve_existing(root, Path.join(candidate, "index.html"))

        :regular ->
          {:ok, candidate}

        :symlink ->
          case File.read_link(candidate) do
            {:ok, target} ->
              dest = Path.expand(target, Path.dirname(candidate))
              resolve_existing(root, dest)

            _ ->
              {:error, :not_found}
          end

        _ ->
          {:error, :unsupported}
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      other -> other
    end
  end

  defp normalize_rel(""), do: "index.html"

  defp normalize_rel(rel) do
    rel
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
  end

  defp inside?(root, path) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, :not_found}
    end
  end
end
