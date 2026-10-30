defmodule Raygun.Reporter do
  @moduledoc """
  Admission bornée des événements Logger. Les places ETS restent occupées jusqu'à
  la fin du worker, y compris pendant son annulation. Aucun message d'admission
  n'est envoyé au dispatcher.
  """
  use GenServer

  @defaults [
    capacity: 100,
    concurrency: 2,
    max_bytes: 262_144,
    timeout: 10_000,
    poll_interval: 10,
    rate_limit: 100
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def submit(message, metadata) do
    table = :ets.whereis(__MODULE__)
    [{:config, config}] = :ets.lookup(table, :config)

    cond do
      metadata[:raygun_reporting] -> reject(table, :internal)
      :erlang.external_size({message, metadata}) > config[:max_bytes] -> reject(table, :oversized)
      :ets.update_counter(table, :rate, 1) > config[:rate_limit] -> reject(table, :rate_limited)
      true -> admit(table, config[:capacity], {message, metadata})
    end
  rescue
    ArgumentError -> :dropped
    MatchError -> :dropped
  end

  def stats do
    table = :ets.whereis(__MODULE__)

    Map.new(
      for {key, value} <- :ets.tab2list(table),
          is_atom(key),
          key not in [:config, :rate],
          do: {key, value}
    )
    |> Map.put(
      :pending,
      :ets.select_count(table, [{{:"$1", :_}, [{:is_integer, :"$1"}], [true]}])
    )
  rescue
    ArgumentError -> %{pending: 0}
  end

  defp admit(table, capacity, event) do
    if Enum.any?(1..capacity, &:ets.insert_new(table, {&1, event})) do
      :ets.update_counter(table, :accepted, 1)
      :accepted
    else
      reject(table, :full)
    end
  end

  defp reject(table, reason) do
    :ets.update_counter(table, reason, 1)
    :dropped
  end

  @impl true
  def init(_) do
    config = Keyword.merge(@defaults, Application.get_env(:raygun, :reporter, []))

    for {key, value} <- config do
      unless key in Keyword.keys(@defaults) and is_integer(value) and value > 0 do
        raise ArgumentError, "Configuration Raygun.Reporter invalide : #{inspect(key)}"
      end
    end

    if config[:concurrency] > config[:capacity],
      do: raise(ArgumentError, "concurrency > capacity")

    table = :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(table, {:config, config})

    for key <- [
          :rate,
          :accepted,
          :internal,
          :oversized,
          :rate_limited,
          :full,
          :completed,
          :failed,
          :timed_out
        ] do
      :ets.insert(table, {key, 0})
    end

    Process.send_after(self(), :poll, config[:poll_interval])
    Process.send_after(self(), :reset_rate, 1_000)
    {:ok, %{table: table, config: config, active: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = dispatch(state)
    Process.send_after(self(), :poll, state.config[:poll_interval])
    {:noreply, state}
  end

  def handle_info(:reset_rate, state) do
    :ets.insert(state.table, {:rate, 0})
    Process.send_after(self(), :reset_rate, 1_000)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case state.active[ref] do
      nil -> :ok
      _ -> :ets.update_counter(state.table, if(result == :ok, do: :completed, else: :failed), 1)
    end

    {:noreply, state}
  end

  def handle_info({:expire, ref}, state) do
    case state.active[ref] do
      nil ->
        :ok

      %{pid: pid} ->
        Process.exit(pid, :kill)
        :ets.update_counter(state.table, :timed_out, 1)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.active, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{slot: slot, timer: timer}, active} ->
        Process.cancel_timer(timer)
        :ets.delete(state.table, slot)
        if reason != :normal, do: :ets.update_counter(state.table, :failed, 1)
        {:noreply, %{state | active: active}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp dispatch(state) do
    occupied = MapSet.new(state.active, fn {_ref, worker} -> worker.slot end)

    Enum.reduce_while(1..state.config[:capacity], state, fn slot, state ->
      if map_size(state.active) >= state.config[:concurrency] do
        {:halt, state}
      else
        case {MapSet.member?(occupied, slot), :ets.lookup(state.table, slot)} do
          {false, [{^slot, {message, metadata}}]} ->
            task =
              Task.Supervisor.async_nolink(
                Raygun.TaskSupervisor,
                fn -> deliver(message, metadata, state.config[:max_bytes]) end,
                shutdown: :brutal_kill
              )

            timer = Process.send_after(self(), {:expire, task.ref}, state.config[:timeout])
            worker = %{pid: task.pid, slot: slot, timer: timer}
            {:cont, %{state | active: Map.put(state.active, task.ref, worker)}}

          _ ->
            {:cont, state}
        end
      end
    end)
  end

  defp deliver(message, metadata, max_bytes) do
    Logger.metadata(metadata)
    Logger.metadata(raygun_reporting: true)
    Process.put(:raygun_max_bytes, max_bytes)

    try do
      if is_exception(message),
        do: Raygun.report_stacktrace([], message),
        else: Raygun.report_message(message)
    rescue
      _ -> {:error, :report_failed}
    catch
      _, _ -> {:error, :report_failed}
    end
  end
end
