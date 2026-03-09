# 08 - Agent Integration Cookbook

This guide walks through adding persistent, cross-session memory to a Jido agent from scratch. By the end you'll have an agent that:

1. Automatically captures LLM responses and tool results as memories
2. Retrieves relevant memories when a user starts a new conversation
3. Injects that context into the system prompt so the LLM actually uses it

## 1. Plugin Setup

Mount `Jido.MemoryOS.Plugin` in your agent's plugin list. The plugin manages the memory lifecycle — capture, storage, retrieval, and namespace isolation.

### Minimal Config

```elixir
plugin_config = %{
  manager: MyApp.MemoryManager,          # Your MemoryManager process name
  tier: :short,                           # Default tier for writes
  store: {Jido.Memory.Store.ETS, []},     # ETS for dev/test
  auto_capture: true,                     # Capture signals automatically
  capture_signal_patterns: [
    "ai.llm.response",
    "ai.tool.result"
  ]
}

{:ok, plugin_state} = Jido.MemoryOS.Plugin.mount(%{}, plugin_config)
```

### Full Config with All Options

```elixir
plugin_config = %{
  # Core
  manager: MyApp.MemoryManager,
  tier: :short,
  store: {Jido.Memory.Store.ETS, [table: :my_memory]},

  # Framework adapter (controls retrieval strategy)
  framework_adapter: Jido.MemoryOS.FrameworkAdapter.ToolHeavy,
  framework_adapter_opts: [default_limit: 8],

  # Auto-capture
  auto_capture: true,
  capture_signal_patterns: ["ai.llm.response", "ai.tool.result"],
  capture_rules: [
    %{pattern: "ai.llm.response", tags: ["capture:llm"], kind: :response},
    %{pattern: "ai.tool.result", tags: ["capture:tool"], kind: :event}
  ],

  # Embedding (optional — enables semantic search)
  embed_fn: &MyApp.Embeddings.embed/1,
  embedding_store: {Jido.MemoryOS.EmbeddingStore.Pgvector, [
    repo: MyApp.VectorsRepo,
    schema: MyApp.MemoryEmbedding
  ]},
  semantic_provider: Jido.MemoryOS.Retrieval.SemanticProvider.Embedding,
  context_token_budget: 4_000
}
```

### Framework Adapters

The adapter controls how memories are retrieved and ranked during `pre_turn`:

| Adapter | Best For | Description |
|---------|----------|-------------|
| `ToolHeavy` | Most agents | Retrieves by tag overlap with active tools + text relevance |
| `SingleAgent` | Simple chatbots | Lightweight retrieval without tool awareness |
| `MultiAgent` | Multi-agent systems | Coordinates memory across agent boundaries |

## 2. Namespace Management

Namespaces isolate memories per user or session. The critical insight: **the namespace usually isn't available when the plugin mounts** because the session hasn't started yet.

### Late-Binding Pattern

Use `Jido.MemoryOS.Integration.ensure_namespace/2` early in your agent's lifecycle hook to inject the session ID:

```elixir
def prepare_before_cmd(agent, params) do
  # Inject session_id into the plugin's namespace slots
  agent = Jido.MemoryOS.Integration.ensure_namespace(
    agent,
    agent.state[:session_id]
  )

  # Now all memory operations use this namespace
  # ...
end
```

This sets the namespace in both the `:defaults` and `:capture` paths of the plugin state. It's idempotent — calling it multiple times with the same value is safe.

### Namespace Strategies

Choose based on your use case:

| Strategy | Format | Use When |
|----------|--------|----------|
| Per-user | `"ask_anything_usr_42"` | Each user accumulates personal memory |
| Per-session | `"session_abc123"` | Memory scoped to a single conversation |
| Per-agent-user | `"scheduler_usr_42"` | Per-user memory isolated by agent type |

## 3. Auto-Capture Configuration

When `auto_capture: true`, the plugin intercepts agent signals and stores them as memory records automatically.

### Signal Patterns

Patterns match signal types using exact strings or wildcards:

```elixir
capture_signal_patterns: [
  "ai.llm.response",     # Exact match
  "ai.tool.*",           # Matches ai.tool.result, ai.tool.error, etc.
  "custom.event.type"    # Your custom signals
]
```

### Capture Rules

Rules control how matched signals are stored:

