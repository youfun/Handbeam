defmodule ExFff.Matcher do
  @moduledoc """
  Fuzzy path matching engine for ExFff.

  Provides tokenization of file paths into trigrams and tiered scoring.
  Match quality (exact name, filename, path, fuzzy) outranks frecency.
  Frecency decays with a 7-day half-life and only reorders a tier.
  """

  # Half-life decay replaces the old unbounded `old * 0.9 + 100` accumulator.
  @half_life_seconds 7 * 24 * 60 * 60
  @frecency_cap 32.0
  @frecency_boost 1.0
  @frecency_weight 0.2
  @git_boost 0.05
  @similarity_floor 0.5
  @tier_gap 10.0
  # Reference used only to compress pre-decay persisted scores into the cap.
  @legacy_frecency_span 1000.0

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
  Advance a frecency score after an access.

  The previous score decays with a 7-day half-life over `elapsed_seconds`,
  then a unit boost is added. The result is capped so repeated touches cannot
  grow without bound. `elapsed_seconds` defaults to `0` (a burst of touches).
  """
  @spec compute_frecency(number(), number()) :: float()
  def compute_frecency(old_score, elapsed_seconds \\ 0)
      when is_number(old_score) and is_number(elapsed_seconds) do
    elapsed = max(elapsed_seconds, 0)
    decayed = max(old_score, 0) * :math.pow(0.5, elapsed / @half_life_seconds)
    min(decayed + @frecency_boost, @frecency_cap)
  end

  @doc """
  Map a persisted frecency value onto the bounded scale.

  Scores already within the cap are kept. Older unbounded accumulators
  (`old * 0.9 + 100`, often hundreds) are log-compressed so their order
  survives without dominating the new scale.
  """
  @spec normalize_stored_frecency(number()) :: float()
  def normalize_stored_frecency(score) when is_number(score) do
    score = max(score * 1.0, 0.0)

    if score <= @frecency_cap do
      score
    else
      (:math.log(1 + score) / :math.log(1 + @legacy_frecency_span) * @frecency_cap)
      |> min(@frecency_cap)
      |> max(0.0)
    end
  end

  @doc false
  @spec decay_frecency(number(), number()) :: float()
  def decay_frecency(score, elapsed_seconds)
      when is_number(score) and is_number(elapsed_seconds) do
    elapsed = max(elapsed_seconds, 0)
    max(score, 0) * :math.pow(0.5, elapsed / @half_life_seconds)
  end

  @doc """
  Match query against the index tables and return scored results.

  Returns a list of `%{path: String.t(), score: float()}` sorted by
  descending score.

  Arguments:
  - `query` — `%ExFff.Query{}`
  - `files_tab` — ETS table id for Files
  - `trigram_tab` — ETS table id for Trigrams
  - `frecency_tab` — ETS table id for Frecency
  """
  @spec match(ExFff.Query.t(), :ets.tid(), :ets.tid(), :ets.tid()) :: [
          %{path: String.t(), score: float()}
        ]
  def match(query, files_tab, trigram_tab, frecency_tab) do
    do_match(query, files_tab, trigram_tab, frecency_tab, nil)
  end

  @doc false
  @spec match(ExFff.Query.t(), :ets.tid(), :ets.tid(), :ets.tid(), :ets.tid() | nil) :: [map()]
  def match(query, files_tab, trigram_tab, frecency_tab, git_tab) do
    do_match(query, files_tab, trigram_tab, frecency_tab, git_tab)
  end

  defp do_match(query, files_tab, trigram_tab, frecency_tab, git_tab) do
    now = System.system_time(:second)

    prepared =
      query
      |> find_candidates(files_tab, trigram_tab)
      |> Enum.map(&%{path: &1})
      |> apply_filters(query)
      |> Enum.map(&prepare_candidate(&1, query, frecency_tab, git_tab, now))
      |> Enum.reject(&below_similarity_floor?(&1, query))

    max_freq = prepared |> Enum.map(& &1.freq) |> Enum.max(fn -> 0.0 end)

    prepared
    |> Enum.map(&finalize_score(&1, max_freq))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(query.limit)
  end

  # ── Candidate Discovery ──

  defp find_candidates(%ExFff.Query{terms: [], globs: globs}, files_tab, trigram_tab)
       when globs != [] do
    case all_indexed_paths(files_tab) do
      [] -> all_trigram_paths(trigram_tab)
      paths -> paths
    end
  end

  defp find_candidates(%ExFff.Query{terms: []}, _files_tab, trigram_tab) do
    # No search terms — extension filters still scan the trigram inventory.
    all_trigram_paths(trigram_tab)
  end

  defp find_candidates(%ExFff.Query{terms: terms}, _files_tab, trigram_tab) do
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

  defp all_trigram_paths(trigram_tab) do
    trigram_tab
    |> :ets.tab2list()
    |> Enum.map(fn {_trigram, path} -> path end)
    |> Enum.uniq()
  end

  defp all_indexed_paths(files_tab) do
    case :ets.info(files_tab) do
      :undefined ->
        []

      _ ->
        :ets.foldl(fn {path, _meta}, acc -> [path | acc] end, [], files_tab)
    end
  end

  # ── Scoring ──
  #
  # Tiers (exact filename > filename prefix/contains > path contains > fuzzy)
  # are separated by `@tier_gap`, which is larger than any within-tier bonus.
  # Frecency and git status can only reorder files inside the same tier:
  #
  #     within = sim * (1 + 0.2 * norm_frec) + git_boost
  #     norm_frec = log(1 + freq) / log(1 + max_freq)

  defp prepare_candidate(%{path: path}, query, frecency_tab, git_tab, now) do
    {tier, sim} = classify_match(path, query.terms)

    %{
      path: path,
      tier: tier,
      sim: sim,
      freq: effective_frecency(path, frecency_tab, now),
      git_status: fetch_git_status(path, git_tab)
    }
  end

  defp below_similarity_floor?(_candidate, %{terms: []}), do: false

  defp below_similarity_floor?(%{sim: sim}, _query), do: sim < @similarity_floor

  defp finalize_score(candidate, max_freq) do
    norm = if max_freq > 0, do: :math.log(1 + candidate.freq) / :math.log(1 + max_freq), else: 0.0
    within = candidate.sim * (1 + @frecency_weight * norm) + git_boost(candidate.git_status)
    score = tier_rank(candidate.tier) * @tier_gap + within
    %{path: candidate.path, score: score, git_status: candidate.git_status}
  end

  defp classify_match(_path, []), do: {:fuzzy, 1.0}

  defp classify_match(path, terms) do
    matches = Enum.map(terms, &term_match(path, &1))
    tier = matches |> Enum.map(&elem(&1, 0)) |> Enum.min_by(&tier_rank/1)
    sim = matches |> Enum.map(&elem(&1, 1)) |> average()
    {tier, sim}
  end

  defp term_match(path, term) do
    needle = safe_downcase(term)
    basename = path |> Path.basename() |> safe_downcase()
    normalized_path = safe_downcase(path)
    sim = similarity_to_term(normalized_path, needle)

    cond do
      needle != "" and basename == needle ->
        {:exact, max(sim, 1.0)}

      needle != "" and
          (String.starts_with?(basename, needle) or String.contains?(basename, needle)) ->
        {:filename, max(sim, 0.9)}

      needle != "" and String.contains?(normalized_path, needle) ->
        {:path, max(sim, 0.75)}

      true ->
        {:fuzzy, sim}
    end
  end

  defp tier_rank(:exact), do: 3
  defp tier_rank(:filename), do: 2
  defp tier_rank(:path), do: 1
  defp tier_rank(:fuzzy), do: 0

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp fetch_git_status(_path, nil), do: nil

  defp fetch_git_status(path, git_tab) do
    case :ets.lookup(git_tab, path) do
      [{^path, status}] -> status
      [] -> nil
    end
  end

  defp git_boost(nil), do: 0.0
  defp git_boost(_status), do: @git_boost

  defp similarity_to_term(normalized_path, normalized_term) do
    # Jaro against a short path token inflates long queries (the match window
    # is half the longer string). Scale by length so only similar-length
    # tokens count as a real fuzzy hit; substring and tier floors cover
    # prefix/contains matches.
    substring_bonus =
      if normalized_term != "" and String.contains?(normalized_path, normalized_term),
        do: 0.9,
        else: 0.0

    basename_jaro =
      safe_jaro(normalized_term, Path.basename(normalized_path)) *
        length_ratio(normalized_term, Path.basename(normalized_path))

    token_jaro =
      normalized_path
      |> split_path_tokens()
      |> Enum.map(fn token ->
        safe_jaro(normalized_term, token) * length_ratio(normalized_term, token)
      end)
      |> Enum.max(fn -> 0.0 end)

    max(substring_bonus, max(basename_jaro, token_jaro))
  end

  defp length_ratio(a, b) do
    la = max(String.length(a), 1)
    lb = max(String.length(b), 1)
    min(la, lb) / max(la, lb)
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

  defp effective_frecency(path, frecency_tab, now) do
    # Frecency table: {{score, path}, touched_at | true} (ordered_set).
    # `true` is the legacy value written before timestamps existed.
    case :ets.match_object(frecency_tab, {{:_, path}, :_}) do
      [] ->
        0.0

      [{{score, _path}, meta} | _] ->
        elapsed =
          case frecency_timestamp(meta) do
            nil -> 0
            touched_at -> max(now - touched_at, 0)
          end

        decay_frecency(score, elapsed)
    end
  end

  defp frecency_timestamp(ts) when is_integer(ts), do: ts
  defp frecency_timestamp(%{touched_at: ts}) when is_integer(ts), do: ts
  defp frecency_timestamp(_meta), do: nil

  # ── Filters ──

  defp apply_filters(candidates, query) do
    candidates
    |> apply_include_patterns(query.include_patterns)
    |> apply_exclude_patterns(query.exclude_patterns)
    |> apply_globs(Map.get(query, :globs, []))
  end

  defp apply_globs(candidates, []), do: candidates

  defp apply_globs(candidates, globs) do
    Enum.filter(candidates, fn %{path: path} ->
      Enum.all?(globs, &glob_match?(&1, path))
    end)
  end

  defp glob_match?(%{regex: regex, basename?: true}, path) do
    regex_match?(regex, Path.basename(path))
  end

  defp glob_match?(%{regex: regex}, path), do: regex_match?(regex, path)

  defp regex_match?(regex, value) do
    String.valid?(value) and Regex.match?(regex, value)
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
