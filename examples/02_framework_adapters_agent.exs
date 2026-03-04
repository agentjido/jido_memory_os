Mix.Task.run("app.start")

alias Jido.MemoryOS
alias Jido.MemoryOS.FrameworkAdapter.{MultiAgent, SingleAgent, ToolHeavy}
alias Jido.MemoryOS.MemoryManager

defmodule Examples.AdapterBackedLoop do
  @manager :memory_os_examples_adapters
  @tables %{
    short: :jido_memory_os_example_adapters_short,
    mid: :jido_memory_os_example_adapters_mid,
    long: :jido_memory_os_example_adapters_long
  }

  def run do
    cleanup_tables()
    start_manager()

    primary = %{id: "examples-adapter-primary"}
    shared_a = %{id: "examples-adapter-shared-a"}
    shared_b = %{id: "examples-adapter-shared-b"}
    opts = [server: @manager]

    IO.puts("Single-agent adapter:")
    run_single_agent_demo(primary, opts)

    IO.puts("")
    IO.puts("Multi-agent adapter:")
    run_multi_agent_demo(primary, [shared_a, shared_b], opts)

    IO.puts("")
    IO.puts("Tool-heavy adapter:")
    run_tool_heavy_demo(primary, opts)
  end

  defp run_single_agent_demo(target, opts) do
    {:ok, post_turn} =
      SingleAgent.post_turn(
        target,
        %{
          response_text: "User prefers concise responses",
          tags: ["persona:style"],
          chain_id: "chain:examples:single"
        },
        opts
      )

    {:ok, pre_turn} =
      SingleAgent.pre_turn(
        target,
        %{memory_query: %{text: "concise responses", tier_mode: :short, limit: 3}},
        opts
      )

    IO.puts("- memory id: #{post_turn.memory_id}")
    IO.puts("- retrieved result count: #{pre_turn.retrieval.result_count}")
  end

  defp run_multi_agent_demo(primary, shared_targets, opts) do
    targets = [primary | shared_targets]

    Enum.each(targets, fn target ->
      {:ok, _record} =
        MemoryOS.remember(
          target,
          %{
            class: :episodic,
            kind: :event,
            text: "Shared project context for #{target.id}",
            chain_id: "chain:examples:multi:seed"
          },
          opts
        )
    end)

    {:ok, pre_turn} =
      MultiAgent.pre_turn(
        primary,
        %{
          memory_query: %{text: "Shared project context", tier_mode: :short, limit: 6},
          shared_targets: shared_targets
        },
        opts
      )

    {:ok, post_turn} =
      MultiAgent.post_turn(
        primary,
        %{
          response: "Shared decision recorded",
          chain_id: "chain:examples:multi:post",
          shared_targets: shared_targets
        },
        Keyword.put(opts, :broadcast_shared, true)
      )

    IO.puts("- participants: #{Enum.join(pre_turn.retrieval.participants, ", ")}")
    IO.puts("- per-target retrieval limit: #{pre_turn.retrieval.per_target_limit}")
    IO.puts("- write count: #{length(post_turn.written)}")
  end

  defp run_tool_heavy_demo(target, opts) do
    {:ok, post_turn} =
      ToolHeavy.post_turn(
        target,
        %{
          response_text: "Completed weather and calendar tools",
          chain_id: "chain:examples:tools:post",
          tool_events: [
            %{tool_name: "weather_lookup", status: :ok, result: "72F and sunny"},
            %{tool_name: "calendar_create", status: :ok, result: %{event_id: "evt-1"}}
          ]
        },
        opts
      )

    {:ok, pre_turn} =
      ToolHeavy.pre_turn(
        target,
        %{
          memory_query: %{text: "weather", tier_mode: :short, limit: 5},
          tool_names: ["weather_lookup"]
        },
        opts
      )

    IO.puts("- assistant memory id: #{post_turn.assistant_memory_id}")
    IO.puts("- tool memory ids: #{Enum.join(post_turn.tool_memory_ids, ", ")}")
    IO.puts("- retrieval tool tags: #{Enum.join(pre_turn.retrieval.tool_tags, ", ")}")
    IO.puts("- retrieved result count: #{pre_turn.retrieval.result_count}")
  end

  defp start_manager do
    {:ok, _pid} = MemoryManager.start_link(name: @manager, app_config: app_config())
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

Examples.AdapterBackedLoop.run()
