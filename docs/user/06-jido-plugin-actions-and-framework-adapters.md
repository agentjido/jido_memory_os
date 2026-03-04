# 06 - Jido Plugin, Actions, and Framework Adapters

## Plugin
`Jido.MemoryOS.Plugin` exposes action routes:
- `memory_os.remember`
- `memory_os.retrieve`
- `memory_os.forget`
- `memory_os.consolidate`
- `memory_os.pre_turn`
- `memory_os.post_turn`

It also supports auto-capturing signals using exact/wildcard patterns and rule overrides.

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent",
    plugins: [Jido.MemoryOS.Plugin]
end

plugin_config = %{
  manager: Jido.MemoryOS.MemoryManager,
  framework_adapter: Jido.MemoryOS.FrameworkAdapter.SingleAgent,
  framework_adapter_opts: [default_limit: 6],
  auto_capture: true,
  capture_signal_patterns: ["ai.llm.*", "ai.tool.*"],
  capture_rules: [
    %{pattern: "ai.llm.response", tags: ["capture:llm"], kind: :response},
    %{pattern: "ai.llm.ignore", skip: true}
  ]
}
```

`framework_adapter` selects the default adapter module used by:
- `memory_os.pre_turn`
- `memory_os.post_turn`

You can override adapter or options per call with:
- `framework_adapter`
- `framework_opts` (or `framework_adapter_opts`)

Route example with configured adapter:

```elixir
Jido.Signal.new!("memory_os.post_turn", %{
  response_text: "completed tools",
  tool_events: [%{tool_name: "weather_lookup", status: :ok, result: "72F"}],
  memory_result_key: :post_turn_result
})

Jido.Signal.new!("memory_os.pre_turn", %{
  memory_query: %{text: "weather", tier_mode: :short, limit: 5},
  tool_names: ["weather_lookup"],
  memory_result_key: :pre_turn_result
})
```

## Actions
Action wrappers for core CRUD/consolidation map directly to the facade:
- `Jido.MemoryOS.Actions.Remember`
- `Jido.MemoryOS.Actions.Retrieve`
- `Jido.MemoryOS.Actions.Forget`
- `Jido.MemoryOS.Actions.Consolidate`

Framework-loop action wrappers route through the selected framework adapter:
- `Jido.MemoryOS.Actions.PreTurn`
- `Jido.MemoryOS.Actions.PostTurn`

Use when building declarative action pipelines in Jido.

## Framework adapters
Reference adapters for common loop styles:
- `Jido.MemoryOS.FrameworkAdapter.SingleAgent`
- `Jido.MemoryOS.FrameworkAdapter.MultiAgent`
- `Jido.MemoryOS.FrameworkAdapter.ToolHeavy`

Adapter responsibilities:
- `pre_turn/3`: retrieval + context pack preparation
- `post_turn/3`: write turn outcomes into memory
- `normalize_error/2`: consistent error mapping

Use adapters when you want framework-level integration instead of calling the facade manually in every turn.
