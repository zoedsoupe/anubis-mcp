defmodule Peri.MixProject do
  use Mix.Project

  @version "0.11.3"
  @source_url "https://github.com/zoedsoupe/peri"

  def project do
    [
      app: :peri,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      deps: deps(),
      package: package(),
      description: description(),
      source_url: @source_url,
      dialyzer: [plt_local_path: "priv/plts", ignore_warnings: ".dialyzerignore"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.0", optional: true},
      {:stream_data, "~> 1.1", optional: true},
      {:ecto, "~> 3.12", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:benchee, "~> 1.0", only: :dev},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "A Plug'n Play schema validator library, focused on raw data structures"
  end

  defp package do
    [
      name: "peri",
      links: %{"GitHub" => @source_url},
      licenses: ["MIT"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "pages/types.md",
        "pages/validation.md",
        "pages/ecto.md",
        "pages/phoenix.md",
        "pages/generation.md",
        "pages/json_schema.md",
        "pages/refs.md"
      ],
      groups_for_extras: [
        Guides: ~r/pages\/.*/
      ],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
