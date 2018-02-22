defmodule RabbitExchangeTypeMessageDeduplication.Mixfile do
  use Mix.Project

  def project do
    deps_dir = case System.get_env("DEPS_DIR") do
      nil -> "deps"
      dir -> dir
    end

    [
      app: :rabbitmq_message_deduplication_exchange,
      version: "0.0.1",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps_path: deps_dir,
      deps: deps(deps_dir),
      aliases: aliases()
    ]
  end

  def application do
    [
      applications: [:cachex, :rabbit],
      mod: {RabbitExchangeTypeMessageDeduplication, []},
      env: [exchange: "x-message-deduplication"],
    ]
  end

  defp deps(deps_dir) do
    [
      {:cachex, "~> 3.0.0"},
      {
        :rabbit,
        path: Path.join(deps_dir, "rabbit"),
        compile: "true",
        override: true
      },
      {
        :rabbit_common,
        path: Path.join(deps_dir, "rabbit_common"),
        compile: "true",
        override: true
      }
    ]
  end

  defp aliases do
    [
      make_deps: [
        "deps.get",
        "deps.compile",
      ],
      make_app: [
        "compile",
      ],
      make_all: [
        "deps.get",
        "deps.compile",
        "compile",
      ],
    ]
  end
end