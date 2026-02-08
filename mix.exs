defmodule McpEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_ex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      name: "MCP Ex",
      description: "Elixir implementation of the Model Context Protocol (MCP)",
      source_url: "https://github.com/JohnSmall/mcp_ex"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {McpEx.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:elixir_uuid, "~> 1.2"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
