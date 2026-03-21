defmodule Example.CommonPluginMemoryOSAgent do
  use Jido.Agent,
    name: "common_plugin_memory_os_agent",
    default_plugins: %{__memory__: false},
    plugins: [
      {Jido.Memory.Plugin,
       %{
         provider:
           {Jido.MemoryOS.Provider,
            [
              server: Example.MemoryManager,
              app_config: %{
                tiers: %{
                  short: %{store: {Jido.Memory.Store.ETS, [table: :example_common_short]}},
                  mid: %{store: {Jido.Memory.Store.ETS, [table: :example_common_mid]}},
                  long: %{store: {Jido.Memory.Store.ETS, [table: :example_common_long]}}
                }
              }
            ]}
       }}
    ]
end
