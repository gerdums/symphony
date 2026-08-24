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
            waiting_issues: MapSet.new(),
            waiting_session_requests: MapSet.new(),
            checked_existing_waiting_sessions: MapSet.new(),
            open_session_reconciliation: :pending,
            work_started_issues: MapSet.new(),
            failure_notified_issues: MapSet.new(),
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

  @spec waiting_for_slot(Issue.t(), GenServer.server()) :: :ok
  def waiting_for_slot(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.cast(server, {:waiting_for_slot, issue})
  end

  @doc """
  Marks an already-open native session as waiting without creating a session
  for a ticket that has not been admitted yet.
  """
  @spec waiting_for_existing_slot(Issue.t(), GenServer.server()) :: :ok
  def waiting_for_existing_slot(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.cast(server, {:waiting_for_existing_slot, issue})
  end

  @doc """
  Reconnects this workflow's open native sessions after a coordinator restart
  and closes sessions whose issues are no longer eligible.
  """
  @spec reconcile_open_sessions([Issue.t()], GenServer.server()) :: :ok
  def reconcile_open_sessions(issues, server \\ __MODULE__) when is_list(issues) do
    issue_ids =
      Enum.flat_map(issues, fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)

    GenServer.call(server, {:reconcile_open_sessions, MapSet.new(issue_ids)}, 60_000)
  end

  @spec start_work(Issue.t(), GenServer.server()) :: :ok | {:error, term()} | :disabled
  def start_work(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.call(server, {:start_work, issue}, 35_000)
  end

  @spec setup_repair_started(String.t(), pos_integer(), pos_integer(), GenServer.server()) :: :ok
  def setup_repair_started(issue_id, attempt, total, server \\ __MODULE__)
      when is_binary(issue_id) and is_integer(attempt) and is_integer(total) do
    GenServer.cast(server, {:setup_repair_started, issue_id, attempt, total})
  end

  @spec setup_repair_succeeded(String.t(), GenServer.server()) :: :ok
  def setup_repair_succeeded(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.cast(server, {:setup_repair_succeeded, issue_id})
  end

  @spec session_for_issue(String.t(), GenServer.server()) :: String.t() | nil
  def session_for_issue(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:session_for_issue, issue_id})
  end

  @spec take_prompt(String.t(), GenServer.server()) :: {:ok, map()} | :empty
  def take_prompt(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:take_prompt, issue_id}, :infinity)
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

  @spec close(String.t(), String.t(), GenServer.server()) :: :ok
  def close(issue_id, summary, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(summary) do
    GenServer.cast(server, {:close, issue_id, summary})
  end

  @spec fail(String.t(), String.t(), GenServer.server()) :: :ok
  def fail(issue_id, message, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(message) do
    GenServer.cast(server, {:failure, issue_id, message})
  end

  @spec recovering(String.t(), GenServer.server()) :: :ok
  def recovering(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.cast(server, {:recovering, issue_id})
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
        case ensure_issue_session(state, issue_id, settings.app_user_id) do
          {:ok, session_id, state} -> {:reply, {:ok, session_id}, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:reconcile_open_sessions, eligible_issue_ids}, _from, state) do
    settings = Config.settings!()

    cond do
      !settings.linear_agent.enabled ->
        {:reply, :ok, state}

      state.open_session_reconciliation != :pending ->
        {:reply, :ok, state}

      true ->
        result =
          state.client.list_open_sessions(
            settings.linear_agent.app_user_id,
            settings.tracker.project_slug,
            client_opts(state)
          )

        {:reply, :ok, reconcile_open_session_result(state, eligible_issue_ids, result)}
    end
  end

  def handle_call({:start_work, %Issue{id: issue_id}}, _from, state) do
    settings = Config.settings!().linear_agent

    cond do
      !settings.enabled ->
        {:reply, :disabled, state}

      is_nil(session_id(state, issue_id)) ->
        {:reply, {:error, :missing_linear_agent_session}, state}

      true ->
        case maybe_assign_issue_to_app(state, issue_id, settings) do
          :ok ->
            state = announce_work_started(state, issue_id)
            {:reply, :ok, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
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
        proof_body =
          "#{safe_activity_text(caption, 1_000)}\n\n" <>
            "![#{escape_alt_text(caption)}](#{asset_url})"

        content = %{
          "type" => "action",
          "action" => "Screenshot proof",
          "parameter" => safe_activity_text(caption, 240),
          "result" => proof_body
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
  def handle_cast({:close, issue_id, summary}, state) do
    case session_id(state, issue_id) do
      nil ->
        {:noreply, state}

      agent_session_id ->
        run_async(fn ->
          close_session(state, issue_id, agent_session_id, summary)
        end)

        {:noreply, delete_session(state, issue_id, agent_session_id)}
    end
  end

  def handle_cast({:accept_webhook, payload}, state) do
    {:noreply, handle_webhook(payload, state)}
  end

  def handle_cast({:waiting_for_slot, %Issue{id: issue_id}}, state) when is_binary(issue_id) do
    settings = Config.settings!().linear_agent

    cond do
      !settings.enabled ->
        {:noreply, state}

      MapSet.member?(state.waiting_issues, issue_id) or
          MapSet.member?(state.waiting_session_requests, issue_id) ->
        {:noreply, state}

      agent_session_id = session_id(state, issue_id) ->
        publish_waiting_status_async(state, agent_session_id)
        {:noreply, mark_waiting(state, issue_id)}

      true ->
        {:noreply, request_waiting_session(state, issue_id, settings.app_user_id)}
    end
  end

  def handle_cast({:waiting_for_existing_slot, %Issue{id: issue_id}}, state)
      when is_binary(issue_id) do
    settings = Config.settings!().linear_agent

    cond do
      !settings.enabled ->
        {:noreply, state}

      MapSet.member?(state.waiting_issues, issue_id) ->
        {:noreply, state}

      MapSet.member?(state.waiting_session_requests, issue_id) ->
        {:noreply, state}

      agent_session_id = session_id(state, issue_id) ->
        publish_waiting_status_async(state, agent_session_id)
        {:noreply, mark_waiting(state, issue_id)}

      MapSet.member?(state.checked_existing_waiting_sessions, issue_id) ->
        {:noreply, state}

      true ->
        {:noreply, request_existing_waiting_session(state, issue_id, settings.app_user_id)}
    end
  end

  def handle_cast({:setup_repair_started, issue_id, attempt, total}, state) do
    publish_issue_activity_async(state, issue_id, %{
      "type" => "thought",
      "body" => "Workspace setup hit an error. A bounded recovery agent is diagnosing it before setup is retried (attempt #{attempt}/#{total})."
    })

    {:noreply, state}
  end

  def handle_cast({:setup_repair_succeeded, issue_id}, state) do
    publish_issue_activity_async(state, issue_id, %{
      "type" => "thought",
      "body" => "Workspace setup recovered and passed validation. The ticket work is continuing."
    })

    {:noreply, state}
  end

  def handle_cast({:codex_update, issue_id, update}, state) do
    {:noreply, publish_codex_update_for_issue(state, issue_id, update)}
  end

  def handle_cast({:failure, issue_id, message}, state) do
    if MapSet.member?(state.failure_notified_issues, issue_id) do
      {:noreply, state}
    else
      publish_issue_activity_async(state, issue_id, %{"type" => "error", "body" => message})

      {:noreply,
       %{
         state
         | failure_notified_issues: MapSet.put(state.failure_notified_issues, issue_id)
       }}
    end
  end

  def handle_cast({:recovering, issue_id}, state) do
    case session_id(state, issue_id) do
      agent_session_id when is_binary(agent_session_id) ->
        publish_recovering_status_async(state, agent_session_id)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:activity, issue_id, content, opts}, state) do
    case session_id(state, issue_id) do
      agent_session_id when is_binary(agent_session_id) ->
        run_async(fn -> create_activity(state, agent_session_id, content, opts) end)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:waiting_session_result, issue_id, result}, state) do
    state = clear_waiting_session_request(state, issue_id)

    case waiting_session_from_result(state, issue_id, result) do
      {:ok, agent_session_id, state} ->
        publish_waiting_status_async(state, agent_session_id)
        {:noreply, mark_waiting(state, issue_id)}

      {:error, reason, state} ->
        Logger.warning("Unable to create a Linear waiting session for issue_id=#{issue_id}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:existing_waiting_session_result, issue_id, result}, state) do
    state = clear_waiting_session_request(state, issue_id)

    case result do
      {:ok, %{"id" => session_id}} when is_binary(session_id) ->
        state = put_session(state, issue_id, session_id)
        publish_waiting_status_async(state, session_id)
        {:noreply, mark_waiting(state, issue_id)}

      :not_found ->
        {:noreply, mark_existing_waiting_session_checked(state, issue_id)}

      {:error, reason} ->
        Logger.warning("Unable to recover an existing Linear waiting session for issue_id=#{issue_id}: #{inspect(reason)}")

        {:noreply, mark_existing_waiting_session_checked(state, issue_id)}

      other ->
        Logger.warning("Invalid existing Linear waiting session response for issue_id=#{issue_id}: #{inspect(other)}")

        {:noreply, mark_existing_waiting_session_checked(state, issue_id)}
    end
  end

  defp reconcile_open_session_result(state, eligible_issue_ids, {:ok, sessions})
       when is_list(sessions) do
    state =
      Enum.reduce(sessions, state, fn
        %{"id" => session_id, "issue" => %{"id" => issue_id}}, state_acc
        when is_binary(session_id) and is_binary(issue_id) ->
          if MapSet.member?(eligible_issue_ids, issue_id) do
            put_session(state_acc, issue_id, session_id)
          else
            publish_ineligible_session_close_async(state_acc, issue_id, session_id)
            state_acc
          end

        _session, state_acc ->
          state_acc
      end)

    %{state | open_session_reconciliation: :complete}
  end

  defp reconcile_open_session_result(state, _eligible_issue_ids, {:error, reason}) do
    Logger.warning("Unable to reconcile open Linear agent sessions after restart: #{inspect(reason)}")
    %{state | open_session_reconciliation: :complete}
  end

  defp reconcile_open_session_result(state, _eligible_issue_ids, other) do
    Logger.warning("Invalid open Linear agent session reconciliation response: #{inspect(other)}")
    %{state | open_session_reconciliation: :complete}
  end

  defp publish_codex_update(state, agent_session_id, update) do
    case plan_for_update(update) do
      plan when is_list(plan) ->
        _ = state.client.update_session(agent_session_id, %{"plan" => plan}, client_opts(state))

      nil ->
        publish_codex_activity(state, agent_session_id, update)
    end
  end

  defp publish_codex_update_for_issue(state, issue_id, update) do
    case session_id(state, issue_id) do
      agent_session_id when is_binary(agent_session_id) ->
        publish_codex_update_by_failure_state(
          state,
          issue_id,
          agent_session_id,
          update,
          failure_update?(update)
        )

      _ ->
        state
    end
  end

  defp publish_codex_update_by_failure_state(
         state,
         _issue_id,
         agent_session_id,
         update,
         false
       ) do
    run_async(fn -> publish_codex_update(state, agent_session_id, update) end)
    state
  end

  defp publish_codex_update_by_failure_state(
         state,
         issue_id,
         agent_session_id,
         update,
         true
       ) do
    case MapSet.member?(state.failure_notified_issues, issue_id) do
      true ->
        state

      false ->
        run_async(fn -> publish_codex_update(state, agent_session_id, update) end)

        %{
          state
          | failure_notified_issues: MapSet.put(state.failure_notified_issues, issue_id)
        }
    end
  end

  defp failure_update?(%{event: event})
       when event in [:startup_failed, :turn_failed, :turn_ended_with_error],
       do: true

  defp failure_update?(_update), do: false

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
      run_async(fn ->
        create_activity(
          state,
          session_id,
          %{
            "type" => "thought",
            "body" => "#{display_name} received this ticket and is preparing an agent."
          },
          ephemeral: true
        )
      end)
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

  defp activity_for_update(%{event: :session_started, phase: :setup_repair}) do
    %{"type" => "thought", "body" => "A Codex setup-recovery worker started for this task."}
  end

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

  defp activity_for_update(%{event: :notification} = update) do
    update
    |> notification_payload()
    |> activity_for_notification()
  end

  defp activity_for_update(_update), do: nil

  defp activity_for_notification(%{"method" => "item/started", "params" => %{"item" => item}})
       when is_map(item) do
    activity_for_started_item(item)
  end

  defp activity_for_notification(%{"method" => "item/completed", "params" => %{"item" => item}})
       when is_map(item) do
    activity_for_completed_item(item)
  end

  defp activity_for_notification(_payload), do: nil

  defp activity_for_started_item(%{"type" => "commandExecution"}),
    do: action_activity("Running command", "Executing a workspace command")

  defp activity_for_started_item(%{"type" => "fileChange"}),
    do: action_activity("Editing files", "Applying implementation changes")

  defp activity_for_started_item(%{"type" => "mcpToolCall"} = item),
    do: action_activity("Using a connected tool", connected_tool_label(item))

  defp activity_for_started_item(%{"type" => "dynamicToolCall"} = item),
    do: action_activity("Using a Symphony tool", dynamic_tool_label(item))

  defp activity_for_started_item(%{"type" => "webSearch"}),
    do: action_activity("Searching the web", "Gathering current source material")

  defp activity_for_started_item(%{"type" => "imageView"}),
    do: action_activity("Inspecting an image", "Reviewing visual evidence")

  defp activity_for_started_item(%{"type" => "imageGeneration"}),
    do: action_activity("Generating an image", "Creating a visual asset")

  defp activity_for_started_item(%{"type" => "reasoning"}),
    do: thought_activity("Analyzing the ticket and current workspace state.")

  defp activity_for_started_item(_item), do: nil

  # An app-server agentMessage can be emitted before the worker turn has actually
  # ended. Linear treats a response activity as the terminal answer for the
  # current agent turn, so progress messages must remain non-terminal.
  defp activity_for_completed_item(%{"type" => "agentMessage", "text" => text}),
    do: thought_activity(text)

  defp activity_for_completed_item(%{"type" => "reasoning"} = item),
    do: thought_activity(reasoning_summary(item))

  defp activity_for_completed_item(%{"type" => "plan", "text" => text}),
    do: thought_activity(text)

  defp activity_for_completed_item(%{"type" => "commandExecution"} = item),
    do: action_activity("Command finished", command_result_label(item))

  defp activity_for_completed_item(%{"type" => "fileChange"} = item),
    do: action_activity("Files updated", file_change_label(item))

  defp activity_for_completed_item(%{"type" => "mcpToolCall"} = item),
    do: action_activity("Connected tool finished", connected_tool_label(item))

  defp activity_for_completed_item(%{"type" => "dynamicToolCall"} = item),
    do: action_activity("Symphony tool finished", dynamic_tool_label(item))

  defp activity_for_completed_item(%{"type" => "webSearch"}),
    do: action_activity("Web research finished", "Sources are available to the worker")

  defp activity_for_completed_item(%{"type" => "imageView"}),
    do: action_activity("Image review finished", "Visual evidence was inspected")

  defp activity_for_completed_item(%{"type" => "imageGeneration"}),
    do: action_activity("Image generation finished", "A visual asset was produced")

  defp activity_for_completed_item(%{"type" => "contextCompaction"}),
    do: thought_activity("Condensed the working context and continued.")

  defp activity_for_completed_item(_item), do: nil

  defp action_activity(action, parameter) when is_binary(action) and is_binary(parameter) do
    %{"type" => "action", "action" => action, "parameter" => safe_activity_text(parameter, 240)}
  end

  defp thought_activity(text) when is_binary(text) do
    case safe_activity_text(text, 4_000) do
      "" -> nil
      body -> %{"type" => "thought", "body" => body}
    end
  end

  defp thought_activity(_text), do: nil

  defp reasoning_summary(%{"summary" => summary}) when is_list(summary) do
    summary
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n\n")
  end

  defp reasoning_summary(%{"summary" => summary}) when is_binary(summary), do: summary
  defp reasoning_summary(_item), do: nil

  defp connected_tool_label(item) do
    [item["server"], item["tool"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" / ")
    |> default_activity_label("Connected tool")
  end

  defp dynamic_tool_label(item) do
    [item["namespace"], item["tool"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" / ")
    |> default_activity_label("Symphony tool")
  end

  defp default_activity_label("", fallback), do: fallback
  defp default_activity_label(label, _fallback), do: label

  defp command_result_label(item) do
    case item["exitCode"] do
      code when is_integer(code) -> "Exited with status #{code}"
      _ -> "Command execution completed"
    end
  end

  defp file_change_label(%{"changes" => changes}) when is_list(changes) do
    case length(changes) do
      1 -> "Updated 1 file"
      count -> "Updated #{count} files"
    end
  end

  defp file_change_label(_item), do: "Applied implementation changes"

  defp safe_activity_text(text, max_length) do
    sanitized =
      text
      |> String.trim()
      |> String.replace(
        ~r{(?i)(authorization|bearer|token|secret|password)(\s*[:=]?\s+)[^\s]+},
        "\\1\\2[REDACTED]"
      )
      |> String.replace(~r{(?i)://[^/@\s:]+:[^/@\s]+@}, "://[REDACTED]@")
      |> String.replace(~r{\b(?:ghp|github_pat|lin_api)_[A-Za-z0-9_\-]+\b}, "[REDACTED]")

    if String.length(sanitized) > max_length do
      String.slice(sanitized, 0, max_length) <> "…"
    else
      sanitized
    end
  end

  defp ephemeral_update?(%{event: :session_started}), do: true
  defp ephemeral_update?(_update), do: false

  defp plan_for_update(%{event: :notification} = update) do
    case notification_payload(update) do
      %{"method" => "turn/plan/updated", "params" => %{"plan" => plan}} when is_list(plan) ->
        Enum.flat_map(plan, fn
          %{"step" => content, "status" => status}
          when is_binary(content) and status in ["pending", "inProgress", "completed"] ->
            [%{"content" => content, "status" => status}]

          _ ->
            []
        end)

      _ ->
        nil
    end
  end

  defp plan_for_update(%{event: event})
       when event in [:startup_failed, :turn_failed, :turn_ended_with_error] do
    [
      %{
        "content" => "Recovering the worker after a transient failure",
        "status" => "inProgress"
      }
    ]
  end

  defp plan_for_update(_update), do: nil

  defp notification_payload(%{payload: payload}) when is_map(payload), do: payload
  defp notification_payload(%{details: %{payload: payload}}) when is_map(payload), do: payload
  defp notification_payload(_update), do: nil

  defp create_activity(state, agent_session_id, content, opts \\ []) do
    case state.client.create_activity(agent_session_id, content, client_opts(state, opts)) do
      {:ok, _activity} ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to publish Linear agent activity: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp publish_issue_activity_async(state, issue_id, content) do
    case session_id(state, issue_id) do
      agent_session_id when is_binary(agent_session_id) ->
        run_async(fn -> create_activity(state, agent_session_id, content) end)

      _ ->
        :ok
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

  defp ensure_issue_session(state, issue_id, app_user_id) do
    case session_id(state, issue_id) do
      session_id when is_binary(session_id) ->
        {:ok, session_id, state}

      _ ->
        case find_or_create_session(state, issue_id, app_user_id) do
          {:ok, %{"id" => session_id}} when is_binary(session_id) ->
            {:ok, session_id, put_session(state, issue_id, session_id)}

          {:error, reason} ->
            {:error, reason, state}

          other ->
            {:error, {:invalid_agent_session_response, other}, state}
        end
    end
  end

  defp maybe_assign_issue_to_app(_state, _issue_id, %{assign_on_start: false}), do: :ok

  defp maybe_assign_issue_to_app(state, issue_id, settings) do
    assign_issue_to_app(state, issue_id, settings.app_user_id)
  end

  defp announce_work_started(state, issue_id) do
    state = %{state | waiting_issues: MapSet.delete(state.waiting_issues, issue_id)}

    if MapSet.member?(state.work_started_issues, issue_id) do
      state
    else
      case session_id(state, issue_id) do
        agent_session_id when is_binary(agent_session_id) ->
          publish_work_started_async(state, agent_session_id)

        _ ->
          :ok
      end

      %{
        state
        | work_started_issues: MapSet.put(state.work_started_issues, issue_id)
      }
    end
  end

  defp publish_work_started_async(state, agent_session_id) do
    run_async(fn ->
      _ =
        state.client.update_session(
          agent_session_id,
          %{
            "plan" => [
              %{"content" => "Preparing the ticket workspace", "status" => "inProgress"}
            ]
          },
          client_opts(state)
        )

      create_activity(state, agent_session_id, %{
        "type" => "thought",
        "body" => "A worker slot is available. Symphony is preparing the ticket workspace."
      })
    end)
  end

  defp publish_waiting_status_async(state, agent_session_id) do
    run_async(fn ->
      _ =
        state.client.update_session(
          agent_session_id,
          %{
            "plan" => [
              %{
                "content" => "Waiting for an available worker slot on any configured computer",
                "status" => "inProgress"
              }
            ]
          },
          client_opts(state)
        )

      create_activity(state, agent_session_id, %{
        "type" => "thought",
        "body" => "This ticket is ready. Symphony is waiting for an available worker slot on one of the configured computers."
      })
    end)
  end

  defp publish_recovering_status_async(state, agent_session_id) do
    run_async(fn ->
      _ =
        state.client.update_session(
          agent_session_id,
          %{
            "plan" => [
              %{
                "content" => "Recovering the worker after a transient failure",
                "status" => "inProgress"
              }
            ]
          },
          client_opts(state)
        )
    end)
  end

  defp publish_ineligible_session_close_async(state, issue_id, agent_session_id) do
    run_async(fn ->
      close_session(
        state,
        issue_id,
        agent_session_id,
        "Symphony stopped this run because the issue is no longer eligible for this workflow. No worker is currently running."
      )
    end)
  end

  defp close_session(state, issue_id, agent_session_id, summary) do
    activity_result =
      create_activity(state, agent_session_id, %{"type" => "response", "body" => summary})

    delegate_result = state.client.clear_issue_delegate(issue_id, client_opts(state))

    case {activity_result, delegate_result} do
      {:ok, {:ok, %{"delegate" => nil}}} -> :ok
      {:ok, {:ok, issue}} -> {:error, {:linear_agent_assignment_not_cleared, issue}}
      {{:error, reason}, _delegate_result} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, {:linear_agent_assignment_clear_failed, reason}}
    end
  end

  defp request_waiting_session(state, issue_id, app_user_id) do
    bridge = self()

    {:ok, _pid} =
      Task.start(fn ->
        result = find_or_create_session(state, issue_id, app_user_id)
        send(bridge, {:waiting_session_result, issue_id, result})
      end)

    %{
      state
      | waiting_session_requests: MapSet.put(state.waiting_session_requests, issue_id)
    }
  end

  defp request_existing_waiting_session(state, issue_id, app_user_id) do
    bridge = self()

    {:ok, _pid} =
      Task.start(fn ->
        result = state.client.find_open_session(issue_id, app_user_id, client_opts(state))
        send(bridge, {:existing_waiting_session_result, issue_id, result})
      end)

    %{
      state
      | waiting_session_requests: MapSet.put(state.waiting_session_requests, issue_id)
    }
  end

  defp waiting_session_from_result(state, issue_id, {:ok, %{"id" => session_id}})
       when is_binary(session_id) do
    selected_session_id = session_id(state, issue_id) || session_id
    {:ok, selected_session_id, put_session(state, issue_id, selected_session_id)}
  end

  defp waiting_session_from_result(state, issue_id, {:error, reason}) do
    case session_id(state, issue_id) do
      session_id when is_binary(session_id) -> {:ok, session_id, state}
      _ -> {:error, reason, state}
    end
  end

  defp waiting_session_from_result(state, _issue_id, other) do
    {:error, {:invalid_agent_session_response, other}, state}
  end

  defp mark_waiting(state, issue_id) do
    %{state | waiting_issues: MapSet.put(state.waiting_issues, issue_id)}
  end

  defp clear_waiting_session_request(state, issue_id) do
    %{
      state
      | waiting_session_requests: MapSet.delete(state.waiting_session_requests, issue_id)
    }
  end

  defp mark_existing_waiting_session_checked(state, issue_id) do
    %{
      state
      | checked_existing_waiting_sessions: MapSet.put(state.checked_existing_waiting_sessions, issue_id)
    }
  end

  defp run_async(fun) when is_function(fun, 0) do
    {:ok, _pid} = Task.start(fun)
    :ok
  end

  defp assign_issue_to_app(state, issue_id, app_user_id) do
    case state.client.assign_issue(issue_id, app_user_id, client_opts(state)) do
      {:ok, %{"delegate" => %{"id" => ^app_user_id}}} ->
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
        issue_by_session: Map.put(state.issue_by_session, session_id, issue_id),
        checked_existing_waiting_sessions: MapSet.delete(state.checked_existing_waiting_sessions, issue_id)
    }
  end

  defp delete_session(state, issue_id, session_id) do
    %{
      state
      | sessions_by_issue: Map.delete(state.sessions_by_issue, issue_id),
        issue_by_session: Map.delete(state.issue_by_session, session_id),
        waiting_issues: MapSet.delete(state.waiting_issues, issue_id),
        work_started_issues: MapSet.delete(state.work_started_issues, issue_id)
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
