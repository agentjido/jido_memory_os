# Examples

This directory shows two ways to integrate MemoryOS with agents.

## 1) Plugin + Actions API surface

Run:

```bash
mix run examples/01_plugin_actions_agent.exs
```

What it shows:
- agent configured with `Jido.MemoryOS.Plugin`
- route-based usage via `memory_os.remember` and `memory_os.retrieve`
- adapter-routed usage via `memory_os.post_turn` and `memory_os.pre_turn`
- plugin-level adapter selector with `framework_adapter`
- direct action module usage via `Jido.MemoryOS.Actions.Remember` and
  `Jido.MemoryOS.Actions.Retrieve`

## 2) Framework adapter integration

Run:

```bash
mix run examples/02_framework_adapters_agent.exs
```

What it shows:
- custom loop using `FrameworkAdapter.SingleAgent`
- shared loop using `FrameworkAdapter.MultiAgent`
- tool-trace loop using `FrameworkAdapter.ToolHeavy`

Both scripts start an isolated `MemoryManager` with local ETS stores.
