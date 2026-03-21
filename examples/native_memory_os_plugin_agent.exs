defmodule Example.NativeMemoryOSPluginAgent do
  use Jido.Agent,
    name: "native_memory_os_plugin_agent",
    plugins: [
      {Jido.MemoryOS.Plugin,
       %{
         manager: Example.MemoryManager,
         framework_adapter: Jido.MemoryOS.FrameworkAdapter.SingleAgent,
         tier: :short,
         capture_signal_patterns: ["ai.react.query", "ai.llm.response"]
       }}
    ]
end
