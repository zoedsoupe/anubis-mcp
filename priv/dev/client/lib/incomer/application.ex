defmodule Incomer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_, _) do
    children = [
      {Anubis.Client,
       name: Incomer.Client,
       transport: {:streamable_http, base_url: "http://localhost:4000"},
       client_info: %{"name" => "incomer", "version" => "0.1.0"},
       capabilities: %{},
       protocol_version: "2025-03-26"}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Incomer.Supervisor)
  end
end
