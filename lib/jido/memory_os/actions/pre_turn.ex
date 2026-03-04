defmodule Jido.MemoryOS.Actions.PreTurn do
  @moduledoc """
  Action wrapper for framework adapter `pre_turn/3`.
  """

  alias Jido.MemoryOS.Actions.AdapterSupport

  @memory_option_keys AdapterSupport.memory_opt_keys()
  @adapter_option_keys [:default_limit, :allow_partial, :shared_targets, :broadcast_shared]
  @meta_option_keys [
    :framework_adapter,
    :framework_adapter_opts,
    :framework_opts,
    :target,
    :turn_input,
    :memory_result_key
  ]

  use Jido.Action,
    name: "memory_os_pre_turn",
    description: "Run framework adapter pre_turn and write result into state",
    schema: [
      framework_adapter: [
        type: :any,
        required: false,
        doc: "Adapter module implementing Jido.MemoryOS.FrameworkAdapter"
      ],
      framework_adapter_opts: [
        type: :any,
        required: false,
        doc: "Default keyword options passed to adapter hook"
      ],
      framework_opts: [
        type: :any,
        required: false,
        doc: "Inline keyword options passed to adapter hook"
      ],
      target: [type: :any, required: false, doc: "Explicit target override"],
      turn_input: [type: :any, required: false, doc: "Optional explicit pre-turn payload"],
      default_limit: [type: :any, required: false, doc: "Adapter retrieval default limit"],
      allow_partial: [type: :any, required: false, doc: "Allow partial adapter success"],
      shared_targets: [type: :any, required: false, doc: "Shared targets for multi-agent loops"],
      broadcast_shared: [type: :any, required: false, doc: "Broadcast writes to shared targets"],
      memory_result_key: [type: :any, required: false, doc: "Result key for pre-turn payload"]
    ]

  @impl true
  def run(params, context) do
    map_params = normalize_map(params)
    target = AdapterSupport.target(map_params, context)

    payload =
      AdapterSupport.build_turn_payload(
        map_params,
        :turn_input,
        @memory_option_keys ++ @adapter_option_keys ++ @meta_option_keys
      )

    with {:ok, adapter} <- AdapterSupport.resolve_adapter(map_params, context, :pre_turn),
         {:ok, result} <-
           adapter.pre_turn(
             target,
             payload,
             AdapterSupport.resolve_adapter_opts(map_params, context, @adapter_option_keys)
           ) do
      key = map_get(map_params, :memory_result_key, :memory_pre_turn)
      {:ok, %{key => result}}
    else
      {:error, reason} ->
        framework = AdapterSupport.framework_state(context)

        adapter =
          map_get(
            map_params,
            :framework_adapter,
            map_get(framework, :adapter, AdapterSupport.default_adapter())
          )

        {:error, AdapterSupport.normalize_adapter_error(adapter, reason, :pre_turn)}
    end
  end

  @spec normalize_map(term()) :: map()
  defp normalize_map(%{} = map), do: map

  defp normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Map.new(list), else: %{}
  end

  defp normalize_map(_), do: %{}

  @spec map_get(map(), atom(), term()) :: term()
  defp map_get(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
