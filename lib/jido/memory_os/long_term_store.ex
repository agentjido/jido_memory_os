defmodule Jido.MemoryOS.LongTermStore do
  @moduledoc """
  Behavior contract for pluggable long-term memory backends.

  The `:long` tier is always routed through this behavior. By default,
  MemoryOS uses `Jido.MemoryOS.LongTermStore.ETS`, and applications can
  override it with Postgres/Redis/custom implementations.

  Built-in backends:
  - `Jido.MemoryOS.LongTermStore.ETS`
  - `Jido.MemoryOS.LongTermStore.Postgres`

  The callback `opts` include resolved runtime context keys such as:
  - `:namespace`
  - `:store`
  - `:tier`
  - `:correlation_id`
  - `:now`
  - `:config`
  """

  alias Jido.Memory.Query
  alias Jido.Memory.Record

  @type target :: map() | struct()

  @callback remember(target(), map() | keyword(), keyword()) ::
              {:ok, Record.t()} | {:error, term()}

  @callback get(target(), String.t(), keyword()) ::
              {:ok, Record.t()} | {:error, term()}

  @callback recall(target(), map() | keyword() | Query.t(), keyword()) ::
              {:ok, [Record.t()]} | {:error, term()}

  @callback forget(target(), String.t(), keyword()) ::
              {:ok, boolean()} | {:error, term()}

  @callback prune(target(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, term()}
end
