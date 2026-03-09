defmodule Jido.MemoryOS.Retrieval.SemanticProvider.Lexical do
  @moduledoc """
  Zero-dependency lexical semantic provider fallback.

  It approximates semantic similarity through token overlap and phrase matching.
  """

  @behaviour Jido.MemoryOS.Retrieval.SemanticProvider

  alias Jido.MemoryOS.Query
  alias Jido.MemoryOS.Retrieval.Candidate

  @impl true
  @spec score(Query.t(), [map()], keyword()) :: {:ok, %{optional(String.t()) => number()}}
  def score(%Query{} = query, candidates, _opts) do
    scoring_text = query.query_text || query.text_contains
    query_tokens = tokenize(scoring_text)

    scores =
      candidates
      |> Enum.reduce(%{}, fn candidate, acc ->
        key = candidate.key || Candidate.candidate_key(candidate.namespace, candidate.id)
        score = lexical_similarity(candidate, scoring_text, query_tokens)
        Map.put(acc, key, score)
      end)

    {:ok, scores}
  end

  @spec lexical_similarity(map(), String.t() | nil, [String.t()]) :: number()
  defp lexical_similarity(_candidate, nil, _query_tokens), do: 0.5

  defp lexical_similarity(candidate, query_text, query_tokens) when is_map(candidate) do
    candidate_tokens = tokenize(candidate.normalized_text)
    query_lookup = token_lookup(query_tokens)
    unique_candidate_tokens = Enum.uniq(candidate_tokens)

    overlap_score =
      if query_tokens == [] do
        0.0
      else
        overlap_count =
          Enum.count(unique_candidate_tokens, fn token ->
            Map.has_key?(query_lookup, token)
          end)

        overlap_count / length(query_tokens)
      end

    phrase_match =
      if is_binary(query_text) and query_text != "" and
           is_binary(candidate.normalized_text) and
           String.contains?(candidate.normalized_text, String.downcase(query_text)) do
        1.0
      else
        0.0
      end

    clamp(Float.round(0.65 * overlap_score + 0.35 * phrase_match, 4), 0.0, 1.0)
  rescue
    _ -> 0.5
  end

  @spec tokenize(String.t() | nil) :: [String.t()]
  defp tokenize(nil), do: []

  defp tokenize(text) when is_binary(text) do
    # Ensure valid UTF-8 before passing to Unicode regex — invalid bytes crash :re.run
    safe_text =
      if String.valid?(text) do
        text
      else
        text
        |> :unicode.characters_to_binary(:utf8, :utf8)
        |> case do
          {:error, valid, _rest} -> valid
          {:incomplete, valid, _rest} -> valid
          bin when is_binary(bin) -> bin
        end
      end

    safe_text
    |> String.downcase()
    |> Regex.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @spec token_lookup([String.t()]) :: %{optional(String.t()) => true}
  defp token_lookup(tokens), do: Map.new(tokens, &{&1, true})

  @spec clamp(number(), number(), number()) :: number()
  defp clamp(value, min_value, _max_value) when value < min_value, do: min_value
  defp clamp(value, _min_value, max_value) when value > max_value, do: max_value
  defp clamp(value, _min_value, _max_value), do: value
end
