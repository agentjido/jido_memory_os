defmodule Jido.MemoryOS.LongTermStore.ETS do
  @moduledoc """
  Default `LongTermStore` implementation backed by `Jido.Memory.Runtime`.

  This preserves existing ETS store behavior for the `:long` tier while
  exposing a stable behavior contract for custom persistent backends.
  """

  @behaviour Jido.MemoryOS.LongTermStore

  alias Jido.Memory.Query
  alias Jido.Memory.Runtime

  @impl true
  @spec remember(map() | struct(), map() | keyword(), keyword()) ::
          {:ok, Jido.Memory.Record.t()} | {:error, term()}
  def remember(target, attrs, opts) do
    with {:ok, runtime_opts} <- runtime_opts(opts) do
      Runtime.remember(target, attrs, runtime_opts)
    end
  end

  @impl true
  @spec get(map() | struct(), String.t(), keyword()) ::
          {:ok, Jido.Memory.Record.t()} | {:error, term()}
  def get(target, id, opts) do
    with {:ok, runtime_opts} <- runtime_opts(opts) do
      Runtime.get(target, id, runtime_opts)
    end
  end

  @impl true
  @spec recall(map() | struct(), map() | keyword() | Query.t(), keyword()) ::
          {:ok, [Jido.Memory.Record.t()]} | {:error, term()}
  def recall(target, query, opts) do
    Runtime.recall(target, with_query_context(query, opts))
  end

  @impl true
  @spec forget(map() | struct(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def forget(target, id, opts) do
    with {:ok, runtime_opts} <- runtime_opts(opts) do
      Runtime.forget(target, id, runtime_opts)
    end
  end

  @impl true
  @spec prune(map() | struct(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune(target, opts) do
    with {:ok, runtime_opts} <- runtime_opts(opts) do
      Runtime.prune_expired(target, runtime_opts)
    end
  end

  @spec with_query_context(map() | keyword() | Query.t(), keyword()) ::
          map() | keyword() | Query.t()
  defp with_query_context(%Query{} = query, opts) do
    query
    |> Map.from_struct()
    |> with_query_context(opts)
  end

  defp with_query_context(query, opts) when is_map(query) do
    query
    |> Map.put_new(:namespace, Keyword.get(opts, :namespace))
    |> Map.put_new(:store, Keyword.get(opts, :store))
  end

  defp with_query_context(query, opts) when is_list(query) do
    if Keyword.keyword?(query) do
      query
      |> Map.new()
      |> with_query_context(opts)
    else
      query
    end
  end

  defp with_query_context(query, _opts), do: query

  @spec runtime_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  defp runtime_opts(opts) do
    namespace = Keyword.get(opts, :namespace)
    store = Keyword.get(opts, :store)

    cond do
      is_nil(namespace) -> {:error, {:missing_long_term_backend_option, :namespace}}
      is_nil(store) -> {:error, {:missing_long_term_backend_option, :store}}
      true -> {:ok, [namespace: namespace, store: store]}
    end
  end
end
