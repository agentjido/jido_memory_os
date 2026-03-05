defmodule Jido.MemoryOS.EmbeddingStore do
  @moduledoc """
  Behaviour for dedicated embedding vector storage.

  Separates embedding vectors from the main record store, allowing applications
  to use specialized vector databases (pgvector, Milvus, Pinecone, etc.) while
  keeping the record store simple.

  Built-in implementations:
  - `Jido.MemoryOS.EmbeddingStore.ETS` — in-memory, for tests and development

  ## Usage

  Configure in plugin or retrieval config:

      embedding_store: {MyApp.EmbeddingStore.Pgvector, [repo: MyApp.VectorsRepo]}
  """

  @type record_id :: String.t()
  @type vector :: [float()]
  @type namespace :: String.t()

  @callback store_embeddings(namespace(), [{record_id(), vector()}], keyword()) ::
              :ok | {:error, term()}

  @callback get_embeddings(namespace(), [record_id()], keyword()) ::
              {:ok, %{record_id() => vector()}} | {:error, term()}

  @callback nearest_neighbors(namespace(), vector(), pos_integer(), keyword()) ::
              {:ok, [{record_id(), float()}]} | {:error, term()}

  @callback delete_embeddings(namespace(), [record_id()], keyword()) ::
              :ok | {:error, term()}
end
