defmodule ParallelSearch.MixProject do
  use Mix.Project

  def project do
    [app: :parallel_search, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:anubis_mcp, path: "../.."},
      {:finch, "~> 0.24"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