```elixir
capture_rules: [
  # Tag LLM responses for easy retrieval
  %{pattern: "ai.llm.response", tags: ["capture:llm"], kind: :response},

  # Tag tool results with the tool category
  %{pattern: "ai.tool.result", tags: ["capture:tool"], kind: :event},

  # Add a text requirement — skip signals with no useful text
  %{pattern: "ai.tool.result", require_text: true},

  # Skip noisy signals entirely
  %{pattern: "ai.debug.trace", skip: true}
]
```

### What Gets Stored

Each captured signal becomes a `Jido.Memory.Record` with:

- **`:text`** — The primary searchable content (extracted from signal data)
- **`:content`** — The full structured signal payload
- **`:tags`** — Auto-generated tags + any from capture rules
- **`:class`** — Usually `:episodic` for auto-captured signals
- **`:kind`** — Signal-specific (`:response`, `:event`, `:user_query`)

### Capture Timing Caveat

Signal capture is **asynchronous** — the `ai.llm.response` signal is emitted via `GenServer.cast`, so there's a brief window where the memory isn't yet stored. This means:

- If a user sends a second message immediately, the first response may not be retrievable yet
- In practice this is rarely an issue since human response time exceeds the capture latency
- For tests, add a small `Process.sleep(100)` after signal emission to ensure capture completes

## 4. Retrieval and Prompt Injection

This is where the magic happens. Before each LLM turn, retrieve relevant memories and inject them into the prompt.

### Using Integration.retrieve_context/3

```elixir
def prepare_before_cmd(agent, params) do
  agent = Jido.MemoryOS.Integration.ensure_namespace(agent, agent.state[:session_id])

  user_prompt = params[:prompt] || params[:query]
  tool_names = get_active_tool_names(agent)

  # Retrieve formatted memory context
  memory_block = Jido.MemoryOS.Integration.retrieve_context(
    agent,
    user_prompt,
    tool_names: tool_names,
    render_opts: [header: "Your memory of past interactions with this user:"]
  )

  # Inject into system prompt (see below)
  # ...
end
```

### How Retrieval Works

1. **Planner** — Analyzes the user's query and active tools to build a retrieval plan
2. **Candidates** — Queries the memory store for matching records (by tags, text, recency)
3. **Ranker** — Scores candidates by relevance (tool overlap, text similarity, recency)
4. **Context Pack** — Groups and formats top candidates into a structured pack
5. **Render** — `ContextPack.render/2` converts the pack into a prompt-ready string

### System Prompt Injection (Critical Pattern)

**Always inject memory into the system prompt, NOT the user message.**

LLMs treat user-role content as the user's text and may ignore memory placed there. Appending the context block to the system prompt yields reliable recall.

```elixir
# CORRECT: Inject into system prompt
agent =
  if is_binary(memory_block) do
    current_system_prompt = get_system_prompt(agent)
    enriched = current_system_prompt <> "\n\n---\n\n" <> memory_block
    put_system_prompt(agent, enriched)
  else
    agent
  end

# WRONG: Putting memory in the user message
# The LLM will likely ignore it or treat it as user input
params = Map.put(params, :prompt, memory_block <> "\n" <> user_prompt)
```

### Token Budget Tuning

The `context_token_budget` controls how much memory (in tokens) is included in the context pack. Adjust based on your model's context window:

```elixir
# In plugin config
context_token_budget: 4_000    # ~4K tokens of memory context

# For models with larger context windows
context_token_budget: 8_000

# For constrained contexts
context_token_budget: 1_200    # Default if not specified
```

## 5. Embedding and Semantic Search

By default, retrieval uses structured filters (tags, text substring, recency). Adding embeddings enables semantic similarity search, improving relevance for large memory stores.

### Configuration

```elixir
plugin_config = %{
  # ... base config ...

  # Function that converts text → vector embeddings
  embed_fn: fn texts ->
    vectors = MyApp.AI.embed(texts, model: "text-embedding-3-small")
    {:ok, vectors}
  end,

  # Where to store embeddings
  embedding_store: {Jido.MemoryOS.EmbeddingStore.Pgvector, [
    repo: MyApp.VectorsRepo,
    schema: MyApp.MemoryEmbedding
  ]},

  # Enables the embedding-based semantic provider
  semantic_provider: Jido.MemoryOS.Retrieval.SemanticProvider.Embedding
}
```

### Built-in Embedding Stores

| Store | Use Case | Requirements |
|-------|----------|-------------|
| `EmbeddingStore.ETS` | Development & testing | None |
| `EmbeddingStore.Pgvector` | Production | PostgreSQL + pgvector extension |

### Pgvector Setup

