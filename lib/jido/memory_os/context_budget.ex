defmodule Jido.MemoryOS.ContextBudget do
  @moduledoc """
  Dynamic context token budget computation for memory retrieval.

  Early in a conversation the model has plenty of context window available,
  so we can afford a larger memory budget. As the conversation grows, the
  budget shrinks to leave room for accumulated history and tool results.

  ## Usage

  Pass `dynamic/1` as the `context_token_budget` in MemoryOS plugin config:

      {Jido.MemoryOS.Plugin, %{
        context_token_budget: &Jido.MemoryOS.ContextBudget.dynamic/1,
        ...
      }}

  Or use a static integer for a fixed budget:

      {Jido.MemoryOS.Plugin, %{context_token_budget: 4_000}}

  ## Custom Budget Functions

  Any function with the signature `(keyword()) -> non_neg_integer()` works.
  The keyword list contains:

    * `:turn_count` — number of user messages processed (from agent state)
    * `:namespace` — the memory namespace
    * `:tier` — the default memory tier

  ## Default Budget Curve

  The default `dynamic/1` function uses:
  - ~300 tokens per turn for history growth estimate
  - 2,000 tokens reserved for system prompt
  - 128,000 token model context window
  - Budget = min(8,000, max(1,000, available / 4))

  This yields ~8,000 tokens for early turns, tapering to ~1,000 for very long conversations.
  """

  @doc """
  Computes a dynamic context token budget based on conversation length.

  Accepts a keyword list with `:turn_count` (defaults to 0).
  """
  @spec dynamic(keyword()) :: non_neg_integer()
  def dynamic(opts \\ []) do
    turn_count = Keyword.get(opts, :turn_count, 0)
    compute(turn_count)
  end

  @doc """
  Resolves a budget value that may be a static integer or a function.

  When `budget` is:
  - an integer: returned as-is
  - a function/1: called with `opts`
  - `nil`: falls back to `default` (default: 4,000)
  """
  @spec resolve(term(), keyword(), non_neg_integer()) :: non_neg_integer()
  def resolve(budget, opts \\ [], default \\ 4_000)
  def resolve(nil, _opts, default), do: default
  def resolve(budget, _opts, _default) when is_integer(budget), do: budget
  def resolve(budget, opts, _default) when is_function(budget, 1), do: budget.(opts)
  def resolve(_budget, _opts, default), do: default

  @spec compute(non_neg_integer()) :: non_neg_integer()
  defp compute(turn_count) do
    history_tokens_estimate = turn_count * 300
    system_tokens = 2_000
    model_context = 128_000
    available = model_context - system_tokens - history_tokens_estimate
    min(8_000, max(1_000, div(available, 4)))
  end
end
