defmodule Jido.MemoryOS.Retrieval.SemanticProvider.Embedding do
  @moduledoc """
  Generic embedding-based semantic provider.

  Computes cosine similarity between a query embedding and candidate embeddings.
  Accepts an `embed_fn` via opts — no external dependency on any specific
  embedding API. Applications provide their own embedding function.

  ## Configuration

      # In retrieval opts or query semantic_provider config:
      semantic_provider: Jido.MemoryOS.Retrieval.SemanticProvider.Embedding

      # Required opt:
      embed_fn: fn texts -> {:ok, [vector]} | {:error, reason} end

      # Optional opt:
      embedding_store: {MyApp.EmbeddingStore, [opts]}

  The `embed_fn` receives a list of strings and returns a list of float vectors
  (one per input string). All vectors must have the same dimensionality.

  Candidates whose `record.embedding` is already set will use the cached vector
  instead of calling `embed_fn`, minimizing API calls.
  """

  @behaviour Jido.MemoryOS.Retrieval.SemanticProvider

  alias Jido.MemoryOS.Query
  alias Jido.MemoryOS.Retrieval.Candidate

  @impl true
  @spec score(Query.t(), [map()], keyword()) ::
          {:ok, %{optional(String.t()) => number()}} | {:error, term()}
  def score(%Query{} = query, candidates, opts) do
    case Keyword.get(opts, :embed_fn) do
      nil ->
        {:error, :embed_fn_not_configured}

      embed_fn when is_function(embed_fn, 1) ->
        do_score(query, candidates, embed_fn, opts)
    end
  end

  @spec do_score(Query.t(), [map()], function(), keyword()) ::
          {:ok, %{optional(String.t()) => number()}} | {:error, term()}
  defp do_score(query, candidates, embed_fn, opts) do
    query_text = query.query_text || query.text_contains || ""

    if String.trim(query_text) == "" do
      # No query text — return neutral scores
      scores =
        candidates
        |> Enum.reduce(%{}, fn candidate, acc ->
          key = candidate_key(candidate)
          Map.put(acc, key, 0.5)
        end)

      {:ok, scores}
    else
      score_with_embeddings(query_text, candidates, embed_fn, opts)
    end
  end

  @spec score_with_embeddings(String.t(), [map()], function(), keyword()) ::
          {:ok, %{optional(String.t()) => number()}} | {:error, term()}
  defp score_with_embeddings(query_text, candidates, embed_fn, opts) do
    embedding_store = Keyword.get(opts, :embedding_store)

    # Partition candidates: those with cached embeddings vs those needing embedding
    {cached, need_embed} = partition_by_embedding(candidates, embedding_store)

    # Build the list of texts to embed: query + uncached candidates
    texts_to_embed = [query_text | Enum.map(need_embed, &candidate_text/1)]

    case embed_fn.(texts_to_embed) do
      {:ok, vectors} when is_list(vectors) and length(vectors) == length(texts_to_embed) ->
        [query_vector | candidate_vectors] = vectors

        # Store newly computed embeddings if embedding_store is configured
        maybe_store_embeddings(embedding_store, need_embed, candidate_vectors)

        # Build score map from cached + newly embedded candidates
        scores =
          build_scores(query_vector, cached, need_embed, candidate_vectors)

        {:ok, scores}

      {:ok, vectors} when is_list(vectors) ->
        {:error, {:embedding_dimension_mismatch, length(texts_to_embed), length(vectors)}}

      {:error, reason} ->
        {:error, {:embed_fn_failed, reason}}
    end
  end

  @spec partition_by_embedding([map()], term()) :: {[{map(), [float()]}], [map()]}
  defp partition_by_embedding(candidates, embedding_store) do
    # First check record.embedding on each candidate
    {with_embedding, without} =
      Enum.split_with(candidates, fn candidate ->
        embedding = get_in(candidate, [:record, :embedding])
        is_list(embedding) and embedding != []
      end)

    cached =
      Enum.map(with_embedding, fn candidate ->
        {candidate, candidate.record.embedding}
      end)

    # If embedding_store is configured, try to fetch embeddings for those without
    {store_cached, still_need} =
      case embedding_store do
        {store_mod, store_opts} when is_atom(store_mod) ->
          fetch_from_store(store_mod, store_opts, without)

        _ ->
          {[], without}
      end

    {cached ++ store_cached, still_need}
  end

  @spec fetch_from_store(module(), keyword(), [map()]) :: {[{map(), [float()]}], [map()]}
  defp fetch_from_store(store_mod, store_opts, candidates) do
    if candidates == [] do
      {[], []}
    else
      # Group by namespace for batched retrieval
      by_namespace = Enum.group_by(candidates, & &1.namespace)

      found_map =
        Enum.reduce(by_namespace, %{}, fn {namespace, ns_candidates}, acc ->
          record_ids = Enum.map(ns_candidates, & &1.id)

          case store_mod.get_embeddings(namespace, record_ids, store_opts) do
            {:ok, embeddings} -> Map.merge(acc, embeddings)
            {:error, _} -> acc
          end
        end)

      {cached, still_need} =
        Enum.split_with(candidates, fn c -> Map.has_key?(found_map, c.id) end)

      store_cached = Enum.map(cached, fn c -> {c, Map.fetch!(found_map, c.id)} end)
      {store_cached, still_need}
    end
  end

  @spec maybe_store_embeddings(term(), [map()], [[float()]]) :: :ok
  defp maybe_store_embeddings(nil, _candidates, _vectors), do: :ok
  defp maybe_store_embeddings(_store, [], _vectors), do: :ok

  defp maybe_store_embeddings({store_mod, store_opts}, candidates, vectors) do
    # Group by namespace for batched storage
    pairs = Enum.zip(candidates, vectors)
    by_namespace = Enum.group_by(pairs, fn {c, _v} -> c.namespace end)

    Enum.each(by_namespace, fn {namespace, ns_pairs} ->
      records = Enum.map(ns_pairs, fn {c, v} -> {c.id, v} end)

      # Fire and forget — don't block scoring
      spawn(fn -> store_mod.store_embeddings(namespace, records, store_opts) end)
    end)

    :ok
  end

  @spec build_scores([float()], [{map(), [float()]}], [map()], [[float()]]) ::
          %{optional(String.t()) => number()}
  defp build_scores(query_vector, cached_pairs, uncached_candidates, uncached_vectors) do
    cached_scores =
      Enum.reduce(cached_pairs, %{}, fn {candidate, vector}, acc ->
        score = cosine_similarity(query_vector, vector)
        Map.put(acc, candidate_key(candidate), score)
      end)

    uncached_scores =
      uncached_candidates
      |> Enum.zip(uncached_vectors)
      |> Enum.reduce(%{}, fn {candidate, vector}, acc ->
        score = cosine_similarity(query_vector, vector)
        Map.put(acc, candidate_key(candidate), score)
      end)

    Map.merge(cached_scores, uncached_scores)
  end

  @spec cosine_similarity([float()], [float()]) :: float()
  defp cosine_similarity(a, b) when length(a) == length(b) do
    {dot, norm_a, norm_b} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {ai, bi}, {dot, na, nb} ->
        {dot + ai * bi, na + ai * ai, nb + bi * bi}
      end)

    denominator = :math.sqrt(norm_a) * :math.sqrt(norm_b)

    if denominator == 0.0 do
      0.0
    else
      # Clamp to [0, 1] — embeddings from common providers are often normalized,
      # but rounding errors can push slightly outside bounds
      clamp(dot / denominator, 0.0, 1.0)
    end
  end

  defp cosine_similarity(_a, _b), do: 0.0

  @spec candidate_key(map()) :: String.t()
  defp candidate_key(candidate) do
    candidate.key || Candidate.candidate_key(candidate.namespace, candidate.id)
  end

  @spec candidate_text(map()) :: String.t()
  defp candidate_text(candidate) do
    candidate.normalized_text || candidate.text || ""
  end

  @spec clamp(number(), number(), number()) :: number()
  defp clamp(value, min_val, _max_val) when value < min_val, do: min_val
  defp clamp(value, _min_val, max_val) when value > max_val, do: max_val
  defp clamp(value, _min_val, _max_val), do: value
end
