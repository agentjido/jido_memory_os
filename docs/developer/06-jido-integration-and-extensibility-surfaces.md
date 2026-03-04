# 06 - Jido Integration and Extensibility Surfaces

## Integration surfaces
- Plugin: `Jido.MemoryOS.Plugin`
- Actions: `Jido.MemoryOS.Actions.Remember|Retrieve|Forget|Consolidate|PreTurn|PostTurn`
- Long-term persistence behavior: `Jido.MemoryOS.LongTermStore`
- Framework adapters:
  - `Jido.MemoryOS.FrameworkAdapter.SingleAgent`
  - `Jido.MemoryOS.FrameworkAdapter.MultiAgent`
  - `Jido.MemoryOS.FrameworkAdapter.ToolHeavy`

## Plugin routing and signal capture
```mermaid
flowchart LR
    SIG["Jido.Signal"] --> PL["MemoryOS.Plugin.handle_signal"]
    PL --> RULES["pattern/rule match"]
    RULES -->|capture| REM["Jido.MemoryOS.remember"]
    RULES -->|skip| CONT["continue"]

    AGENT["Agent route memory_os.remember/retrieve/forget/consolidate"] --> ACT["Action module"] --> API["Jido.MemoryOS facade"]
    AGENT --> ADAPT["memory_os.pre_turn/post_turn"] --> FW["Configured framework adapter"]
    FW --> API
```

## Why actions exist
Action wrappers provide schema-validated, pipeline-friendly access to facade operations and framework adapter hooks, while standardizing result key placement in agent state.

## Framework adapter contract
`Jido.MemoryOS.FrameworkAdapter` defines:
- `pre_turn/3`
- `post_turn/3`
- `normalize_error/2`

Reference adapters map common orchestration styles:
- Single agent: simple retrieve-before, remember-after
- Multi-agent: participant fan-out/fan-in with optional partial success
- Tool-heavy: explicit tool-event memory capture with tool tags/status

## Extensibility points
- Semantic ranking provider behavior (`Retrieval.SemanticProvider`)
- Capture rules/patterns in plugin config
- Plugin-level framework adapter selector (`framework_adapter`, `framework_adapter_opts`)
- Runtime option overlays from adapter payloads
- Long-term store behavior (`LongTermStore`) for `:long` tier persistence
- Compatibility mappers for legacy payload/query/result shapes (`Jido.MemoryOS.Compatibility`)

## LongTermStore dispatch path
```mermaid
flowchart LR
    API["Jido.MemoryOS facade"] --> MM["MemoryManager"]
    MM --> RT["Adapter.MemoryRuntime"]
    RT --> TIER{"tier == :long ?"}
    TIER -->|no| JR["Jido.Memory.Runtime + tier store"]
    TIER -->|yes| LTS["LongTermStore behavior"]
    LTS --> ETS["LongTermStore.ETS (default)"]
    LTS --> PG["LongTermStore.Postgres"]
    LTS --> CUS["Custom backend module"]
```

Long-term backend selection order:
- per-call override: `opts[:long_term_backend]`
- manager config: `manager.long_term_backend`
- fallback: `Jido.MemoryOS.LongTermStore.ETS`

## How this enables intended goals
- Integration stays ergonomic for real Jido agents and workflows.
- Extensibility keeps core logic stable while allowing domain-specific retrieval/capture behavior.
- Legacy compatibility lowers migration cost for existing agents.
