defmodule Jido.MemoryOS.Integration do
  @moduledoc """
  High-level helpers for integrating MemoryOS into agent lifecycle hooks.

  This module encapsulates the common glue code that every MemoryOS-powered
  agent needs: late-binding the namespace, building memory options from plugin
  state, and orchestrating retrieval + formatting for prompt injection.

  ## Complete Usage in Agent Hooks

      alias Jido.MemoryOS.Integration

      def prepare_before_cmd(agent, params) do
        user_prompt = params[:prompt] || params[:query]
        tool_names = get_active_tool_names(agent)

        # 1. Bind namespace (usually the session_id) into plugin state.
        #    Safe to call every turn — idempotent once set.
        agent = Integration.ensure_namespace(agent, agent.state[:session_id])

        # 2. Retrieve relevant memory context as a formatted string.
        #    Returns nil when no memories match or the prompt is blank.
        memory_block =
          Integration.retrieve_context(agent, user_prompt,
            tool_names: tool_names,
            render_opts: [header: "Your memory of past interactions:"]
          )

        # 3. Inject into the SYSTEM prompt (critical — see note below).
        agent =
          if is_binary(memory_block) do
            base = get_system_prompt(agent)
            put_system_prompt(agent, base <> "\\n\\n---\\n\\n" <> memory_block)
          else
            agent
          end

        # 4. Build the user-facing prompt (history + user message only).
        params = Map.put(params, :prompt, build_prompt(history, user_prompt))

        {agent, params}
      end

  ## System Prompt Injection

  When injecting retrieved memory into an LLM prompt, place the memory block in
  the **system message** (role: system), not the user message. LLMs treat user-role
  content as the user's text and may ignore memory placed there. Appending the
  context block to the end of the system prompt yields reliable recall.

  ## Key Functions

    * `ensure_namespace/2` — late-binds a namespace (usually session_id) into
      the plugin's `:defaults` and `:capture` paths
    * `build_memory_opts/1` — extracts a flat keyword list of memory options
      from the plugin state for passing to framework adapters
    * `retrieve_context/3` — runs the framework adapter's `pre_turn` hook and
      renders the result into a prompt-ready string
    * `resolve_adapter/1` — returns the configured framework adapter module
  """

  require Logger

  alias Jido.MemoryOS.ContextBudget
  alias Jido.MemoryOS.Plugin
  alias Jido.MemoryOS.Retrieval.ContextPack

  # ---------------------------------------------------------------------------
  # Namespace
  # ---------------------------------------------------------------------------

  @doc """
  Ensures the plugin state has `namespace` set in both `:defaults` and `:capture`.

  The MemoryOS plugin is typically mounted before the agent session starts, so
  the namespace (usually a session ID) isn't available at mount time. Call this
  early in the agent lifecycle to inject the namespace.

  Returns the agent unchanged if:
  - the plugin is not mounted
  - `namespace` is `nil` or empty
  - both paths already have a binary namespace
  """
  @spec ensure_namespace(map(), String.t() | nil) :: map()
  def ensure_namespace(agent, nil), do: agent
  def ensure_namespace(agent, ""), do: agent

  def ensure_namespace(agent, namespace) when is_binary(namespace) do
    case Plugin.get_state(agent) do
      nil ->
        agent

      plugin_state ->
        defaults = Map.get(plugin_state, :defaults, %{})
        capture = Map.get(plugin_state, :capture, %{})

        needs_update? =
          not is_binary(Map.get(defaults, :namespace)) or
            not is_binary(Map.get(capture, :namespace))

        if needs_update? do
          agent
          |> Plugin.put_in_state([:defaults, :namespace], namespace)
          |> Plugin.put_in_state([:capture, :namespace], namespace)
        else
          agent
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Memory opts
  # ---------------------------------------------------------------------------

  @doc """
  Builds a keyword list of memory options from the plugin state.

  Extracts `:namespace`, `:tier`, `:server`, and extension keys
  (`:embed_fn`, `:embedding_store`, `:semantic_provider`,
  `:context_token_budget`, `:semantic_timeout_ms`) into a flat keyword list
  suitable for passing to framework adapters and `Jido.MemoryOS` functions.

  Falls back to `agent.state[:session_id]` when no namespace is configured.
  """
  @spec build_memory_opts(map()) :: keyword()
  def build_memory_opts(agent) do
    plugin_state = Plugin.get_state(agent) || %{}
    defaults = Map.get(plugin_state, :defaults, %{})
    bindings = Map.get(plugin_state, :bindings, %{})
    framework = Map.get(plugin_state, :framework, %{})
    extensions = Map.get(plugin_state, :extensions, %{})

    namespace =
      case Map.get(defaults, :namespace) do
        ns when is_binary(ns) and ns != "" -> ns
        _ -> agent.state[:session_id]
      end

    extension_keys = [
      :embed_fn,
      :embedding_store,
      :semantic_provider,
      :context_token_budget,
      :semantic_timeout_ms
    ]

    extension_opts =
      extension_keys
      |> Enum.reduce([], fn key, acc ->
        case Map.get(extensions, key) do
          nil -> acc
          value -> [{key, value} | acc]
        end
      end)
      |> Enum.reverse()

    # Resolve dynamic context_token_budget (supports function or static integer)
    turn_count = Map.get(agent.state, :turn_count, 0)
    tier = Map.get(defaults, :tier)

    budget_opts = [turn_count: turn_count, namespace: namespace, tier: tier]
    raw_budget = Keyword.get(extension_opts, :context_token_budget)
    resolved_budget = ContextBudget.resolve(raw_budget, budget_opts)

    extension_opts =
      if raw_budget do
        Keyword.put(extension_opts, :context_token_budget, resolved_budget)
      else
        extension_opts
      end

    Map.get(framework, :opts, [])
    |> Keyword.merge(extension_opts)
    |> maybe_put(:namespace, namespace)
    |> maybe_put(:tier, tier)
    |> maybe_put(:server, Map.get(bindings, :server))
  end

  # ---------------------------------------------------------------------------
  # Retrieval
  # ---------------------------------------------------------------------------

  @doc """
  Retrieves relevant memory context via the framework adapter's `pre_turn` hook
  and renders it into a formatted string for prompt injection.

  Returns `nil` when the prompt is blank, no memories are found, or an error
  occurs during retrieval.

  ## Options

    * `:tool_names` — list of tool name strings for the adapter (default `[]`)
    * `:render_opts` — keyword opts forwarded to `ContextPack.render/2`
    * `:memory_opts` — keyword overrides merged into `build_memory_opts/1` (e.g., `context_token_budget: 6000`)
  """
  @spec retrieve_context(map(), String.t() | nil, keyword()) :: String.t() | nil
  def retrieve_context(agent, prompt, opts \\ [])
  def retrieve_context(_agent, nil, _opts), do: nil
  def retrieve_context(_agent, "", _opts), do: nil

  def retrieve_context(agent, prompt, opts) when is_binary(prompt) do
    tool_names = Keyword.get(opts, :tool_names, [])
    render_opts = Keyword.get(opts, :render_opts, [])
    memory_overrides = Keyword.get(opts, :memory_opts, [])

    turn_input = %{tool_names: tool_names, query_text: prompt}
    memory_opts = Keyword.merge(build_memory_opts(agent), memory_overrides)
    adapter = resolve_adapter(agent)

    case adapter.pre_turn(agent, turn_input, memory_opts) do
      {:ok, %{context_pack: context_pack, candidates: candidates}}
      when is_list(candidates) and candidates != [] ->
        ContextPack.render(context_pack, render_opts)

      # Support legacy `records` key for backwards compatibility
      {:ok, %{context_pack: context_pack, records: records}}
      when is_list(records) and records != [] ->
        ContextPack.render(context_pack, render_opts)

      {:ok, _} ->
        nil

      {:error, _reason} ->
        nil
    end
  rescue
    e ->
      Logger.debug("[MemoryOS.Integration] retrieve_context exception: #{Exception.message(e)}")

      nil
  catch
    :exit, reason ->
      Logger.debug("[MemoryOS.Integration] retrieve_context exit: #{inspect(reason)}")
      nil
  end

  # ---------------------------------------------------------------------------
  # Adapter resolution
  # ---------------------------------------------------------------------------

  @doc """
  Returns the framework adapter module configured in the plugin state.

  Defaults to `Jido.MemoryOS.FrameworkAdapter.ToolHeavy` when not configured.
  """
  @spec resolve_adapter(map()) :: module()
  def resolve_adapter(agent) do
    plugin_state = Plugin.get_state(agent) || %{}
    framework = Map.get(plugin_state, :framework, %{})
    Map.get(framework, :adapter, Jido.MemoryOS.FrameworkAdapter.ToolHeavy)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
