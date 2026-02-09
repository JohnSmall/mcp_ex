defmodule McpEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_ex,
      version: "0.2.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:elixir_uuid, "~> 1.2"},

      # Optional: Streamable HTTP transport
      {:req, "~> 0.5", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.5", optional: true},

      # Dev/test
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
