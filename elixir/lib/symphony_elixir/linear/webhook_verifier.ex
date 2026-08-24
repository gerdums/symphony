defmodule SymphonyElixir.Linear.WebhookVerifier do
  @moduledoc false

  alias SymphonyElixir.Config

  @spec verify(binary(), String.t() | nil, term(), keyword()) :: :ok | {:error, term()}
  def verify(raw_body, signature, timestamp, opts \\ [])
      when is_binary(raw_body) do
    settings = Keyword.get_lazy(opts, :agent_settings, fn -> Config.settings!().linear_agent end)
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))

    with :ok <- enabled(settings),
         {:ok, provided_signature} <- decode_signature(signature),
         expected_signature <- :crypto.mac(:hmac, :sha256, settings.webhook_secret, raw_body),
         true <- Plug.Crypto.secure_compare(expected_signature, provided_signature),
         {:ok, webhook_timestamp} <- normalize_timestamp(timestamp),
         true <- abs(now_ms - webhook_timestamp) <= settings.webhook_max_age_ms do
      :ok
    else
      false -> {:error, :invalid_linear_webhook}
      {:error, _reason} = error -> error
    end
  end

  defp enabled(%{enabled: true, webhook_secret: secret})
       when is_binary(secret) and secret != "",
       do: :ok

  defp enabled(%{enabled: false}), do: {:error, :linear_agent_disabled}
  defp enabled(_settings), do: {:error, :missing_linear_agent_webhook_secret}

  defp decode_signature(signature) when is_binary(signature) do
    case Base.decode16(signature, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _ -> {:error, :invalid_linear_webhook_signature}
    end
  end

  defp decode_signature(_signature), do: {:error, :missing_linear_webhook_signature}

  defp normalize_timestamp(timestamp) when is_integer(timestamp), do: {:ok, timestamp}
  defp normalize_timestamp(timestamp) when is_float(timestamp), do: {:ok, trunc(timestamp)}

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_linear_webhook_timestamp}
    end
  end

  defp normalize_timestamp(_timestamp), do: {:error, :invalid_linear_webhook_timestamp}
end
