defmodule SymphonyElixirWeb.LinearAgentWebhookController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Linear.{AgentBridge, WebhookVerifier}
  alias SymphonyElixirWeb.RawBodyReader

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    signature = conn |> get_req_header("linear-signature") |> List.first()
    timestamp = params["webhookTimestamp"] || conn |> get_req_header("linear-timestamp") |> List.first()

    case WebhookVerifier.verify(RawBodyReader.body(conn), signature, timestamp) do
      :ok ->
        :ok = AgentBridge.accept_webhook(params)
        json(conn, %{accepted: true})

      {:error, :linear_agent_disabled} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "not_found", message: "Route not found"}})

      {:error, _reason} ->
        conn
        |> put_status(401)
        |> json(%{error: %{code: "invalid_signature", message: "Invalid webhook signature"}})
    end
  end
end
