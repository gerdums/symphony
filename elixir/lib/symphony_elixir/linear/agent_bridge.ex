defmodule SymphonyElixir.Linear.AgentBridge do
  @moduledoc """
  Owns the mapping between Linear agent sessions and Symphony issue runs.

  Linear is the durable, machine-independent conversation. Local or SSH workers
  can restart or move without changing the session that users see on the issue.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.AgentClient
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue

  defstruct client: AgentClient,
            client_opts: [],
            orchestrator: Orchestrator,
            sessions_by_issue: %{},
            issue_by_session: %{},
            pending_prompts: %{},
            proof_counts: %{},
            seen_webhooks: MapSet.new()

  @type state :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec accept_webhook(map(), GenServer.server()) :: :ok
  def accept_webhook(payload, server \\ __MODULE__) when is_map(payload) do
    GenServer.cast(server, {:accept_webhook, payload})
  end

  @spec ensure_session(Issue.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()} | :disabled
  def ensure_session(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.call(server, {:ensure_session, issue}, 35_000)
  end

  @spec start_work(Issue.t(), GenServer.server()) :: :ok | {:error, term()} | :disabled
  def start_work(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.call(server, {:start_work, issue}, 35_000)
  end

  @spec session_for_issue(String.t(), GenServer.server()) :: String.t() | nil
  def session_for_issue(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:session_for_issue, issue_id})
  end

  @spec take_prompt(String.t(), GenServer.server()) :: {:ok, map()} | :empty
  def take_prompt(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:take_prompt, issue_id})
  end

  @spec report_codex_update(String.t(), map(), GenServer.server()) :: :ok
  def report_codex_update(issue_id, update, server \\ __MODULE__)
      when is_binary(issue_id) and is_map(update) do
    GenServer.cast(server, {:codex_update, issue_id, update})
  end

  @spec record_proof(String.t(), String.t(), String.t(), GenServer.server()) ::
          :ok | {:error, term()} | :disabled
  def record_proof(issue_id, asset_url, caption, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(asset_url) and is_binary(caption) do
    GenServer.call(server, {:record_proof, issue_id, asset_url, caption}, 35_000)
  end

  @spec proof_satisfied?(String.t(), GenServer.server()) :: boolean()
  def proof_satisfied?(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:proof_satisfied, issue_id})
  end

  @spec complete(String.t(), String.t(), GenServer.server()) ::
          :ok | {:error, term()} | :disabled
  def complete(issue_id, summary, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(summary) do
    GenServer.call(server, {:complete, issue_id, summary}, 35_000)
  end

  @spec fail(String.t(), String.t(), GenServer.server()) :: :ok
  def fail(issue_id, message, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(message) do
    GenServer.cast(server, {:activity, issue_id, %{"type" => "error", "body" => message}, []})
  end

  @spec prompt_guidance() :: String.t() | nil
  def prompt_guidance do
    settings = Config.settings!().linear_agent

    if settings.enabled and settings.proof.required do
      minimum = settings.proof.minimum_screenshots

      """
      Native Linear agent session requirements:

      - Report meaningful progress through the native Linear agent session; Symphony forwards execution activity automatically.
      - Before claiming completion or moving the issue to a terminal state, call `linear_agent_proof` with at least #{minimum} screenshot(s) from the current workspace.
      - Screenshot proof is mandatory. Capture the changed behavior or the strongest visual validation available, and include a concise caption explaining what it proves.
      - Follow-up prompts sent from the Linear agent session are live instructions for this same run.
      """
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       client: Keyword.get(opts, :client, AgentClient),
       client_opts: Keyword.get(opts, :client_opts, []),
       orchestrator: Keyword.get(opts, :orchestrator, Orchestrator)
     }}
  end

  @impl true
  def handle_call({:ensure_session, %Issue{id: issue_id}}, _from, state) do
    settings = Config.settings!().linear_agent

    cond do
      !settings.enabled ->
        {:reply, :disabled, state}

      session_id = state.sessions_by_issue[issue_id] ->
        {:reply, {:ok, session_id}, state}

      true ->
        case find_or_create_session(state, issue_id, settings.app_user_id) do
          {:ok, %{"id" => session_id}} when is_binary(session_id) ->
            state = put_session(state, issue_id, session_id)
            {:reply, {:ok, session_id}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          other ->
            {:reply, {:error, {:invalid_agent_session_response, other}}, state}
        end
    end
  end

  def handle_call({:start_work, %Issue{id: issue_id}}, _from, state) do
    settings = Config.settings!().linear_agent

    cond do
      !settings.enabled ->
        {:reply, :disabled, state}

      !settings.assign_on_start ->
        {:reply, :ok, state}

      is_nil(session_id(state, issue_id)) ->
        {:reply, {:error, :missing_linear_agent_session}, state}

      true ->
        result = assign_issue_to_app(state, issue_id, settings.app_user_id)
        {:reply, result, state}
    end
  end

  def handle_call({:session_for_issue, issue_id}, _from, state) do
    {:reply, state.sessions_by_issue[issue_id], state}
  end

  def handle_call({:take_prompt, issue_id}, _from, state) do
    case Map.get(state.pending_prompts, issue_id, []) do
      [prompt | rest] ->
        pending_prompts =
          if rest == [] do
            Map.delete(state.pending_prompts, issue_id)
          else
            Map.put(state.pending_prompts, issue_id, rest)
          end

        {:reply, {:ok, prompt}, %{state | pending_prompts: pending_prompts}}

      [] ->
        {:reply, :empty, state}
    end
  end

  def handle_call({:record_proof, issue_id, asset_url, caption}, _from, state) do
    case session_id(state, issue_id) do
      nil ->
        {:reply, :disabled, state}

      agent_session_id ->
        content = %{
          "type" => "action",
          "action" => "Captured proof",
          "parameter" => caption,
          "result" => "![#{escape_alt_text(caption)}](#{asset_url})"
        }

        case create_activity(state, agent_session_id, content) do
          :ok ->
            proof_counts = Map.update(state.proof_counts, issue_id, 1, &(&1 + 1))
            {:reply, :ok, %{state | proof_counts: proof_counts}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:proof_satisfied, issue_id}, _from, state) do
    {:reply, proof_satisfied_in_state?(state, issue_id), state}
  end

  def handle_call({:complete, issue_id, summary}, _from, state) do
    case session_id(state, issue_id) do
      nil ->
        {:reply, :disabled, state}

      agent_session_id ->
        if proof_satisfied_in_state?(state, issue_id) do
          result = create_activity(state, agent_session_id, %{"type" => "response", "body" => summary})
          {:reply, result, state}
        else
          minimum = Config.settings!().linear_agent.proof.minimum_screenshots

          _ =
            create_activity(state, agent_session_id, %{
              "type" => "error",
              "body" => "Completion was withheld because the required screenshot proof was not uploaded (minimum: #{minimum})."
            })

          {:reply, {:error, :proof_required}, state}
        end
    end
  end

  @impl true
  def handle_cast({:accept_webhook, payload}, state) do
    {:noreply, handle_webhook(payload, state)}
  end

  def handle_cast({:codex_update, issue_id, update}, state) do
    case session_id(state, issue_id) do
      agent_session_id when is_binary(agent_session_id) ->
        publish_codex_update(state, agent_session_id, update)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:activity, issue_id, content, opts}, state) do
    case session_id(state, issue_id) do
      agent_session_id when is_binary(agent_session_id) ->
        _ = create_activity(state, agent_session_id, content, opts)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp publish_codex_update(state, agent_session_id, update) do
    case plan_for_update(update) do
      plan when is_list(plan) ->
        _ = state.client.update_session(agent_session_id, %{"plan" => plan}, client_opts(state))

      nil ->
        publish_codex_activity(state, agent_session_id, update)
    end
  end

  defp publish_codex_activity(state, agent_session_id, update) do
    case activity_for_update(update) do
      %{} = content ->
        _ = create_activity(state, agent_session_id, content, ephemeral: ephemeral_update?(update))

      nil ->
        :ok
    end
  end

  defp handle_webhook(payload, state) do
    settings = Config.settings!().linear_agent
    webhook_id = payload["webhookId"]

    cond do
      !settings.enabled ->
        state

      is_binary(webhook_id) and MapSet.member?(state.seen_webhooks, webhook_id) ->
        state

      payload["oauthClientId"] != settings.oauth_client_id ->
        Logger.warning("Ignoring Linear agent webhook for a different OAuth client")
        state

      payload["appUserId"] != settings.app_user_id ->
        Logger.warning("Ignoring Linear agent webhook for a different app user")
        state

      true ->
        state
        |> remember_webhook(webhook_id)
        |> register_webhook_session(payload)
        |> enqueue_webhook_prompt(payload)
    end
  end

  defp register_webhook_session(state, %{
         "agentSession" => %{"id" => session_id, "issueId" => issue_id}
       })
       when is_binary(session_id) and is_binary(issue_id) do
    newly_registered? = state.sessions_by_issue[issue_id] != session_id
    display_name = Config.settings!().linear_agent.display_name
    state = put_session(state, issue_id, session_id)

    if newly_registered? do
      _ =
        create_activity(
          state,
          session_id,
          %{
            "type" => "thought",
            "body" => "#{display_name} received this ticket and is preparing an agent."
          },
          ephemeral: true
        )
    end

    state
  end

  defp register_webhook_session(state, _payload), do: state

  defp enqueue_webhook_prompt(state, payload) do
    with action when action in ["created", "prompted"] <- payload["action"],
         %{"id" => session_id, "issueId" => issue_id} <- payload["agentSession"],
         true <- is_binary(session_id) and is_binary(issue_id),
         {:ok, prompt} <- webhook_prompt(payload, action) do
      prompt_entry = %{
        id: get_in(payload, ["agentActivity", "id"]) || payload["webhookId"],
        body: prompt,
        action: action
      }

      pending_prompts = Map.update(state.pending_prompts, issue_id, [prompt_entry], &(&1 ++ [prompt_entry]))
      notify_orchestrator(state.orchestrator, issue_id)
      %{state | pending_prompts: pending_prompts}
    else
      _ -> state
    end
  end

  defp webhook_prompt(payload, "created") do
    normalize_prompt(payload["promptContext"])
  end

  defp webhook_prompt(payload, "prompted") do
    normalize_prompt(get_in(payload, ["agentActivity", "content", "body"]))
  end

  defp normalize_prompt(prompt) when is_binary(prompt) do
    case String.trim(prompt) do
      "" -> :empty
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_prompt(_prompt), do: :empty

  defp notify_orchestrator(orchestrator, issue_id) when is_atom(orchestrator) do
    if Process.whereis(orchestrator) do
      Orchestrator.linear_agent_prompt_available(issue_id, orchestrator)
    end
  end

  defp notify_orchestrator(_orchestrator, _issue_id), do: :ok

  defp activity_for_update(%{event: :session_started}) do
    %{"type" => "thought", "body" => "A Codex worker started this task."}
  end

  defp activity_for_update(%{event: :turn_input_required}) do
    %{
      "type" => "elicitation",
      "body" => "The agent needs additional input. Reply in this session to continue the same run."
    }
  end

  defp activity_for_update(%{event: :run_finished, outcome: :active}) do
    %{
      "type" => "thought",
      "body" => "This worker batch ended while the issue is still active. Symphony will continue in the same session."
    }
  end

  defp activity_for_update(%{event: :run_finished, outcome: :inactive}) do
    %{
      "type" => "thought",
      "body" => "The run paused because the issue is no longer eligible for dispatch. The agent session remains attached to the issue."
    }
  end

  defp activity_for_update(%{event: :run_finished, outcome: :terminal}), do: nil

  defp activity_for_update(%{event: event}) when event in [:startup_failed, :turn_failed, :turn_ended_with_error] do
    %{"type" => "error", "body" => "The Codex worker encountered an error. Symphony will preserve the session for recovery."}
  end

  defp activity_for_update(%{event: :notification, details: %{payload: payload}}) do
    action_for_notification(payload)
  end

  defp activity_for_update(_update), do: nil

  defp action_for_notification(%{"method" => "item/started", "params" => %{"item" => item}})
       when is_map(item) do
    case item["type"] do
      "commandExecution" ->
        %{"type" => "action", "action" => "Running command", "parameter" => "Workspace validation"}

      "fileChange" ->
        %{"type" => "action", "action" => "Editing files", "parameter" => "Applying implementation changes"}

      "mcpToolCall" ->
        %{"type" => "action", "action" => "Using a connected tool", "parameter" => "External verification"}

      _ ->
        nil
    end
  end

  defp action_for_notification(_payload), do: nil

  defp ephemeral_update?(%{event: :session_started}), do: true
  defp ephemeral_update?(%{event: :notification}), do: true
  defp ephemeral_update?(_update), do: false

  defp plan_for_update(%{
         event: :notification,
         details: %{
           payload: %{"method" => "turn/plan/updated", "params" => %{"plan" => plan}}
         }
       })
       when is_list(plan) do
    Enum.flat_map(plan, fn
      %{"step" => content, "status" => status}
      when is_binary(content) and status in ["pending", "inProgress", "completed"] ->
        [%{"content" => content, "status" => status}]

      _ ->
        []
    end)
  end

  defp plan_for_update(_update), do: nil

  defp create_activity(state, agent_session_id, content, opts \\ []) do
    case state.client.create_activity(agent_session_id, content, client_opts(state, opts)) do
      {:ok, _activity} ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to publish Linear agent activity: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp client_opts(state, opts \\ []) do
    Keyword.merge(state.client_opts, opts)
  end

  defp find_or_create_session(state, issue_id, app_user_id) do
    case state.client.find_open_session(issue_id, app_user_id, client_opts(state)) do
      {:ok, %{} = session} -> {:ok, session}
      :not_found -> state.client.create_session(issue_id, client_opts(state))
      {:error, reason} -> {:error, {:linear_agent_session_lookup_failed, reason}}
    end
  end

  defp assign_issue_to_app(state, issue_id, app_user_id) do
    case state.client.assign_issue(issue_id, app_user_id, client_opts(state)) do
      {:ok, %{"assignee" => %{"id" => ^app_user_id}}} ->
        :ok

      {:ok, issue} ->
        {:error, {:linear_agent_assignment_not_applied, issue}}

      {:error, reason} ->
        {:error, {:linear_agent_assignment_failed, reason}}
    end
  end

  defp put_session(state, issue_id, session_id) do
    %{
      state
      | sessions_by_issue: Map.put(state.sessions_by_issue, issue_id, session_id),
        issue_by_session: Map.put(state.issue_by_session, session_id, issue_id)
    }
  end

  defp session_id(state, issue_id), do: state.sessions_by_issue[issue_id]

  defp remember_webhook(state, webhook_id) when is_binary(webhook_id) do
    %{state | seen_webhooks: MapSet.put(state.seen_webhooks, webhook_id)}
  end

  defp remember_webhook(state, _webhook_id), do: state

  defp proof_satisfied_in_state?(state, issue_id) do
    proof = Config.settings!().linear_agent.proof
    !proof.required or Map.get(state.proof_counts, issue_id, 0) >= proof.minimum_screenshots
  end

  defp escape_alt_text(caption) do
    String.replace(caption, ["]", "["], "")
  end
end
