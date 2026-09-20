defmodule Handbeam.WebFetch do
  @moduledoc """
  Bounded public-web GET and local document extraction. Each redirect resolves
  and validates its destination again, then connects directly to that IP.
  No browser, API key, proxy or external extraction service is involved.
  """

  alias Handbeam.WebFetch.{Address, Document, HTTP}

  @doc "Fetch text from a public HTTP(S) URL. Options inject resolver/transport for tests."
  def fetch(url, max_chars \\ 20_000, opts \\ []) do
    if is_integer(max_chars) and max_chars in 1..50_000 do
      deadline = System.monotonic_time(:millisecond) + 30_000

      with {:ok, uri} <- Address.parse(url),
           {:ok, final_uri, response} <- follow(uri, deadline, 3, opts),
           {:ok, document} <-
             Document.extract(response.body, response.headers, final_uri, max_chars) do
        {:ok,
         Map.merge(document, %{
           requested_url: URI.to_string(uri),
           final_url: URI.to_string(final_uri),
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
         })}
      end
    else
      {:error, "max_chars must be an integer between 1 and 50000"}
    end
  end

  defp follow(uri, deadline, redirects, opts) do
    resolve = Keyword.get(opts, :resolve, &Address.resolve/2)
    request = Keyword.get(opts, :request, &HTTP.get/3)

    with {:ok, ips} <- resolve.(uri.host, deadline),
         {:ok, ip} <- Address.select_public(ips),
         {:ok, response} <- request.(uri, ip, deadline) do
      cond do
        response.status in [301, 302, 303, 307, 308] ->
          redirect(uri, response.headers, deadline, redirects, opts)

        response.status in 200..299 ->
          {:ok, uri, response}

        true ->
          {:error, "HTTP status #{response.status}"}
      end
    end
  end

  defp redirect(_uri, _headers, _deadline, 0, _opts),
    do: {:error, "Too many redirects (maximum 3)"}

  defp redirect(uri, headers, deadline, redirects, opts) do
    with {"location", location} <- List.keyfind(headers, "location", 0),
         {:ok, relative} <- URI.new(location),
         {:ok, target} <- Address.parse(uri |> URI.merge(relative) |> URI.to_string()) do
      follow(target, deadline, redirects - 1, opts)
    else
      _ -> {:error, "Invalid redirect destination"}
    end
  end
end
