Mix.Task.run("app.start")

alias Jido.MemoryOS.Actions.{Remember, Retrieve}
alias Jido.MemoryOS.MemoryManager
alias Jido.Signal

defmodule Examples.PluginActionsAgent do
  use Jido.Agent,
    name: "examples_plugin_actions_agent",
    plugins: [
      {Jido.MemoryOS.Plugin,
       %{
         manager: :memory_os_examples_plugin,
         framework_adapter: Jido.MemoryOS.FrameworkAdapter.ToolHeavy,
         framework_adapter_opts: [default_limit: 5],
         tier: :short,
         auto_capture: true,
         capture_signal_patterns: ["ai.llm.*", "ai.tool.*"],
         capture_rules: [
           %{pattern: "ai.llm.response", tags: ["capture:llm"], kind: :response},
           %{pattern: "ai.tool.result", tags: ["capture:tool"], kind: :event}
         ]
       }}
    ]
end

defmodule Examples.PluginActionsDemo do
  @manager :memory_os_examples_plugin
  @tables %{
    short: :jido_memory_os_example_plugin_short,
    mid: :jido_memory_os_example_plugin_mid,
    long: :jido_memory_os_example_plugin_long
  }

  def run do
    cleanup_tables()
    start_manager()
    start_jido()

    target = %{id: "examples-plugin-agent-1", group: "examples"}

    {:ok, server} =
      Jido.AgentServer.start_link(
        agent: Examples.PluginActionsAgent,
        id: target.id
      )

    remember_signal =
      Signal.new!(
        "memory_os.remember",
        %{
          server: @manager,
          tier: :short,
          agent_id: target.id,
          class: :episodic,
          kind: :event,
          text: "User prefers concise answers",
          tags: ["persona:style", "topic:response"],
          memory_result_key: :last_memory_id
        },
        source: "/examples/plugin"
      )

    {:ok, remembered_agent} = Jido.AgentServer.call(server, remember_signal)
    memory_id = remembered_agent.state.last_memory_id

    retrieve_signal =
      Signal.new!(
        "memory_os.retrieve",
        %{
          server: @manager,
          tier_mode: :short,
          agent_id: target.id,
          text_contains: "concise answers",
          limit: 5,
          memory_result_key: :records
        },
        source: "/examples/plugin"
      )

    {:ok, retrieved_agent} = Jido.AgentServer.call(server, retrieve_signal)

    IO.puts("Plugin route usage:")
    IO.puts("- remembered memory id: #{memory_id}")
    IO.puts("- retrieved records: #{length(retrieved_agent.state.records)}")

    post_turn_signal =
      Signal.new!(
        "memory_os.post_turn",
        %{
          server: @manager,
          tier: :short,
          agent_id: target.id,
          response_text: "Completed weather and calendar tools",
          chain_id: "chain:examples:plugin:adapter",
          tool_events: [
            %{tool_name: "weather_lookup", status: :ok, result: "72F and sunny"},
            %{tool_name: "calendar_create", status: :ok, result: %{event_id: "evt-1"}}
          ],
          memory_result_key: :post_turn_result
        },
        source: "/examples/plugin"
      )

    {:ok, post_turn_agent} = Jido.AgentServer.call(server, post_turn_signal)
    post_turn_result = post_turn_agent.state.post_turn_result

    pre_turn_signal =
      Signal.new!(
        "memory_os.pre_turn",
        %{
          server: @manager,
          tier: :short,
          agent_id: target.id,
          memory_query: %{text: "weather", tier_mode: :short, limit: 5},
          tool_names: ["weather_lookup"],
          memory_result_key: :pre_turn_result
        },
        source: "/examples/plugin"
      )

    {:ok, pre_turn_agent} = Jido.AgentServer.call(server, pre_turn_signal)
    pre_turn_result = pre_turn_agent.state.pre_turn_result

    IO.puts("Plugin adapter route usage (configured ToolHeavy):")
    IO.puts("- assistant memory id: #{post_turn_result.assistant_memory_id}")
    IO.puts("- tool memory ids: #{length(post_turn_result.tool_memory_ids)}")
    IO.puts("- tool tags in retrieval: #{Enum.join(pre_turn_result.retrieval.tool_tags, ", ")}")
    IO.puts("- retrieved result count: #{pre_turn_result.retrieval.result_count}")

    {:ok, action_result} =
      Remember.run(
        %{
          server: @manager,
          tier: :short,
          agent_id: target.id,
          class: :episodic,
          kind: :event,
          text: "Remembered through action module",
          tags: ["source:action"],
          memory_result_key: :action_memory_id
        },
        target
      )

    {:ok, retrieved_action_result} =
      Retrieve.run(
        %{
          server: @manager,
          tier_mode: :short,
          agent_id: target.id,
          text_contains: "action module",
          limit: 5,
          memory_result_key: :action_records
        },
        target
      )

    action_memory_id = Map.fetch!(action_result, :action_memory_id)
    action_records = Map.fetch!(retrieved_action_result, :action_records)

    IO.puts("Direct action usage:")
    IO.puts("- remembered memory id: #{action_memory_id}")
    IO.puts("- retrieved records: #{length(action_records)}")
  end

  defp start_manager do
    {:ok, _pid} = MemoryManager.start_link(name: @manager, app_config: app_config())
  end

  defp start_jido do
    case Jido.start(name: Jido) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp app_config do
    %{
      tiers: %{
        short: %{store: {Jido.Memory.Store.ETS, [table: @tables.short]}},
        mid: %{store: {Jido.Memory.Store.ETS, [table: @tables.mid]}},
        long: %{store: {Jido.Memory.Store.ETS, [table: @tables.long]}}
      }
    }
  end

  defp cleanup_tables do
    @tables
    |> Map.values()
    |> Enum.each(fn table ->
      case :ets.whereis(table) do
        :undefined -> :ok
        _tid -> :ets.delete(table)
      end
    end)
  end
end

Examples.PluginActionsDemo.run()
