defmodule Raygun.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      Raygun.Reporter,
      {Task.Supervisor, name: Raygun.TaskSupervisor, max_children: reporter_concurrency()}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Raygun.Supervisor)
  end

  defp reporter_concurrency do
    Application.get_env(:raygun, :reporter, []) |> Keyword.get(:concurrency, 2)
  end
end
