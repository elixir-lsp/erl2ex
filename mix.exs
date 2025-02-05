defmodule Erl2exVendored.Mixfile do
  use Mix.Project

  def project do
    [
      app: :erl2ex_vendored,
      version: "0.0.10",
      elixir: "~> 1.4",
      name: "Erl2exVendored",
      source_url: "https://github.com/dazuma/erl2ex",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Erl2exVendored.Cli],
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [applications: [:logger, :syntax_tools]]
  end

  defp deps do
    [
      {:earmark, "~> 1.0", only: :dev},
      {:ex_doc, "~> 0.13", only: :dev},
      {:credo, "~> 0.4", only: :dev}
    ]
  end

  defp docs do
    [
      extras: ["README.md", "LICENSE.md", "CHANGELOG.md"]
    ]
  end

  defp description do
    """
    Erl2exVendored is an Erlang to Elixir transpiler, converting well-formed Erlang
    source to Elixir source with equivalent functionality.
    """
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md", "CHANGELOG.md"],
      maintainers: ["Daniel Azuma"],
      licenses: ["BSD"],
      links: %{"GitHub" => "https://github.com/dazuma/erl2ex"}
    ]
  end
end
