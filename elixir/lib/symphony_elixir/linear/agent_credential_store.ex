defmodule SymphonyElixir.Linear.AgentCredentialStore do
  @moduledoc """
  Caches and renews Linear client-credentials tokens for the native agent.

  The OAuth client secret remains in the coordinator process. Workers receive
  neither the secret nor the short-lived access token.
  """

  use GenServer

  defstruct access_token: nil,
            expires_at_ms: 0,
            credential_key: nil,
            request_fun: nil

  @renewal_margin_ms 60_000

  @type state :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec token(map(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def token(settings, server \\ __MODULE__) when is_map(settings) do
    case Map.get(settings, :access_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> GenServer.call(server, {:token, settings}, 35_000)
    end
  end

  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  end

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{request_fun: Keyword.get(opts, :request_fun)}}
  end

  @impl true
  def handle_call({:token, settings}, _from, state) do
    credential_key = credential_key(settings)
    now_ms = System.monotonic_time(:millisecond)

    if reusable_token?(state, credential_key, now_ms) do
      {:reply, {:ok, state.access_token}, state}
    else
      case request_token(settings, state.request_fun) do
        {:ok, access_token, expires_in_seconds} ->
          state = %{
            state
            | access_token: access_token,
              expires_at_ms: now_ms + expires_in_seconds * 1_000,
              credential_key: credential_key
          }

          {:reply, {:ok, access_token}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, clear_token(state)}
      end
    end
  end

  @impl true
  def handle_cast(:invalidate, state) do
    {:noreply, clear_token(state)}
  end

  defp reusable_token?(state, credential_key, now_ms) do
    is_binary(state.access_token) and state.credential_key == credential_key and
      state.expires_at_ms - @renewal_margin_ms > now_ms
  end

  defp request_token(settings, request_fun) do
    with {:ok, client_id} <- required_setting(settings, :oauth_client_id),
         {:ok, client_secret} <- required_setting(settings, :client_secret),
         {:ok, token_endpoint} <- required_setting(settings, :token_endpoint),
         scopes when is_list(scopes) <- Map.get(settings, :scopes),
         {:ok, %{status: 200, body: body}} <-
           token_request(request_fun).(
             token_endpoint,
             %{
               "grant_type" => "client_credentials",
               "client_id" => client_id,
               "client_secret" => client_secret,
               "scope" => Enum.join(scopes, ",")
             }
           ),
         {:ok, access_token, expires_in} <- normalize_token_response(body) do
      {:ok, access_token, expires_in}
    else
      {:ok, %{status: status}} -> {:error, {:linear_agent_token_status, status}}
      {:error, _reason} = error -> error
      other -> {:error, {:linear_agent_token_response, other}}
    end
  end

  defp token_request(request_fun) when is_function(request_fun, 2), do: request_fun

  defp token_request(_request_fun) do
    fn endpoint, form ->
      Req.post(endpoint, form: form, connect_options: [timeout: 30_000])
    end
  end

  defp normalize_token_response(%{"access_token" => access_token, "expires_in" => expires_in})
       when is_binary(access_token) and access_token != "" and is_integer(expires_in) and
              expires_in > 0 do
    {:ok, access_token, expires_in}
  end

  defp normalize_token_response(body), do: {:error, {:linear_agent_invalid_token_payload, body}}

  defp required_setting(settings, key) do
    case Map.get(settings, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_linear_agent_setting, key}}
    end
  end

  defp credential_key(settings) do
    {
      Map.get(settings, :oauth_client_id),
      Map.get(settings, :client_secret),
      Map.get(settings, :token_endpoint),
      Map.get(settings, :scopes)
    }
  end

  defp clear_token(state) do
    %{state | access_token: nil, expires_at_ms: 0, credential_key: nil}
  end
end
