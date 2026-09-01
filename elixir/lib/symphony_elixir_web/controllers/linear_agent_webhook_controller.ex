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
        respond_to_recording(conn, record_webhook(params))

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

  defp record_webhook(params) do
    case Application.get_env(:symphony_elixir, :linear_agent_webhook_bridge, AgentBridge) do
      {module, server} when is_atom(module) -> module.accept_webhook(params, server)
      module when is_atom(module) -> module.accept_webhook(params)
    end
  catch
    :exit, reason -> {:error, {:bridge_unavailable, reason}}
  end

  defp respond_to_recording(conn, :ok), do: json(conn, %{accepted: true})

  defp respond_to_recording(conn, {:error, _reason}) do
    conn
    |> put_status(503)
    |> json(%{
      error: %{
        code: "webhook_recording_unavailable",
        message: "Webhook could not be recorded"
      }
    })
  end
end
