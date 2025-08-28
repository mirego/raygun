defmodule Raygun.Mixfile do
  use Mix.Project

  def project do
    [
      app: :raygun,
      version: "0.4.0",
      elixir: "~> 1.18",
      source_url: "https://github.com/cobenian/raygun",
      description: description(),
      package: package(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: preferred_cli_env(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [
      extra_applications: [:logger, :httpoison, :plug]
    ]
  end

  defp description do
    """
    Send errors in your application to Raygun.

    Raygun captures all your application errors in one place. It can be used as
    a Plug, via Logger and/or programmatically.
    """
  end

  defp preferred_cli_env do
    [
      coveralls: :test,
      "coveralls.detail": :test,
      "coveralls.post": :test,
      "coveralls.html": :test
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type `mix help deps` for more examples and options
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:httpoison, "~> 1.5"},
      {:plug, "~> 1.14"},
      {:earmark, "~> 1.4", only: :dev},
      {:ex_doc, "~> 0.30", only: :dev},
      {:meck, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    # These are the default files included in the package
    [
      maintainers: ["Bryan Weber"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/cobenian/raygun"}
    ]
  end
end
