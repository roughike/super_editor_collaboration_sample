defmodule Collab.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Collab.DocumentSupervisor,
      # Start the Telemetry supervisor
      CollabWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Collab.PubSub},
      CollabWeb.Presence,
      # Start the Endpoint (http/https)
      CollabWeb.Endpoint
      # Start a worker by calling: Collab.Worker.start_link(arg)
      # {Collab.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Collab.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CollabWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
