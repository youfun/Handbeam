defmodule ExFff.Matcher do
  @moduledoc """
  Fuzzy path matching engine for ExFff.

  Provides tokenization of file paths into trigrams and scoring
  of candidates using Jaro distance and frecency.
  """

  @decay 0.9
  @boost 100
  @similarity_weight 0.7
  @frecency_weight 0.3

  @doc """
  Tokenize a file path into unique trigrams.

  Splits on `/`, `_`, `-`, `.`, then further splits on case boundaries.
  Each resulting token of length >= 3 graphemes yields sliding-window
  trigrams over **graphemes** (not bytes), so CJK and other multi-byte
  UTF-8 characters are handled correctly.

  Returns `[]` if `path` is not a valid UTF-8 binary (so that callers
  using raw filesystem bytes never crash).

  ## Examples

      iex> ExFff.Matcher.tokenize("lib/user.ex")
      ["lib", "use", "ser"]

  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(path) when is_binary(path) do
    if String.valid?(path) do
      path
      |> String.split(~r{[/_\-\.]})
      |> Enum.flat_map(&split_camel_case/1)
      |> Enum.flat_map(&trigrams/1)
      |> Enum.uniq()
    else
      []
    end
  end

  @doc """
  Compute the frecency decay formula.

      new_score = old_score * decay + boost
  """
  @spec compute_frecency(number()) :: float()
  def compute_frecency(old_score) do
    old_score * @decay + @boost
  end

  @doc """
  Match query against the index tables and return scored results.

  Returns a list of `%{path: String.t(), score: float()}` sorted by
  descending score.

  Arguments:
  - `query` — `%ExFff.Query{}`
  - `files_tab` — ETS table atom for Files
  - `trigram_tab` — ETS table atom for Trigrams
  - `frecency_tab` — ETS table atom for Frecency
  """
  @spec match(ExFff.Query.t(), atom(), atom(), atom()) :: [%{path: String.t(), score: float()}]
  def match(query, _files_tab, trigram_tab, frecency_tab) do
    candidates = find_candidates(query, trigram_tab)

    candidates
    |> Enum.map(&score_candidate(&1, query, frecency_tab))
    |> apply_filters(query)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(query.limit)
  end

  # ── Candidate Discovery ──

  defp find_candidates(%ExFff.Query{terms: []}, trigram_tab) do
    # No search terms — return all files from trigram table
    trigram_tab
    |> :ets.tab2list()
    |> Enum.map(fn {_trigram, path} -> path end)
    |> Enum.uniq()
  end

  defp find_candidates(%ExFff.Query{terms: terms}, trigram_tab) do
    terms
    |> Enum.map(fn term ->
      set = path_set_for_term(term, trigram_tab)
      # Also add direct substring match candidates
      direct = direct_substring_matches(term, trigram_tab)
      MapSet.union(set, direct)
    end)
    |> reduce_intersection()
  end

  defp path_set_for_term(term, trigram_tab) do
    term
    |> tokenize()
    |> Enum.reduce(MapSet.new(), fn trigram, acc ->
      paths = lookup_trigram(trigram, trigram_tab)
      MapSet.union(acc, paths)
    end)
  end

  defp lookup_trigram(trigram, trigram_tab) do
    trigram_tab
    |> :ets.lookup(trigram)
    |> Enum.map(fn {_k, path} -> path end)
    |> MapSet.new()
  end

  defp direct_substring_matches(term, trigram_tab) do
    # Also find paths where the term appears as a substring of any token
    # We check by matching any trigram that contains the term as a substring.
    # `String.contains?/2` is byte-level, so it tolerates trigrams that were
    # generated from non-UTF-8-safe sources — but the term still needs to be
    # downcased safely.
    needle = safe_downcase(term)

    trigram_tab
    |> :ets.tab2list()
    |> Enum.filter(fn {trigram, _path} ->
      is_binary(trigram) and String.contains?(trigram, needle)
    end)
    |> Enum.map(fn {_trigram, path} -> path end)
    |> MapSet.new()
  end

  defp reduce_intersection([first | rest]) do
    Enum.reduce(rest, first, &MapSet.intersection/2)
  end

  defp reduce_intersection([]), do: MapSet.new()

  # ── Scoring ──

  defp score_candidate(path, query, frecency_tab) do
    sim = compute_similarity(path, query.terms)
    freq = fetch_frecency(path, frecency_tab)

    score = sim * @similarity_weight + freq * @frecency_weight

    %{path: path, score: score}
  end

  defp compute_similarity(path, terms) do
    normalized_path = safe_downcase(path)

    scores =
      Enum.map(terms, fn term ->
        normalized_term = safe_downcase(term)

        # Whole-path substring bonus: useful for CJK queries where
        # Jaro on short tokens is unreliable.
        substring_bonus =
          if normalized_term != "" and String.contains?(normalized_path, normalized_term),
            do: 0.9,
            else: 0.0

        # Score each token in the path against this query term
        tokens = split_path_tokens(normalized_path)

        token_scores =
          Enum.map(tokens, fn token ->
            safe_jaro(normalized_term, token)
          end)

        jaro = Enum.max(token_scores, fn -> 0.0 end)
        max(jaro, substring_bonus)
      end)

    if scores == [] do
      0.0
    else
      Enum.sum(scores) / length(scores)
    end
  end

  defp safe_downcase(binary) when is_binary(binary) do
    if String.valid?(binary), do: String.downcase(binary), else: binary
  end

  defp safe_jaro(a, b) when is_binary(a) and is_binary(b) do
    if String.valid?(a) and String.valid?(b) do
      String.jaro_distance(a, b)
    else
      0.0
    end
  end

  defp split_path_tokens(path) do
    String.split(path, ~r{[/_\-\.]})
  end

  defp fetch_frecency(path, frecency_tab) do
    # Frecency table: {{score, path}, true} (ordered_set)
    # Use match_object for wildcard matching on the score portion
    case :ets.match_object(frecency_tab, {{:_, path}, :_}) do
      [] -> 0.0
      [{{score, _p}, _v} | _] -> score
    end
  end

  # ── Filters ──

  defp apply_filters(candidates, query) do
    candidates
    |> apply_include_patterns(query.include_patterns)
    |> apply_exclude_patterns(query.exclude_patterns)
  end

  defp apply_include_patterns(candidates, []), do: candidates

  defp apply_include_patterns(candidates, patterns) do
    Enum.filter(candidates, fn %{path: path} ->
      Enum.any?(patterns, fn pattern ->
        String.ends_with?(String.downcase(path), String.downcase(pattern))
      end)
    end)
  end

  defp apply_exclude_patterns(candidates, []), do: candidates

  defp apply_exclude_patterns(candidates, patterns) do
    Enum.filter(candidates, fn %{path: path} ->
      not Enum.any?(patterns, fn pattern ->
        String.contains?(String.downcase(path), String.downcase(pattern))
      end)
    end)
  end

  # ── Tokenization Helpers ──

  @doc false
  def split_camel_case(""), do: []

  def split_camel_case(token) do
    token
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.split()
    |> Enum.map(&String.downcase/1)
  end

  # Grapheme-based sliding window so that multi-byte characters
  # (CJK, accented Latin, emoji, …) are never sliced in the middle and
  # never produce invalid UTF-8 binaries.
  defp trigrams(token) when is_binary(token) do
    if String.valid?(token) do
      graphemes = String.graphemes(token)

      if length(graphemes) < 3 do
        []
      else
        graphemes
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.map(&Enum.join/1)
      end
    else
      []
    end
  end
end