1. Enable the extension:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

2. Create the Ecto schema:

```elixir
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
```

3. Create the migration:

```elixir
defmodule MyApp.Repo.Migrations.CreateMemoryEmbeddings do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:memory_embeddings, primary_key: false) do
      add :namespace, :string, null: false
      add :record_id, :string, null: false
      add :embedding, :vector, size: 1536  # Match your model's dimension
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memory_embeddings, [:namespace, :record_id])
    create index(:memory_embeddings, [:namespace])
  end
end
```

## 6. Complete Example

Here's a full agent module showing the entire memory integration flow:

```elixir
defmodule MyApp.AskAnything.Hooks do
  @moduledoc "Lifecycle hooks for the Ask Anything agent with memory."

  alias Jido.MemoryOS.Integration

  def prepare_before_cmd(agent, params, opts \\ []) do
    max_history = Keyword.get(opts, :max_history_entries, 20)
    user_prompt = params[:prompt] || params[:query]

    # Step 1: Bind namespace to session
    agent = Integration.ensure_namespace(agent, agent.state[:session_id])

    # Step 2: Set base system prompt
    agent = set_system_prompt(agent)

    # Step 3: Retrieve memory context
    tool_names = get_tool_names(agent)
    memory_block = Integration.retrieve_context(agent, user_prompt,
      tool_names: tool_names
    )

    # Step 4: Inject memory into system prompt (NOT user message)
    agent =
      if is_binary(memory_block) do
        base = get_system_prompt(agent)
        put_system_prompt(agent, base <> "\n\n---\n\n" <> memory_block)
      else
        agent
      end

    # Step 5: Build user-facing prompt with conversation history
    history = agent.state[:history] || []
    prompt = build_prompt_with_history(history, user_prompt, max_history)
    params = Map.put(params, :prompt, prompt)

    {agent, params}
  end
end
```

### The Flow

```
User asks "What meetings do I have today?"
  |
  v
prepare_before_cmd runs:
  1. ensure_namespace → sets "ask_anything_usr_42" on plugin state
  2. set_system_prompt → base prompt with user name, datetime, skills
  3. retrieve_context → finds prior memories about meetings
     -> "Your memory of past interactions with this user:
         - User's schedule: Standup at 3:30 PM, Engineering Daily at 4 PM
         - User prefers short meeting summaries"
  4. Inject into system prompt → LLM sees memories as authoritative context
  5. Build user prompt → "User: What meetings do I have today?"
  |
  v
LLM generates response using both system prompt (with memory) and user message
  |
  v
Response emitted as "ai.llm.response" signal
  |
  v
Plugin auto-captures → stored under namespace "ask_anything_usr_42"
  |
  v
Next session: user asks related question → memories retrieved automatically
```

## 7. Troubleshooting

### "Agent says 'I don't have context from previous conversations'"

The LLM isn't seeing the memory. Check:
1. **System prompt injection** — Memory must be appended to the system prompt, not the user message
2. **Verify memory_block is non-nil** — Add logging before injection to confirm retrieval succeeded
3. **Check the system prompt actually updated** — Log the final system prompt to verify

### "No memories retrieved"

1. **Namespace mismatch** — Ensure the retrieval namespace matches the capture namespace. Call `ensure_namespace/2` before both capture and retrieval.
2. **Wrong tier** — If you store to `:short` but query `:mid`, you won't find records
3. **Empty store** — Verify records exist: `Jido.MemoryOS.retrieve(target, %{tier_mode: :short, limit: 10}, opts)`
4. **Text filter too narrow** — `text_contains` is substring match; try broader terms

### "Token budget shows 1200, not my configured value"

The default `context_token_budget` is 1,200 tokens. Verify your config path:
```elixir
# Must be in the plugin config (flows through extensions)
plugin_config = %{
  context_token_budget: 4_000,  # This gets picked up
  # ...
}
```

### "Memories not captured"

1. **`auto_capture: true`** must be set in plugin config
2. **Signal patterns must match** — `"ai.llm.response"` won't match `"ai.llm.stream"`
3. **Signal must have extractable text** — Empty or nil text signals are skipped
4. **Plugin must be mounted** — Check `agent.state.__memory_os__` exists

### "Embeddings not stored"

1. **`embed_fn` must return `{:ok, vectors}`** where vectors is a list of float lists
2. **Embedding is async** — Add `Process.sleep(200)` in tests after signal emission
3. **Check ETS table** (dev) or **pgvector table** (prod) for stored embeddings
