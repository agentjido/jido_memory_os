if Code.ensure_loaded?(Ecto.Query) and Code.ensure_loaded?(Pgvector) do
  defmodule Jido.MemoryOS.EmbeddingStore.Pgvector do
    @moduledoc """
    Pgvector-backed embedding store for MemoryOS.

    Implements `Jido.MemoryOS.EmbeddingStore` using Ecto + pgvector with
    HNSW cosine similarity index.

    ## Required Dependencies

    Add to your `mix.exs`:

        {:ecto_sql, "~> 3.10"},
        {:pgvector, "~> 0.3"},
        {:postgrex, "~> 0.20"}

    ## Configuration

        embedding_store: {Jido.MemoryOS.EmbeddingStore.Pgvector,
          repo: MyApp.VectorsRepo,
          schema: MyApp.MemoryEmbedding}

    ## Schema Requirements

    The schema module must define at minimum:

        defmodule MyApp.MemoryEmbedding do
          use Ecto.Schema

          @primary_key false
          schema "memory_embeddings" do
            field :namespace, :string
            field :record_id, :string
            field :embedding, Pgvector.Ecto.Vector
            timestamps(type: :utc_datetime_usec)
          end
        end

    ## Ecto Migration

        defmodule MyApp.Repo.Migrations.CreateMemoryEmbeddings do
          use Ecto.Migration

          def change do
            execute "CREATE EXTENSION IF NOT EXISTS vector"

            create table(:memory_embeddings, primary_key: false) do
              add :namespace, :string, null: false
              add :record_id, :string, null: false
              add :embedding, :vector, size: 1536
              timestamps(type: :utc_datetime_usec)
            end

            create unique_index(:memory_embeddings, [:namespace, :record_id])
            create index(:memory_embeddings, [:namespace])
          end
        end
    """

    @behaviour Jido.MemoryOS.EmbeddingStore

    import Ecto.Query
    import Pgvector.Ecto.Query

    @impl true
    @spec store_embeddings(String.t(), [{String.t(), [float()]}], keyword()) ::
            :ok | {:error, term()}
    def store_embeddings(_namespace, [], _opts), do: :ok

    def store_embeddings(namespace, records, opts) do
      repo = repo!(opts)
      schema = schema!(opts)
      now = DateTime.utc_now()

      entries =
        Enum.map(records, fn {record_id, vector} ->
          %{
            namespace: namespace,
            record_id: record_id,
            embedding: Pgvector.new(vector),
            inserted_at: now,
            updated_at: now
          }
        end)

      repo.insert_all(schema, entries,
        on_conflict: {:replace, [:embedding, :updated_at]},
        conflict_target: [:namespace, :record_id]
      )

      :ok
    rescue
      e -> {:error, {:store_embeddings_failed, Exception.message(e)}}
    end

    @impl true
    @spec get_embeddings(String.t(), [String.t()], keyword()) ::
            {:ok, %{String.t() => [float()]}} | {:error, term()}
    def get_embeddings(_namespace, [], _opts), do: {:ok, %{}}

    def get_embeddings(namespace, record_ids, opts) do
      repo = repo!(opts)
      schema = schema!(opts)

      results =
        schema
        |> where([e], e.namespace == ^namespace and e.record_id in ^record_ids)
        |> select([e], {e.record_id, e.embedding})
        |> repo.all()
        |> Map.new(fn {id, vec} -> {id, Pgvector.to_list(vec)} end)

      {:ok, results}
    rescue
      e -> {:error, {:get_embeddings_failed, Exception.message(e)}}
    end

    @impl true
    @spec delete_embeddings(String.t(), [String.t()], keyword()) ::
            :ok | {:error, term()}
    def delete_embeddings(_namespace, [], _opts), do: :ok

    def delete_embeddings(namespace, record_ids, opts) do
      repo = repo!(opts)
      schema = schema!(opts)

      schema
      |> where([e], e.namespace == ^namespace and e.record_id in ^record_ids)
      |> repo.delete_all()

      :ok
    rescue
      e -> {:error, {:delete_embeddings_failed, Exception.message(e)}}
    end

    @impl true
    @spec nearest_neighbors(String.t(), [float()], pos_integer(), keyword()) ::
            {:ok, [{String.t(), float()}]} | {:error, term()}
    def nearest_neighbors(_namespace, _vector, 0, _opts), do: {:ok, []}

    def nearest_neighbors(namespace, vector, limit, opts) do
      repo = repo!(opts)
      schema = schema!(opts)
      pgvec = Pgvector.new(vector)

      results =
        schema
        |> where([e], e.namespace == ^namespace)
        |> order_by([e], asc: cosine_distance(e.embedding, ^pgvec))
        |> limit(^limit)
        |> select([e], {e.record_id, cosine_distance(e.embedding, ^pgvec)})
        |> repo.all()
        |> Enum.map(fn {id, distance} -> {id, 1.0 - distance} end)

      {:ok, results}
    rescue
      e -> {:error, {:nearest_neighbors_failed, Exception.message(e)}}
    end

    @spec repo!(keyword()) :: module()
    defp repo!(opts), do: Keyword.fetch!(opts, :repo)

    @spec schema!(keyword()) :: module()
    defp schema!(opts), do: Keyword.fetch!(opts, :schema)
  end
end
