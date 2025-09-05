defmodule RaygunTest do
  use ExUnit.Case
  import :meck

  defmodule MyAppError do
    defexception [:message]
  end

  defmodule BeforeSendModule do
    def exclude_error(_error), do: :excluded
  end

  setup do
    new([HTTPoison, Jason, Raygun.Format])

    original_before_send = Application.get_env(:raygun, :before_send)

    on_exit(fn ->
      unload()

      if original_before_send do
        Application.put_env(:raygun, :before_send, original_before_send)
      else
        Application.delete_env(:raygun, :before_send)
      end
    end)

    :ok
  end

  test "report_stacktrace with successful response" do
    response = %HTTPoison.Response{status_code: 202}

    expect(Raygun.Format, :stacktrace_payload, [:stacktrace, :error, []], :payload)
    expect(Jason, :encode!, [:payload], :json)
    expect(HTTPoison, :post, ["https://api.raygun.io/entries", :json, :_, []], {:ok, response})

    assert Raygun.report_stacktrace(:stacktrace, :error) == :ok
  end

  test "report_stacktrace with before_send callback that excludes error" do
    Application.put_env(:raygun, :before_send, {BeforeSendModule, :exclude_error})

    assert num_calls(HTTPoison, :post, :_) == 0
    assert num_calls(Jason, :encode!, :_) == 0
    assert num_calls(Raygun.Format, :stacktrace_payload, :_) == 0

    assert Raygun.report_stacktrace(:stacktrace, :error) == :excluded
  end
end
