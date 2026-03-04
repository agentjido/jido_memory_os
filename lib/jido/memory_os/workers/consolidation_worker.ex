defmodule Jido.MemoryOS.Workers.ConsolidationWorker do
  @moduledoc """
  Consolidation control-plane worker.

  Receives asynchronous consolidation schedules and delegates execution back
  through the manager API.
  """

  use GenServer

  alias Jido.MemoryOS.MemoryManager

  @type state :: %{
          manager: GenServer.server(),
          completed_jobs: non_neg_integer()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Schedules one background consolidation request.
  """
  @spec schedule(GenServer.server(), map() | struct(), keyword()) :: :ok
  def schedule(server \\ __MODULE__, target, opts \\ []) do
    GenServer.cast(server, {:schedule, target, opts})
  end

  @impl true
  def init(opts) do
    {:ok, %{manager: Keyword.get(opts, :manager, MemoryManager), completed_jobs: 0}}
  end

  @impl true
  def handle_cast({:schedule, target, opts}, state) do
    manager = state.manager

    {:ok, _pid} =
      Task.start(fn ->
        _ = MemoryManager.consolidate(target, Keyword.put(opts, :server, manager))
        :ok
      end)

    {:noreply, %{state | completed_jobs: state.completed_jobs + 1}}
  end
end
