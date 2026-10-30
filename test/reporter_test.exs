defmodule Raygun.ReporterTest do
  use ExUnit.Case, async: false
  require Logger

  defmodule Transport do
    @behaviour Raygun.Transport
    def post(url, body, headers, options) do
      owner = Application.fetch_env!(:raygun, :test_owner)
      send(owner, {:request, self(), url, Jason.decode!(body), headers, options})

      case Application.get_env(:raygun, :test_mode, :ok) do
        :block ->
          receive do: (:release -> {:ok, %HTTPoison.Response{status_code: 202}})

        :raise ->
          raise "transport failure"

        :exit ->
          exit(:transport_failure)

        :tls ->
          {:error, %HTTPoison.Error{reason: :tls_alert}}

        :log ->
          Logger.error("reporting failed")
          {:error, :tls_alert}

        code when is_integer(code) ->
          {:ok, %HTTPoison.Response{status_code: code}}

        _ ->
          {:ok, %HTTPoison.Response{status_code: 202}}
      end
    end
  end

  defmodule LocalHTTPTransport do
    @behaviour Raygun.Transport
    def post(_url, body, headers, options) do
      HTTPoison.post(Application.fetch_env!(:raygun, :test_url), body, headers, options)
    end
  end

  defmodule Callback do
    def call(message) do
      send(Application.fetch_env!(:raygun, :test_owner), {:callback, self(), message})

      case message do
        "callback block" -> receive do: (:release -> {:ok, message})
        "filtered" -> {:error, :excluded}
        _ -> {:ok, message}
      end
    end
  end

  defmodule Witness do
    @behaviour :gen_event
    def init(owner), do: {:ok, owner}

    def handle_event(event, owner) do
      send(owner, {:witness, event})
      {:ok, owner}
    end

    def handle_call(_, state), do: {:ok, :ok, state}
    def handle_info(_, state), do: {:ok, state}
    def terminate(_, _), do: :ok
    def code_change(_, state, _), do: {:ok, state}
  end

  defmodule LegacyBackend do
    def init(_), do: {:ok, nil}

    def handle_event({:error, _, {Logger, message, _, _}}, state) do
      Raygun.report_message(message)
      {:ok, state}
    end
  end

  setup do
    saved = Application.get_all_env(:raygun)
    Application.stop(:raygun)
    Application.put_env(:raygun, :test_owner, self())
    Application.put_env(:raygun, :transport, Transport)
    Application.put_env(:raygun, :before_send, {Callback, :call})

    Application.put_env(:raygun, :reporter,
      capacity: 4,
      concurrency: 1,
      timeout: 500,
      poll_interval: 5,
      max_bytes: 16_384,
      rate_limit: 100
    )

    {:ok, _} = Application.ensure_all_started(:raygun)
    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, Raygun.Logger, [])
    :ok = :gen_event.add_handler(manager, Witness, self())

    on_exit(fn ->
      Logger.remove_backend(Raygun.Logger)
      if Process.alive?(manager), do: :gen_event.stop(manager)
      Application.stop(:raygun)
      for {key, _} <- Application.get_all_env(:raygun), do: Application.delete_env(:raygun, key)
      for {key, value} <- saved, do: Application.put_env(:raygun, key, value)
      Application.ensure_all_started(:raygun)
    end)

    %{manager: manager}
  end

  defp event(message, metadata \\ []),
    do: {:error, Process.group_leader(), {Logger, message, nil, metadata}}

  defp emit(manager, message), do: :gen_event.sync_notify(manager, event(message))

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  test "the legacy synchronous backend prevents a witness from progressing" do
    Application.put_env(:raygun, :test_mode, :block)
    {:ok, manager} = :gen_event.start()
    :gen_event.add_handler(manager, Witness, self())
    :gen_event.add_handler(manager, LegacyBackend, [])

    try do
      :gen_event.notify(manager, event("legacy"))
      assert_receive {:request, worker, _, _, _, _}, 1_000
      :gen_event.notify(manager, event("later"))
      refute_receive {:witness, _}, 30
      send(worker, :release)
      assert_receive {:witness, _}, 1_000
      assert_receive {:request, ^worker, _, _, _, _}, 1_000
      send(worker, :release)
    after
      Process.exit(manager, :kill)
    end
  end

  test "a blocked report does not block the witness and admission bounds the entire burst", %{
    manager: manager
  } do
    Application.put_env(:raygun, :test_mode, :block)
    emit(manager, "blocked")
    assert_receive {:request, worker, _, _, _, _}, 1_000
    emit(manager, "later")
    assert_receive {:witness, {:error, _, {Logger, "later", _, _}}}, 300
    for _ <- 1..1_000, do: emit(manager, "burst")
    assert Raygun.Reporter.stats().pending == 4
    assert length(Task.Supervisor.children(Raygun.TaskSupervisor)) == 1

    assert {:message_queue_len, size} =
             Process.info(Process.whereis(Raygun.Reporter), :message_queue_len)

    assert size <= 3
    assert Raygun.Reporter.stats().full > 0
    send(worker, :release)
  end

  test "HTTP 202 keeps the callback, endpoint, payload and finite HTTP options", %{
    manager: manager
  } do
    emit(manager, "hello")
    assert_receive {:callback, worker, "hello"}, 1_000
    assert worker != Process.whereis(Logger)

    assert_receive {:request, ^worker, "https://api.raygun.io/entries", payload, headers,
                    options},
                   1_000

    assert payload["details"]["error"]["message"] == "hello"
    assert headers[:"Content-Type"] == "application/json; charset=utf-8"
    assert options[:timeout] == 2_000
    assert options[:recv_timeout] == 5_000
    eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
  end

  test "network and callback deadlines free capacity and allow the next report", %{
    manager: manager
  } do
    for message <- ["network block", "callback block"] do
      Application.put_env(:raygun, :test_mode, :block)
      emit(manager, message)
      assert_receive {:callback, worker, ^message}, 1_000
      ref = Process.monitor(worker)
      if message == "network block", do: assert_receive({:request, ^worker, _, _, _, _}, 1_000)
      Application.put_env(:raygun, :test_mode, :ok)
      assert_receive {:DOWN, ^ref, _, ^worker, :killed}, 1_000
      eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
      emit(manager, "next")

      assert_receive {:request, _, _, %{"details" => %{"error" => %{"message" => "next"}}}, _, _},
                     1_000

      eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
    end

    assert Raygun.Reporter.stats().timed_out == 2
  end

  test "TLS errors, unexpected responses, exceptions and exits do not leak slots", %{
    manager: manager
  } do
    for mode <- [:tls, 500, :raise, :exit] do
      Application.put_env(:raygun, :test_mode, mode)
      emit(manager, "failure")
      assert_receive {:request, _, _, _, _, _}, 1_000
      eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
    end

    assert Process.alive?(Process.whereis(Raygun.Reporter))
    send(Raygun.Reporter, {:expire, make_ref()})
    send(Raygun.Reporter, {:DOWN, make_ref(), :process, self(), :normal})
    assert Raygun.Reporter.stats().pending == 0
  end

  test "transport logs are excluded from the real Logger backend" do
    Application.put_env(:raygun, :test_mode, :log)
    {:ok, _} = Logger.add_backend(Raygun.Logger)
    Logger.error("initial")
    assert_receive {:request, _, _, _, _, _}, 1_000
    eventually(fn -> Raygun.Reporter.stats().internal > 0 end)
    refute_receive {:request, _, _, _, _, _}, 100
  end

  test "concurrent producers cannot exceed admission capacity" do
    Application.put_env(:raygun, :test_mode, :block)

    producers =
      for _ <- 1..20 do
        Task.async(fn ->
          for _ <- 1..20, do: Raygun.Reporter.submit("concurrent", [])
        end)
      end

    Enum.each(producers, &Task.await/1)
    assert Raygun.Reporter.stats().pending == 4
    assert Raygun.Reporter.stats().accepted == 4
    assert_receive {:request, worker, _, _, _, _}, 1_000
    Process.exit(worker, :kill)
    assert_receive {:request, next_worker, _, _, _, _}, 1_000
    assert next_worker != worker
    eventually(fn -> Raygun.Reporter.stats().pending == 3 end)
  end

  test "exception and charlist events keep their payload formats", %{manager: manager} do
    emit(manager, ~c"charlist")

    assert_receive {:request, _, _, %{"details" => %{"error" => %{"message" => "charlist"}}}, _,
                    _},
                   1_000

    emit(manager, %RuntimeError{message: "exception"})

    assert_receive {:request, _, _,
                    %{"details" => %{"error" => %{"message" => "exception", "stackTrace" => []}}},
                    _, _},
                   1_000

    emit(manager, "filtered")
    assert_receive {:callback, _, "filtered"}, 1_000
    refute_receive {:request, _, _, _, _, _}, 30
  end

  test "unmarked dependency errors are globally rate limited" do
    for _ <- 1..300, do: Raygun.Reporter.submit("dependency", [])
    assert Raygun.Reporter.stats().rate_limited == 200
    assert Raygun.Reporter.stats().pending <= 4
  end

  test "absent application, raw oversized payload and callback-expanded payload are safe", %{
    manager: manager
  } do
    emit(manager, String.duplicate("x", 20_000))
    assert Raygun.Reporter.stats().oversized == 1
    Application.put_env(:raygun, :tags, [String.duplicate("x", 20_000)])
    emit(manager, "encoded too large")
    assert_receive {:callback, _, "encoded too large"}, 1_000
    eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
    refute_receive {:request, _, _, _, _, _}, 30
    Application.stop(:raygun)
    assert :ok = emit(manager, "absent")
    assert_receive {:witness, {:error, _, {Logger, "absent", _, _}}}, 300
  end

  test "dispatcher restart kills old workers and creates a fresh admission table", %{
    manager: manager
  } do
    Application.put_env(:raygun, :test_mode, :block)
    emit(manager, "blocked")
    assert_receive {:request, worker, _, _, _, _}, 1_000
    dispatcher = Process.whereis(Raygun.Reporter)
    Process.exit(dispatcher, :kill)
    eventually(fn -> Process.whereis(Raygun.Reporter) not in [nil, dispatcher] end)
    eventually(fn -> not Process.alive?(worker) end)
    Application.put_env(:raygun, :test_mode, :ok)
    emit(manager, "restarted")

    assert_receive {:request, _, _, %{"details" => %{"error" => %{"message" => "restarted"}}}, _,
                    _},
                   1_000

    eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
  end

  test "cancellation closes the real HTTP connection without waiting for the receive timeout", %{
    manager: manager
  } do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    owner = self()

    server =
      spawn_monitor(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        send(owner, :connected)
        drain_socket(socket, owner)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(elem(server, 0), :kill)
    end)

    Application.put_env(:raygun, :transport, LocalHTTPTransport)
    Application.put_env(:raygun, :test_url, "http://127.0.0.1:#{port}/entries")
    Application.put_env(:raygun, :httpoison_opts, recv_timeout: 30_000)
    emit(manager, "real local HTTP")
    assert_receive :connected, 1_000
    assert_receive :socket_closed, 2_000
    eventually(fn -> Raygun.Reporter.stats().pending == 0 end)
    assert Raygun.Reporter.stats().timed_out == 1
  end

  defp drain_socket(socket, owner) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, _bytes} -> drain_socket(socket, owner)
      {:error, :closed} -> send(owner, :socket_closed)
      other -> send(owner, {:socket_error, other})
    end
  end

  test "application shutdown is bounded with an unresponsive transport", %{manager: manager} do
    Application.put_env(:raygun, :test_mode, :block)
    emit(manager, "blocked")
    assert_receive {:request, worker, _, _, _, _}, 1_000
    {micros, :ok} = :timer.tc(fn -> Application.stop(:raygun) end)
    assert micros < 2_000_000
    refute Process.alive?(worker)
  end
end
