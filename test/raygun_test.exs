defmodule RaygunTest do
  use ExUnit.Case, async: false
  import :meck

  defmodule BeforeSendModule do
    def exclude_error(_error), do: :excluded
  end

  setup do
    new([HTTPoison], [:passthrough])
    saved = Application.get_all_env(:raygun)
    Application.delete_env(:raygun, :before_send)

    on_exit(fn ->
      unload()
      for {key, _} <- Application.get_all_env(:raygun), do: Application.delete_env(:raygun, key)
      for {key, value} <- saved, do: Application.put_env(:raygun, key, value)
    end)

    :ok
  end

  test "public APIs synchronously return the HTTP result and preserve payloads" do
    owner = self()

    expect(HTTPoison, :post, fn url, body, headers, options ->
      send(owner, {:post, url, Jason.decode!(body), headers, options})
      {:ok, %HTTPoison.Response{status_code: 202}}
    end)

    assert :ok = Raygun.report_message("message", context: "value")

    assert_received {:post, "https://api.raygun.io/entries", payload, _,
                     [timeout: 2_000, recv_timeout: 5_000]}

    assert payload["details"]["userCustomData"] == %{"context" => "value"}
    assert :ok = Raygun.report_stacktrace([], %RuntimeError{message: "exception"})
    assert :ok = apply(Raygun, :report_exception, [%RuntimeError{message: "deprecated"}])

    assert :ok =
             Raygun.report_plug(Plug.Test.conn(:get, "/test"), [], %RuntimeError{message: "plug"})

    assert num_calls(HTTPoison, :post, :_) == 4
  end

  test "all public APIs preserve the callback's exclusion return" do
    Application.put_env(:raygun, :before_send, {BeforeSendModule, :exclude_error})
    assert :excluded = Raygun.report_message("excluded")
    assert :excluded = Raygun.report_stacktrace([], %RuntimeError{})
    assert :excluded = apply(Raygun, :report_exception, [%RuntimeError{}])
    assert :excluded = Raygun.report_plug(Plug.Test.conn(:get, "/"), [], %RuntimeError{})
    assert num_calls(HTTPoison, :post, :_) == 0
  end

  test "HTTP options override defaults without removing the other defaults" do
    Application.put_env(:raygun, :httpoison_opts, timeout: 123, hackney: [pool: false])

    expect(HTTPoison, :post, fn _, _, _, options ->
      assert options[:timeout] == 123
      assert options[:recv_timeout] == 5_000
      assert options[:hackney] == [pool: false]
      {:ok, %HTTPoison.Response{status_code: 202}}
    end)

    assert :ok = Raygun.report_message("options")
  end

  test "HTTP errors, unexpected responses and transport failures have controlled returns" do
    for {response, result} <- [
          {{:ok, %HTTPoison.Response{status_code: 400}}, {:error, :bad_message}},
          {{:ok, %HTTPoison.Response{status_code: 403}}, {:error, :invalid_api_key}},
          {{:ok, %HTTPoison.Response{status_code: 500}}, {:error, :unexpected}},
          {{:error, %HTTPoison.Error{reason: :tls_alert}}, {:error, :unexpected}}
        ] do
      expect(HTTPoison, :post, fn _, _, _, _ -> response end)
      assert Raygun.report_message("failure") == result
    end

    expect(HTTPoison, :post, fn _, _, _, _ -> raise "failure" end)
    assert {:error, :unexpected} = Raygun.report_message("raised")
  end
end
