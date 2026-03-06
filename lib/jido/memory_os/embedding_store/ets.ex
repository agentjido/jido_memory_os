defmodule Jido.MemoryOS.EmbeddingStore.ETS do
  @moduledoc """
  In-memory ETS-backed embedding store for tests and development.

  Uses brute-force cosine similarity for nearest neighbor search.
  Not suitable for production with large datasets — use a dedicated
  vector database (pgvector, etc.) instead.

  ## Options

  - `:table` — ETS table name (default: `:jido_memory_os_embeddings`)
  """

  @behaviour Jido.MemoryOS.EmbeddingStore

  @default_table :jido_memory_os_embeddings

  @impl true
  @spec store_embeddings(String.t(), [{String.t(), [float()]}], keyword()) ::
          :ok | {:error, term()}
  def store_embeddings(namespace, records, opts \\ []) do
    table = ensure_table(opts)

    Enum.each(records, fn {record_id, vector} ->
      :ets.insert(table, {{namespace, record_id}, vector})
    end)

    :ok
  end

  @impl true
  @spec get_embeddings(String.t(), [String.t()], keyword()) ::
          {:ok, %{String.t() => [float()]}} | {:error, term()}
  def get_embeddings(namespace, record_ids, opts \\ []) do
    table = ensure_table(opts)

    embeddings =
      Enum.reduce(record_ids, %{}, fn record_id, acc ->
        case :ets.lookup(table, {namespace, record_id}) do
          [{{^namespace, ^record_id}, vector}] -> Map.put(acc, record_id, vector)
          [] -> acc
        end
      end)

    {:ok, embeddings}
  end

  @impl true
  @spec nearest_neighbors(String.t(), [float()], pos_integer(), keyword()) ::
          {:ok, [{String.t(), float()}]} | {:error, term()}
  def nearest_neighbors(namespace, query_vector, limit, opts \\ []) do
    table = ensure_table(opts)

    # Brute-force scan all embeddings in the namespace
    results =
      :ets.foldl(
        fn
          {{^namespace, record_id}, vector}, acc ->
            score = cosine_similarity(query_vector, vector)
            [{record_id, score} | acc]

          _other, acc ->
            acc
        end,
        [],
        table
      )
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  @impl true
  @spec delete_embeddings(String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def delete_embeddings(namespace, record_ids, opts \\ [])
  def delete_embeddings(_namespace, [], _opts), do: :ok

  def delete_embeddings(namespace, record_ids, opts) do
    table = ensure_table(opts)

    Enum.each(record_ids, fn record_id ->
      :ets.delete(table, {namespace, record_id})
    end)

    :ok
  end

  @spec ensure_table(keyword()) :: atom()
  defp ensure_table(opts) do
    table = Keyword.get(opts, :table, @default_table)

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end

    table
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
      max(0.0, min(1.0, dot / denominator))
    end
  end

  defp cosine_similarity(_a, _b), do: 0.0
end
