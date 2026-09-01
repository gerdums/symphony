defmodule SymphonyElixir.Linear.AgentBridge do
  @moduledoc """
  Owns the mapping between Linear agent sessions and Symphony issue runs.

  Linear is the durable, machine-independent conversation. Local or SSH workers
  can restart or move without changing the session that users see on the issue.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Factory.{GitHub, Policy, Protocol}
  alias SymphonyElixir.Linear.AgentClient
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue

  @git_sha ~r/\A[0-9a-f]{40}\z/i
  @durable_feedback_version 1
  @max_seen_webhooks 20_000

  defstruct client: AgentClient,
            client_opts: [],
            orchestrator: Orchestrator,
            sessions_by_issue: %{},
            issue_by_session: %{},
            phase_sessions_by_issue: %{},
            phase_by_session: %{},
            factory_agent_sessions: %{},
            factory_roles: %{},
            factory_issue_state: %{},
            factory_phase_changes: %{},
            factory_change_sessions: %{},
            factory_issue_commits: %{},
            pending_prompts: %{},
            factory_feedback_inflight: %{},
            proof_counts: %{},
            waiting_issues: MapSet.new(),
            waiting_session_requests: MapSet.new(),
            checked_existing_waiting_sessions: MapSet.new(),
            open_session_reconciliation: :pending,
            work_started_issues: MapSet.new(),
            failure_notified_issues: MapSet.new(),
            seen_webhooks: MapSet.new(),
            durable_feedback_path: nil

  @type state :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec accept_webhook(map(), GenServer.server()) :: :ok | {:error, term()}
  def accept_webhook(payload, server \\ __MODULE__) when is_map(payload) do
    GenServer.call(server, {:accept_webhook, payload}, 35_000)
  end

  @spec ensure_session(Issue.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()} | :disabled
  def ensure_session(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.call(server, {:ensure_session, issue}, 35_000)
  end

  @spec ensure_phase_session(Issue.t(), String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()} | :disabled
  def ensure_phase_session(%Issue{} = issue, phase, server \\ __MODULE__)
      when phase in ["planning", "build", "review", "qa"] do
    GenServer.call(server, {:ensure_phase_session, issue, phase}, 35_000)
  end

  @spec report_grooming_decision(Issue.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def report_grooming_decision(%Issue{} = issue, decision, server \\ __MODULE__)
      when is_map(decision) do
    GenServer.call(server, {:report_grooming_decision, issue, decision}, 35_000)
  end

  @spec register_phase_session(String.t(), String.t(), String.t(), GenServer.server()) :: :ok
  def register_phase_session(issue_id, phase, session_id, server \\ __MODULE__)
      when is_binary(issue_id) and phase in ["planning", "build", "review", "qa"] and
             is_binary(session_id) do
    GenServer.call(server, {:register_phase_session, issue_id, phase, session_id})
  end

  @spec ensure_factory_agent_session(Issue.t(), String.t(), String.t(), String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_factory_agent_session(%Issue{} = issue, phase, agent_id, role, server \\ __MODULE__)
      when is_binary(agent_id) and is_binary(role) do
    GenServer.call(server, {:ensure_factory_agent_session, issue, phase, agent_id, role}, 35_000)
  end

  @spec register_factory_agent_session(String.t(), String.t(), String.t(), String.t(), GenServer.server()) :: :ok
  def register_factory_agent_session(issue_id, phase, agent_id, session_id, server \\ __MODULE__)
      when is_binary(issue_id) and is_binary(agent_id) and is_binary(session_id) do
    GenServer.call(server, {:register_factory_agent_session, issue_id, phase, agent_id, session_id})
  end

  @spec report_factory_event(Issue.t(), String.t(), map(), GenServer.server()) ::
          :ok | {:error, term()} | :disabled
  def report_factory_event(%Issue{} = issue, session_id, event, server \\ __MODULE__)
      when is_binary(session_id) and is_map(event) do
    GenServer.call(server, {:factory_event, issue, session_id, event}, 35_000)
  end

  @spec complete_factory_lifecycle(Issue.t(), GenServer.server()) :: :ok | {:error, term()}
  def complete_factory_lifecycle(%Issue{} = issue, server \\ __MODULE__) do
    GenServer.call(server, {:complete_factory_lifecycle, issue}, 35_000)
  end

  @spec restore_factory_lifecycle(Issue.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def restore_factory_lifecycle(%Issue{} = issue, facts, server \\ __MODULE__) when is_map(facts) do
    GenServer.call(server, {:restore_factory_lifecycle, issue, facts}, 35_000)
  end

  @doc false
  @spec restore_factory_event(Issue.t(), String.t(), map(), GenServer.server()) ::
          :ok | {:error, term()}
  def restore_factory_event(%Issue{} = issue, session_id, event, server \\ __MODULE__)
      when is_binary(session_id) and is_map(event) do
    GenServer.call(server, {:restore_factory_event, issue, session_id, event}, 35_000)
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

  @spec take_prompts(String.t(), GenServer.server()) :: [map()]
  def take_prompts(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:take_prompts, issue_id}, :infinity)
  end

  @spec checkout_factory_feedback(String.t(), GenServer.server()) :: [map()]
  def checkout_factory_feedback(issue_id, server \\ __MODULE__) when is_binary(issue_id) do
    GenServer.call(server, {:checkout_factory_feedback, issue_id}, :infinity)
  end

  @spec acknowledge_factory_feedback(String.t(), [map()], GenServer.server()) ::
          {:ok, boolean()} | {:error, term()}
  def acknowledge_factory_feedback(issue_id, feedback, server \\ __MODULE__)
      when is_binary(issue_id) and is_list(feedback) do
    GenServer.call(server, {:acknowledge_factory_feedback, issue_id, feedback}, :infinity)
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
      - Never move an issue to `Done`. The final factory state is `In Review`, and only a human may set `Done`.
      """
    end
  end

  @impl true
  def init(opts) do
    durable_path =
      case Keyword.fetch(opts, :durable_feedback_path) do
        {:ok, path} ->
          path

        :error ->
          if Config.settings!().factory.enabled,
            do: Config.factory_state_root() |> Path.join("linear-feedback-v1.json"),
            else: nil
      end

    case load_durable_feedback(durable_path) do
      {:ok, durable} ->
        state = %__MODULE__{
          client: Keyword.get(opts, :client, AgentClient),
          client_opts: Keyword.get(opts, :client_opts, []),
          orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
          pending_prompts: durable.pending_prompts,
          factory_feedback_inflight: durable.factory_feedback_inflight,
          seen_webhooks: durable.seen_webhooks,
          durable_feedback_path: durable_path
        }

        if map_size(state.pending_prompts) > 0 or map_size(state.factory_feedback_inflight) > 0 do
          Process.send_after(self(), :reconcile_durable_factory_feedback, 0)
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, {:durable_factory_feedback_unavailable, reason}}
    end
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

  def handle_call({:ensure_phase_session, %Issue{id: issue_id}, phase}, _from, state) do
    case ensure_phase_session_in_state(state, issue_id, phase) do
      {:ok, session_id, next_state} -> {:reply, {:ok, session_id}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      :disabled -> {:reply, :disabled, state}
    end
  end

  def handle_call({:register_phase_session, issue_id, phase, session_id}, _from, state) do
    {:reply, :ok, put_phase_session(state, issue_id, phase, session_id)}
  end

  def handle_call(
        {:report_grooming_decision, %Issue{id: issue_id, title: title}, decision},
        _from,
        state
      ) do
    to_state = decision["to"]
    acceptance_criteria = decision["acceptanceCriteria"] || []

    plan =
      [
        decision["summary"] || title || "Groom backlog ticket",
        Enum.map(acceptance_criteria, &"Acceptance: #{&1}"),
        "Routing: #{decision["reason"]}"
      ]
      |> List.flatten()
      |> Enum.map(&%{"content" => safe_activity_text(&1, 1_000), "status" => "completed"})

    with :ok <- Policy.allow_transition(to_state),
         :ok <- require_non_terminal_factory_state(to_state, ["Done"]),
         {:ok, session_id, next_state} <- ensure_phase_session_in_state(state, issue_id, "planning"),
         {:ok, _session} <-
           next_state.client.update_session(
             session_id,
             %{"plan" => plan},
             client_opts(next_state)
           ),
         :ok <-
           create_activity(next_state, session_id, %{
             "type" => "action",
             "action" => "Backlog grooming: #{decision["from"]} → #{to_state}",
             "parameter" =>
               safe_activity_text(
                 Enum.join(
                   [decision["summary"], decision["reason"]] ++ acceptance_criteria,
                   "\n"
                 ),
                 1_000
               )
           }),
         {:ok, _issue} <-
           next_state.client.transition_issue_from(
             issue_id,
             Enum.uniq([decision["from"], to_state]),
             to_state,
             client_opts(next_state)
           ) do
      {:reply, :ok, next_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      other -> {:reply, {:error, {:invalid_grooming_result, other}}, state}
    end
  end

  def handle_call({:ensure_factory_agent_session, %Issue{id: issue_id}, phase, agent_id, role}, _from, state) do
    key = {issue_id, phase, agent_id}

    case state.factory_agent_sessions[key] do
      session_id when is_binary(session_id) ->
        {:reply, {:ok, session_id}, state}

      _missing ->
        event = %{"eventId" => agent_id, "phase" => phase, "payload" => %{"role" => role}}

        case create_factory_agent_session(state, issue_id, phase, agent_id, event) do
          {:ok, session_id, next_state} -> {:reply, {:ok, session_id}, next_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:register_factory_agent_session, issue_id, phase, agent_id, session_id}, _from, state) do
    key = {issue_id, phase, agent_id}

    next_state = %{
      state
      | factory_agent_sessions: Map.put(state.factory_agent_sessions, key, session_id),
        phase_by_session: Map.put(state.phase_by_session, session_id, {issue_id, phase})
    }

    {:reply, :ok, next_state}
  end

  def handle_call({:factory_event, %Issue{} = issue, session_id, event}, _from, state) do
    case validate_factory_event_binding(state, issue, session_id, event) do
      :ok ->
        with {:ok, event_session_id, next_state} <-
               route_factory_event_session(state, issue, event),
             {event, next_state} <- decorate_factory_event(next_state, issue.id, event),
             next_state <-
               record_factory_event_state(next_state, issue.id, event, event_session_id),
             :ok <- publish_factory_event(next_state, issue.id, event_session_id, event),
             :ok <- maybe_transition_after_factory_event(next_state, issue) do
          {:reply, :ok, put_phase_session(next_state, issue.id, event["phase"], session_id)}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:restore_factory_event, %Issue{} = issue, session_id, event}, _from, state) do
    case validate_factory_event_binding(state, issue, session_id, event) do
      :ok ->
        case route_factory_event_session(state, issue, event) do
          {:ok, event_session_id, next_state} ->
            {event, next_state} = decorate_factory_event(next_state, issue.id, event)
            next_state = record_factory_event_state(next_state, issue.id, event, event_session_id)
            {:reply, :ok, put_phase_session(next_state, issue.id, event["phase"], session_id)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:complete_factory_lifecycle, %Issue{id: issue_id}}, _from, state) do
    issue_state = Map.get(state.factory_issue_state, issue_id, %{})

    cond do
      !factory_lifecycle_ready?(issue_state) ->
        {:reply, {:error, :factory_qa_not_completed}, state}

      unprocessed_factory_feedback?(state, issue_id) ->
        {:reply, :ok, state}

      true ->
        {:reply, transition_to_review(state, issue_id), state}
    end
  end

  def handle_call({:accept_webhook, payload}, _from, state) do
    next_state = handle_webhook(payload, state)

    case persist_webhook_state(next_state) do
      {:ok, persisted_state} -> {:reply, :ok, persisted_state}
      {:error, reason} -> {:reply, {:error, {:webhook_not_persisted, reason}}, state}
    end
  end

  def handle_call({:restore_factory_lifecycle, %Issue{id: issue_id}, facts}, _from, state) do
    case validate_lifecycle_facts(facts) do
      {:ok, normalized} ->
        next_state = %{
          state
          | factory_issue_state: Map.put(state.factory_issue_state, issue_id, normalized),
            factory_issue_commits:
              restore_factory_issue_commit(
                state.factory_issue_commits,
                issue_id,
                normalized.integrated_head
              )
        }

        next_state = restore_factory_change_bindings(next_state, issue_id, normalized.change_bindings)

        {:reply, :ok, next_state}

      {:error, _reason} = error ->
        {:reply, error, state}
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
        with :ok <- begin_factory_work(state, issue_id),
             :ok <- maybe_assign_issue_to_app(state, issue_id, settings) do
          state = announce_work_started(state, issue_id)
          {:reply, :ok, state}
        else
          {:error, _reason} = error -> {:reply, error, state}
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

        next_state = %{state | pending_prompts: pending_prompts}
        {:reply, {:ok, prompt}, persist_durable_feedback(next_state)}

      [] ->
        {:reply, :empty, state}
    end
  end

  def handle_call({:take_prompts, issue_id}, _from, state) do
    prompts = Map.get(state.pending_prompts, issue_id, [])
    next_state = %{state | pending_prompts: Map.delete(state.pending_prompts, issue_id)}
    {:reply, prompts, persist_durable_feedback(next_state)}
  end

  def handle_call({:checkout_factory_feedback, issue_id}, _from, state) do
    case Map.get(state.factory_feedback_inflight, issue_id) do
      feedback when is_list(feedback) and feedback != [] ->
        {:reply, feedback, state}

      _none ->
        feedback = Map.get(state.pending_prompts, issue_id, [])

        inflight =
          if feedback == [] do
            state.factory_feedback_inflight
          else
            Map.put(state.factory_feedback_inflight, issue_id, feedback)
          end

        next_state = %{state | factory_feedback_inflight: inflight}
        {:reply, feedback, persist_durable_feedback(next_state)}
    end
  end

  def handle_call({:acknowledge_factory_feedback, issue_id, feedback}, _from, state) do
    acknowledged_ids = feedback |> Enum.map(&prompt_entry_id/1) |> MapSet.new()

    remaining =
      state.pending_prompts
      |> Map.get(issue_id, [])
      |> Enum.reject(&MapSet.member?(acknowledged_ids, prompt_entry_id(&1)))

    pending_prompts =
      if remaining == [],
        do: Map.delete(state.pending_prompts, issue_id),
        else: Map.put(state.pending_prompts, issue_id, remaining)

    next_state = %{
      state
      | pending_prompts: pending_prompts,
        factory_feedback_inflight: Map.delete(state.factory_feedback_inflight, issue_id)
    }

    if remaining == [] do
      {:reply, {:ok, false}, persist_durable_feedback(next_state)}
    else
      case reopen_for_feedback(state, issue_id) do
        :ok -> {:reply, {:ok, true}, persist_durable_feedback(next_state)}
        {:error, reason} -> {:reply, {:error, {:factory_feedback_reopen_failed, reason}}, state}
      end
    end
  end

  def handle_call({:record_proof, issue_id, asset_url, caption}, _from, state) do
    case session_id(state, issue_id) do
      nil ->
        {:reply, :disabled, state}

      agent_session_id ->
        safe_caption = safe_activity_text(caption, 1_000)

        content = %{
          "type" => "thought",
          "body" =>
            "Screenshot proof: #{safe_caption}\n\n" <>
              "![#{escape_alt_text(caption)}](#{asset_url})"
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
    case session_ids_for_issue(state, issue_id) do
      [] ->
        {:noreply, state}

      session_ids ->
        run_async(fn ->
          close_sessions(state, issue_id, session_ids, summary)
        end)

        {:noreply, delete_issue_sessions(state, issue_id, session_ids)}
    end
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

  def handle_info({:factory_feedback_reopen_result, issue_id, _attempt, :ok}, state) do
    notify_orchestrator(state.orchestrator, issue_id)
    {:noreply, state}
  end

  def handle_info({:factory_feedback_reopen_result, issue_id, attempt, {:error, reason}}, state) do
    Logger.warning("Unable to reopen Linear issue after review feedback issue_id=#{issue_id}: #{inspect(reason)}")
    Process.send_after(self(), {:retry_factory_feedback_reopen, issue_id, attempt + 1}, feedback_retry_ms(attempt))
    {:noreply, state}
  end

  def handle_info({:retry_factory_feedback_reopen, issue_id, attempt}, state) do
    if Map.get(state.pending_prompts, issue_id, []) == [] do
      {:noreply, state}
    else
      reopen_for_feedback_async(state, issue_id, attempt)
      {:noreply, state}
    end
  end

  def handle_info(:reconcile_durable_factory_feedback, state) do
    issue_ids =
      Map.keys(state.pending_prompts)
      |> Enum.concat(Map.keys(state.factory_feedback_inflight))
      |> Enum.uniq()

    Enum.each(issue_ids, &reopen_for_feedback_async(state, &1, 1))
    {:noreply, state}
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
    publish_external_urls(state, agent_session_id, update)

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
      %{"type" => "response"} = content ->
        _ = create_activity(state, agent_session_id, content)

        _ =
          create_activity(
            state,
            agent_session_id,
            %{"type" => "thought", "body" => "Codex is continuing this run."},
            ephemeral: true
          )

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

      {state, new_prompt?} = put_new_factory_prompt(state, issue_id, prompt_entry)
      if new_prompt?, do: notify_new_factory_prompt(state, issue_id)

      state
    else
      _ -> state
    end
  end

  defp put_new_factory_prompt(state, issue_id, prompt_entry) do
    if known_prompt?(state, issue_id, prompt_entry.id) do
      {state, false}
    else
      pending_prompts =
        Map.update(state.pending_prompts, issue_id, [prompt_entry], &(&1 ++ [prompt_entry]))

      {%{state | pending_prompts: pending_prompts}, true}
    end
  end

  defp notify_new_factory_prompt(state, issue_id) do
    if Config.settings!().factory.enabled do
      reopen_for_feedback_async(state, issue_id, 1)
    else
      notify_orchestrator(state.orchestrator, issue_id)
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

  defp activity_for_notification(%{
         "method" => "turn/diff/updated",
         "params" => %{"diff" => diff}
       })
       when is_binary(diff) do
    diff_activity(diff)
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

  # Linear only renders response activities as foreground conversation messages;
  # thoughts are folded into the Working disclosure. Publish each completed
  # app-server message as a response, then immediately reactivate the same
  # session with an ephemeral thought because the worker turn may still continue.
  defp activity_for_completed_item(%{"type" => "agentMessage", "text" => text}),
    do: response_activity(text)

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

  defp response_activity(text) when is_binary(text) do
    case safe_activity_text(text, 4_000) do
      "" -> nil
      body -> %{"type" => "response", "body" => body}
    end
  end

  defp response_activity(_text), do: nil

  defp diff_activity(diff) do
    file_count = Regex.scan(~r/^diff --git /m, diff) |> length()
    additions = Regex.scan(~r/^\+(?!\+\+)/m, diff) |> length()
    deletions = Regex.scan(~r/^-(?!--)/m, diff) |> length()

    action_activity(
      "Code changes updated",
      "Changed files: #{file_count}; +#{additions} -#{deletions} lines"
    )
  end

  defp publish_external_urls(state, agent_session_id, update) do
    case pull_request_urls_for_update(update) do
      [] ->
        :ok

      urls ->
        added_external_urls =
          Enum.map(urls, fn url -> %{"label" => "Pull request", "url" => url} end)

        _ =
          state.client.update_session(
            agent_session_id,
            %{"addedExternalUrls" => added_external_urls},
            client_opts(state)
          )

        :ok
    end
  end

  defp pull_request_urls_for_update(update) do
    case notification_payload(update) do
      %{"method" => "item/completed", "params" => %{"item" => item}} when is_map(item) ->
        ~r{https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+}
        |> Regex.scan(Jason.encode!(item), capture: :first)
        |> List.flatten()
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp initialize_phase_session(state, session_id, phase) do
    if phase in Protocol.phases() do
      phase_name = phase_name(phase)

      with {:ok, _session} <-
             state.client.update_session(
               session_id,
               %{
                 "plan" => [
                   %{"content" => "#{phase_name} phase", "status" => "inProgress"}
                 ]
               },
               client_opts(state)
             ) do
        create_activity(state, session_id, %{
          "type" => "thought",
          "body" => "#{phase_name} phase is ready. Factory events for this phase appear in this session."
        })
      end
    else
      {:error, {:unsupported_factory_phase, phase}}
    end
  end

  defp publish_factory_event(state, _issue_id, session_id, %{
         "type" => "plan.updated",
         "payload" => payload
       }) do
    plan = factory_plan(payload)

    case state.client.update_session(session_id, %{"plan" => plan}, client_opts(state)) do
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_factory_event(
         state,
         issue_id,
         session_id,
         %{
           "type" => "pr.updated",
           "payload" => payload
         } = event
       ) do
    case Map.get(payload, "url") do
      nil ->
        create_activity(state, session_id, factory_activity(event))

      url ->
        publish_factory_pr_url(state, issue_id, session_id, event, url)
    end
  end

  defp publish_factory_event(
         state,
         _issue_id,
         session_id,
         %{"type" => "artifact.created", "payload" => %{"artifact" => artifact}} = event
       ) do
    with :ok <- require_factory_artifact_url(artifact["uri"], "artifact.uri") do
      create_activity(state, session_id, factory_activity(event))
    end
  end

  defp publish_factory_event(
         state,
         issue_id,
         session_id,
         %{
           "type" => "check.completed",
           "payload" => %{"name" => "post-merge/internal-build", "url" => url}
         } = event
       ) do
    with :ok <- GitHub.validate_actions_run_url(url, Config.settings!().factory.github.repository),
         :ok <- ensure_factory_url_on_sessions(state, issue_id, session_id, "Internal Build", url) do
      create_activity(state, session_id, factory_activity(event))
    end
  end

  defp publish_factory_event(state, _issue_id, session_id, event) do
    case factory_activity(event) do
      nil -> :ok
      content -> create_activity(state, session_id, content)
    end
  end

  defp publish_factory_pr_url(state, issue_id, session_id, event, url) do
    with :ok <- GitHub.validate_pull_request_url(url, Config.settings!().factory.github.repository),
         :ok <- ensure_pull_request_url_on_sessions(state, issue_id, session_id, url) do
      create_activity(state, session_id, factory_activity(event))
    end
  end

  defp ensure_pull_request_url_on_sessions(state, issue_id, event_session_id, url) do
    ensure_factory_url_on_sessions(state, issue_id, event_session_id, "Pull Request", url)
  end

  defp ensure_factory_url_on_sessions(state, issue_id, event_session_id, label, url) do
    state
    |> factory_change_session_ids(issue_id, event_session_id)
    |> Enum.reduce_while(:ok, fn session_id, :ok ->
      case state.client.ensure_external_url(
             session_id,
             label,
             url,
             client_opts(state)
           ) do
        {:ok, _session} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:factory_session_link_failed, session_id, reason}}}
      end
    end)
  end

  defp factory_change_session_ids(state, issue_id, event_session_id) do
    changed_session_ids =
      state.factory_change_sessions
      |> Enum.flat_map(fn
        {{^issue_id, _phase, _agent_id}, session_id} when is_binary(session_id) ->
          [session_id]

        {_key, _session_id} ->
          []
      end)

    [event_session_id | changed_session_ids]
    |> Enum.uniq()
  end

  defp factory_activity(%{
         "type" => "phase.started",
         "phase" => phase,
         "role" => role,
         "payload" => payload
       }) do
    details =
      [Map.get(payload, "packet"), Map.get(payload, "branch")]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" on ")
      |> default_activity_label("Factory phase started")

    action_activity("#{phase_name(phase)} started", role_text(role, details))
  end

  defp factory_activity(%{"type" => "agent.started", "role" => role, "payload" => payload}) do
    provider = Map.get(payload, "provider", "agent")
    model = Map.get(payload, "model", "unknown model")
    access = if Map.get(payload, "readOnly"), do: "read-only", else: "write-enabled"
    action_activity("#{role_name(role)} started", "#{provider} / #{model} / #{access}")
  end

  defp factory_activity(%{"type" => "progress", "role" => role, "payload" => payload}) do
    case Map.get(payload, "message") do
      message when is_binary(message) -> thought_activity(role_text(role, message))
      _ -> nil
    end
  end

  defp factory_activity(%{"type" => "diff.updated", "role" => role, "payload" => payload}) do
    files = Map.get(payload, "filesChanged", 0)
    additions = Map.get(payload, "insertions", 0)
    deletions = Map.get(payload, "deletions", 0)
    commit_shas = Map.get(payload, "commitShas", [])

    commit_result =
      case commit_shas do
        [] -> "No commit SHA reported yet. The phase remains unlinked until a matching PR is published."
        shas -> "Commits: " <> Enum.map_join(shas, ", ", &"`#{&1}`")
      end

    %{
      "type" => "action",
      "action" => "#{role_name(role)} recorded code changes",
      "parameter" => "#{files} files",
      "result" => safe_activity_text("+#{additions} -#{deletions} lines\n\n#{commit_result}", 4_000)
    }
  end

  defp factory_activity(%{"type" => "check.completed", "role" => role, "payload" => payload}) do
    name = Map.get(payload, "name", "Check")
    status = Map.get(payload, "status", "unknown")
    details = Map.get(payload, "summary") || Map.get(payload, "command") || status

    if status in ["failed", "error"] do
      %{"type" => "error", "body" => role_text(role, "#{name} failed. #{details}")}
    else
      action_activity("#{name}: #{status}", role_text(role, to_string(details)))
    end
  end

  defp factory_activity(%{
         "type" => "artifact.created",
         "role" => role,
         "payload" => %{"artifact" => artifact}
       }) do
    kind = Map.get(artifact, "kind", "artifact")
    url = Map.get(artifact, "uri")
    caption = safe_activity_text(Map.get(artifact, "description", "Factory proof"), 1_000)

    cond do
      kind == "image" ->
        %{
          "type" => "thought",
          "body" => role_text(role, "#{caption}\n\n![#{escape_alt_text(caption)}](#{url})")
        }

      kind == "video" ->
        %{
          "type" => "thought",
          "body" => role_text(role, "[Video proof: #{caption}](#{url})")
        }

      true ->
        %{"type" => "thought", "body" => role_text(role, "[#{caption}](#{url})")}
    end
  end

  defp factory_activity(%{"type" => "pr.updated", "role" => role, "payload" => payload}) do
    number = if is_integer(payload["number"]), do: " ##{payload["number"]}", else: ""
    state = Map.get(payload, "state", "updated")
    quality = get_in(payload, ["qualityCheck", "status"])
    quality_text = if is_binary(quality), do: " Quality gate: #{quality}.", else: ""
    thought_activity(role_text(role, "Pull request#{number} is #{state}.#{quality_text}"))
  end

  defp factory_activity(%{"type" => "phase.completed", "phase" => phase, "role" => role, "payload" => payload}) do
    summary = Map.get(payload, "summary", "#{phase_name(phase)} phase completed.")
    response_activity(role_text(role, summary))
  end

  defp factory_activity(%{"type" => "phase.failed", "phase" => phase, "role" => role, "payload" => payload}) do
    message = Map.get(payload, "error", "#{phase_name(phase)} phase failed.")
    %{"type" => "error", "body" => role_text(role, message)}
  end

  defp factory_activity(%{"type" => "blocked", "role" => role, "payload" => payload}) do
    reason = Map.get(payload, "reason", "The factory needs input before it can continue.")
    message = if is_binary(payload["action"]), do: "#{reason} Action: #{payload["action"]}", else: reason
    %{"type" => "elicitation", "body" => role_text(role, message)}
  end

  defp factory_activity(_event), do: nil

  defp factory_plan(payload) do
    summary = Map.get(payload, "summary")

    summary_step =
      if is_binary(summary) do
        [%{"content" => safe_activity_text(summary, 1_000), "status" => "completed"}]
      else
        []
      end

    criteria =
      payload
      |> Map.get("acceptanceCriteria", [])
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&%{"content" => safe_activity_text(&1, 1_000), "status" => "pending"})

    summary_step ++ criteria
  end

  defp maybe_transition_after_factory_event(state, %Issue{id: issue_id}) do
    _issue_state = Map.get(state.factory_issue_state, issue_id, %{})
    :ok
  end

  defp transition_to_review(state, issue_id) do
    settings = Config.settings!()
    factory = settings.factory

    allowed_states =
      factory.review_from_states
      |> Enum.concat([factory.review_state])
      |> Enum.uniq()
      |> Enum.reject(&terminal_factory_state?(&1, settings.tracker.terminal_states))

    with {:ok, state_name} <- Policy.review_state(factory),
         :ok <- require_non_terminal_factory_state(state_name, settings.tracker.terminal_states),
         {:ok, _issue} <-
           state.client.transition_issue_from(
             issue_id,
             allowed_states,
             state_name,
             client_opts(state)
           ) do
      :ok
    end
  end

  defp route_factory_event_session(
         state,
         %Issue{id: issue_id},
         %{"type" => "agent.started", "phase" => phase} = event
       ) do
    agent_id = factory_agent_id(event)
    key = {issue_id, phase, agent_id}

    case state.factory_agent_sessions[key] do
      session_id when is_binary(session_id) ->
        {:ok, session_id, state}

      _missing ->
        create_factory_agent_session(state, issue_id, phase, agent_id, event)
    end
  end

  defp route_factory_event_session(
         state,
         %Issue{id: issue_id},
         %{"agentId" => agent_id, "phase" => phase}
       )
       when is_binary(agent_id) do
    case state.factory_agent_sessions[{issue_id, phase, agent_id}] do
      session_id when is_binary(session_id) -> {:ok, session_id, state}
      _missing -> {:error, {:factory_agent_session_missing, agent_id}}
    end
  end

  defp route_factory_event_session(state, %Issue{id: issue_id}, event) do
    phase = event["phase"]

    case state.phase_sessions_by_issue |> Map.get(issue_id, %{}) |> Map.get(phase) do
      session_id when is_binary(session_id) -> {:ok, session_id, state}
      _missing -> {:error, :factory_phase_session_not_registered}
    end
  end

  defp create_factory_agent_session(state, issue_id, phase, agent_id, event) do
    role = get_in(event, ["payload", "role"]) || phase

    case state.client.create_session(issue_id, client_opts(state)) do
      {:ok, %{"id" => session_id}} when is_binary(session_id) ->
        content = "#{phase_name(phase)} · #{role_name(role)} agent"

        with {:ok, _session} <-
               state.client.update_session(
                 session_id,
                 %{"plan" => [%{"content" => content, "status" => "inProgress"}]},
                 client_opts(state)
               ) do
          key = {issue_id, phase, agent_id}

          next_state = %{
            state
            | factory_agent_sessions: Map.put(state.factory_agent_sessions, key, session_id),
              phase_by_session: Map.put(state.phase_by_session, session_id, {issue_id, phase})
          }

          {:ok, session_id, next_state}
        end

      {:error, reason} ->
        {:error, {:factory_agent_session_create_failed, reason}}

      other ->
        {:error, {:invalid_agent_session_response, other}}
    end
  end

  defp factory_agent_id(%{"agentId" => agent_id}) when is_binary(agent_id), do: agent_id
  defp factory_agent_id(%{"eventId" => event_id}), do: event_id

  defp validate_factory_event_binding(
         state,
         %Issue{id: issue_id, identifier: identifier},
         session_id,
         event
       ) do
    with true <- event["issue"] == identifier,
         true <- event["project"] == Config.settings!().factory.project_key,
         {^issue_id, phase} <- state.phase_by_session[session_id],
         true <- event["phase"] == phase,
         :ok <- validate_factory_commit_shas(event),
         :ok <- validate_factory_pr_head(state, issue_id, event) do
      :ok
    else
      false -> {:error, :factory_event_binding_mismatch}
      nil -> {:error, :factory_phase_session_not_registered}
      {:error, _reason} = error -> error
      {_other_issue_id, _other_phase} -> {:error, :factory_event_binding_mismatch}
    end
  end

  defp validate_factory_commit_shas(%{
         "type" => type,
         "payload" => %{"commitShas" => commit_shas}
       })
       when type in ["diff.updated", "phase.completed"] and is_list(commit_shas) do
    if Enum.all?(commit_shas, &(is_binary(&1) and Regex.match?(@git_sha, &1))) do
      :ok
    else
      {:error, :invalid_factory_commit_sha}
    end
  end

  defp validate_factory_commit_shas(%{"type" => type})
       when type in ["diff.updated", "phase.completed"],
       do: {:error, :invalid_factory_commit_shas}

  defp validate_factory_commit_shas(_event), do: :ok

  defp validate_factory_pr_head(
         state,
         issue_id,
         %{"type" => "pr.updated", "payload" => %{"headSha" => head_sha}}
       )
       when is_binary(head_sha) do
    issue_commits = Map.get(state.factory_issue_commits, issue_id, MapSet.new())

    cond do
      !Regex.match?(@git_sha, head_sha) -> {:error, :invalid_factory_pr_head_sha}
      !MapSet.member?(issue_commits, String.downcase(head_sha)) -> {:error, :factory_pr_head_not_reported}
      true -> :ok
    end
  end

  defp validate_factory_pr_head(_state, _issue_id, %{"type" => "pr.updated"}),
    do: {:error, :invalid_factory_pr_head_sha}

  defp validate_factory_pr_head(_state, _issue_id, _event), do: :ok

  defp decorate_factory_event(state, issue_id, event) do
    phase = event["phase"]
    agent_id = event["agentId"] || if(event["type"] == "agent.started", do: event["eventId"])
    role_key = {issue_id, phase, agent_id || "phase"}
    role = get_in(event, ["payload", "role"]) || state.factory_roles[role_key] || phase
    next_state = %{state | factory_roles: Map.put(state.factory_roles, role_key, role)}
    {Map.put(event, "role", role), next_state}
  end

  defp record_factory_event_state(state, issue_id, event, event_session_id) do
    current = Map.get(state.factory_issue_state, issue_id, %{})

    updated =
      case event do
        %{"type" => "phase.completed", "phase" => "qa"} ->
          Map.put(current, :qa_completed, true)

        %{"type" => "pr.updated", "payload" => payload} ->
          current
          |> Map.put(:merged, payload["state"] == "merged")
          |> Map.put(:quality_passed, quality_gate_passed?(payload["qualityCheck"]))

        _event ->
          current
      end

    state = %{state | factory_issue_state: Map.put(state.factory_issue_state, issue_id, updated)}
    record_factory_change_state(state, issue_id, event, event_session_id)
  end

  defp record_factory_change_state(
         state,
         issue_id,
         %{"type" => "diff.updated", "phase" => phase, "payload" => payload} = event,
         event_session_id
       ) do
    commit_shas = normalized_commit_shas(payload)
    agent_key = {issue_id, phase, event["agentId"] || "phase"}

    phase_changes =
      Map.update(
        state.factory_phase_changes,
        agent_key,
        commit_shas,
        &MapSet.union(&1, commit_shas)
      )

    next_state = %{
      state
      | factory_phase_changes: phase_changes,
        factory_change_sessions: Map.put(state.factory_change_sessions, agent_key, event_session_id)
    }

    put_factory_issue_commits(next_state, issue_id, commit_shas)
  end

  defp record_factory_change_state(
         state,
         issue_id,
         %{"type" => "phase.completed", "payload" => payload},
         _event_session_id
       ) do
    put_factory_issue_commits(state, issue_id, normalized_commit_shas(payload))
  end

  defp record_factory_change_state(state, _issue_id, _event, _event_session_id), do: state

  defp put_factory_issue_commits(state, issue_id, commit_shas) do
    commits =
      Map.update(
        state.factory_issue_commits,
        issue_id,
        commit_shas,
        &MapSet.union(&1, commit_shas)
      )

    %{state | factory_issue_commits: commits}
  end

  defp normalized_commit_shas(payload) do
    payload
    |> Map.get("commitShas", [])
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp quality_gate_passed?(%{"name" => "factory/quality-gate", "status" => "passed"}),
    do: true

  defp quality_gate_passed?(_quality_check), do: false

  defp begin_factory_work(state, issue_id) do
    settings = Config.settings!()

    if settings.factory.enabled do
      factory = settings.factory

      with {:ok, feedback_state} <- Policy.feedback_state(factory),
           :ok <- require_non_terminal_factory_state(feedback_state, settings.tracker.terminal_states),
           {:ok, _issue} <-
             state.client.transition_issue_from(
               issue_id,
               Enum.uniq(["Todo", feedback_state]),
               feedback_state,
               client_opts(state)
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp factory_lifecycle_ready?(issue_state) do
    factory = Config.settings!().factory

    issue_state[:qa_completed] == true and
      Map.get(issue_state, :post_merge_completed, true) == true and
      (!factory.github.enabled or
         (issue_state[:merged] == true and issue_state[:quality_passed] == true))
  end

  defp validate_lifecycle_facts(facts) do
    required_booleans = [:qa_completed, :github_enabled, :merged, :quality_passed, :post_merge_completed]

    cond do
      !Enum.all?(required_booleans, &is_boolean(facts[&1])) ->
        {:error, :invalid_factory_lifecycle_facts}

      !is_nil(facts[:integrated_head]) and
          !(is_binary(facts[:integrated_head]) and Regex.match?(@git_sha, facts[:integrated_head])) ->
        {:error, :invalid_factory_lifecycle_facts}

      !valid_lifecycle_change_bindings?(facts[:change_bindings]) ->
        {:error, :invalid_factory_lifecycle_facts}

      facts[:github_enabled] != Config.settings!().factory.github.enabled ->
        {:error, :factory_lifecycle_configuration_mismatch}

      true ->
        {:ok, Map.put(facts, :change_bindings, facts[:change_bindings] || [])}
    end
  end

  defp valid_lifecycle_change_bindings?(nil), do: true

  defp valid_lifecycle_change_bindings?(bindings) when is_list(bindings) do
    keys = Enum.map(bindings, &{&1[:phase], &1[:agent_id], &1[:session_id]})

    Enum.uniq(keys) == keys and
      Enum.all?(bindings, fn binding ->
        is_map(binding) and binding[:phase] in SymphonyElixir.Factory.Protocol.phases() and
          nonempty_lifecycle_value?(binding[:agent_id]) and
          nonempty_lifecycle_value?(binding[:session_id]) and
          is_list(binding[:commit_shas]) and
          Enum.all?(binding[:commit_shas], &(is_binary(&1) and Regex.match?(@git_sha, &1)))
      end)
  end

  defp valid_lifecycle_change_bindings?(_bindings), do: false

  defp nonempty_lifecycle_value?(value), do: is_binary(value) and String.trim(value) != ""

  defp restore_factory_change_bindings(state, issue_id, bindings) do
    Enum.reduce(bindings, state, fn binding, current_state ->
      key = {issue_id, binding.phase, binding.agent_id}
      commits = MapSet.new(Enum.map(binding.commit_shas, &String.downcase/1))

      phase_changes =
        Map.update(current_state.factory_phase_changes, key, commits, &MapSet.union(&1, commits))

      current_state
      |> Map.put(:factory_phase_changes, phase_changes)
      |> Map.put(
        :factory_change_sessions,
        Map.put(current_state.factory_change_sessions, key, binding.session_id)
      )
      |> put_factory_issue_commits(issue_id, commits)
    end)
  end

  defp restore_factory_issue_commit(commits, _issue_id, nil), do: commits

  defp restore_factory_issue_commit(commits, issue_id, head) do
    Map.put(commits, issue_id, MapSet.new([String.downcase(head)]))
  end

  defp unprocessed_factory_feedback?(state, issue_id) do
    pending_ids =
      state.pending_prompts
      |> Map.get(issue_id, [])
      |> Enum.map(&prompt_entry_id/1)
      |> MapSet.new()

    inflight_ids =
      state.factory_feedback_inflight
      |> Map.get(issue_id, [])
      |> Enum.map(&prompt_entry_id/1)
      |> MapSet.new()

    !MapSet.subset?(pending_ids, inflight_ids)
  end

  defp reopen_for_feedback_async(state, issue_id, attempt) do
    bridge = self()

    run_async(fn ->
      send(
        bridge,
        {:factory_feedback_reopen_result, issue_id, attempt, reopen_for_feedback(state, issue_id)}
      )
    end)
  end

  defp feedback_retry_ms(attempt), do: min(250 * trunc(:math.pow(2, min(attempt - 1, 6))), 15_000)

  defp prompt_entry_id(entry), do: entry[:id] || entry["id"]

  defp known_prompt?(state, issue_id, prompt_id) when is_binary(prompt_id) do
    [state.pending_prompts, state.factory_feedback_inflight]
    |> Enum.flat_map(&Map.get(&1, issue_id, []))
    |> Enum.any?(&(prompt_entry_id(&1) == prompt_id))
  end

  defp known_prompt?(_state, _issue_id, _prompt_id), do: false

  defp reopen_for_feedback(state, issue_id) do
    settings = Config.settings!()
    factory = settings.factory

    with {:ok, feedback_state} <- Policy.feedback_state(factory),
         :ok <- require_non_terminal_factory_state(feedback_state, settings.tracker.terminal_states),
         {:ok, _issue} <-
           state.client.transition_issue_from(
             issue_id,
             Enum.uniq([factory.review_state, feedback_state]),
             feedback_state,
             client_opts(state)
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_non_terminal_factory_state(state_name, terminal_states) do
    if terminal_factory_state?(state_name, terminal_states),
      do: {:error, :factory_terminal_state_forbidden},
      else: :ok
  end

  defp terminal_factory_state?(state_name, terminal_states) when is_binary(state_name) do
    normalized = state_name |> String.trim() |> String.downcase()

    Enum.any?(terminal_states, fn terminal_state ->
      is_binary(terminal_state) and String.downcase(String.trim(terminal_state)) == normalized
    end)
  end

  defp terminal_factory_state?(_state_name, _terminal_states), do: true

  defp phase_name(phase) when is_binary(phase), do: phase |> String.replace("_", " ") |> String.capitalize()
  defp role_name(role) when is_binary(role), do: role |> String.replace(["_", "-"], " ") |> String.capitalize()

  defp role_text(role, text) when is_binary(text) do
    "[#{role_name(role)}] #{safe_activity_text(text, 4_000)}"
  end

  defp require_factory_artifact_url(url, key) do
    allowed_hosts = Config.settings!().factory.proof_url_hosts |> Enum.map(&String.downcase/1)

    with value when is_binary(value) <- url,
         %URI{scheme: "https", host: host, userinfo: nil, port: port}
         when is_binary(host) and host != "" and port in [nil, 443] <- URI.parse(value),
         true <- String.downcase(host) in allowed_hosts do
      :ok
    else
      _uri -> {:error, {:factory_artifact_requires_https_url, key}}
    end
  end

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

  defp ensure_phase_session_in_state(state, issue_id, phase) do
    cond do
      !Config.settings!().linear_agent.enabled ->
        :disabled

      session_id = get_in(state.phase_sessions_by_issue, [issue_id, phase]) ->
        {:ok, session_id, state}

      phase == "planning" and is_binary(session_id(state, issue_id)) ->
        initialize_existing_phase_session(state, issue_id, phase, session_id(state, issue_id))

      true ->
        create_phase_session(state, issue_id, phase)
    end
  end

  defp create_phase_session(state, issue_id, phase) do
    case state.client.create_session(issue_id, client_opts(state)) do
      {:ok, %{"id" => session_id}} when is_binary(session_id) ->
        initialize_existing_phase_session(state, issue_id, phase, session_id)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_agent_session_response, other}}
    end
  end

  defp initialize_existing_phase_session(state, issue_id, phase, session_id) do
    next_state = put_phase_session(state, issue_id, phase, session_id)

    case initialize_phase_session(next_state, session_id, phase) do
      :ok -> {:ok, session_id, next_state}
      {:error, reason} -> {:error, reason}
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

  defp close_sessions(state, issue_id, session_ids, summary) do
    activity_results =
      Enum.map(session_ids, fn session_id ->
        create_activity(state, session_id, %{"type" => "response", "body" => summary})
      end)

    delegate_result = state.client.clear_issue_delegate(issue_id, client_opts(state))

    case {Enum.find(activity_results, &match?({:error, _reason}, &1)), delegate_result} do
      {nil, {:ok, %{"delegate" => nil}}} -> :ok
      {nil, {:ok, issue}} -> {:error, {:linear_agent_assignment_not_cleared, issue}}
      {{:error, reason}, _delegate_result} -> {:error, reason}
      {nil, {:error, reason}} -> {:error, {:linear_agent_assignment_clear_failed, reason}}
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

  defp put_phase_session(state, issue_id, phase, session_id) do
    state = if phase == "planning", do: put_session(state, issue_id, session_id), else: state

    phase_sessions =
      state.phase_sessions_by_issue
      |> Map.get(issue_id, %{})
      |> Map.put(phase, session_id)

    %{
      state
      | phase_sessions_by_issue: Map.put(state.phase_sessions_by_issue, issue_id, phase_sessions),
        phase_by_session: Map.put(state.phase_by_session, session_id, {issue_id, phase}),
        issue_by_session: Map.put(state.issue_by_session, session_id, issue_id)
    }
  end

  defp session_ids_for_issue(state, issue_id) do
    phase_session_ids =
      state.phase_sessions_by_issue
      |> Map.get(issue_id, %{})
      |> Map.values()

    agent_session_ids =
      state.factory_agent_sessions
      |> Enum.flat_map(fn
        {{^issue_id, _phase, _agent_id}, session_id} -> [session_id]
        {_key, _session_id} -> []
      end)

    [session_id(state, issue_id) | phase_session_ids ++ agent_session_ids]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp delete_issue_sessions(state, issue_id, session_ids) do
    %{
      state
      | sessions_by_issue: Map.delete(state.sessions_by_issue, issue_id),
        issue_by_session: Map.drop(state.issue_by_session, session_ids),
        phase_sessions_by_issue: Map.delete(state.phase_sessions_by_issue, issue_id),
        phase_by_session: Map.drop(state.phase_by_session, session_ids),
        factory_agent_sessions:
          Map.reject(state.factory_agent_sessions, fn {{mapped_issue_id, _phase, _agent_id}, _session_id} ->
            mapped_issue_id == issue_id
          end),
        factory_roles:
          Map.reject(state.factory_roles, fn {{mapped_issue_id, _phase, _agent_id}, _role} ->
            mapped_issue_id == issue_id
          end),
        factory_issue_state: Map.delete(state.factory_issue_state, issue_id),
        factory_phase_changes:
          Map.reject(state.factory_phase_changes, fn {{mapped_issue_id, _phase, _agent_id}, _changes} ->
            mapped_issue_id == issue_id
          end),
        factory_change_sessions:
          Map.reject(state.factory_change_sessions, fn {{mapped_issue_id, _phase, _agent_id}, _session_id} ->
            mapped_issue_id == issue_id
          end),
        factory_issue_commits: Map.delete(state.factory_issue_commits, issue_id),
        waiting_issues: MapSet.delete(state.waiting_issues, issue_id),
        work_started_issues: MapSet.delete(state.work_started_issues, issue_id)
    }
  end

  defp session_id(state, issue_id), do: state.sessions_by_issue[issue_id]

  defp remember_webhook(state, webhook_id) when is_binary(webhook_id) do
    seen = MapSet.put(state.seen_webhooks, webhook_id)

    seen =
      if MapSet.size(seen) > @max_seen_webhooks do
        seen
        |> Enum.reject(&(&1 == webhook_id))
        |> Enum.sort()
        |> Enum.take(-(@max_seen_webhooks - 1))
        |> MapSet.new()
        |> MapSet.put(webhook_id)
      else
        seen
      end

    %{state | seen_webhooks: seen}
  end

  defp remember_webhook(state, _webhook_id), do: state

  defp proof_satisfied_in_state?(state, issue_id) do
    proof = Config.settings!().linear_agent.proof
    !proof.required or Map.get(state.proof_counts, issue_id, 0) >= proof.minimum_screenshots
  end

  defp escape_alt_text(caption) do
    String.replace(caption, ["]", "["], "")
  end

  defp load_durable_feedback(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        decode_durable_feedback(bytes)

      {:error, :enoent} ->
        {:ok,
         %{
           pending_prompts: %{},
           factory_feedback_inflight: %{},
           seen_webhooks: MapSet.new()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_durable_feedback(nil) do
    {:ok,
     %{
       pending_prompts: %{},
       factory_feedback_inflight: %{},
       seen_webhooks: MapSet.new()
     }}
  end

  defp decode_durable_feedback(bytes) do
    with {:ok,
          %{
            "version" => @durable_feedback_version,
            "pendingPrompts" => pending,
            "inflightFeedback" => inflight,
            "seenWebhooks" => seen
          }} <- Jason.decode(bytes),
         {:ok, pending} <- validate_durable_prompt_map(pending),
         {:ok, inflight} <- validate_durable_prompt_map(inflight),
         true <- is_list(seen) and length(seen) <= @max_seen_webhooks,
         true <- Enum.uniq(seen) == seen and Enum.all?(seen, &valid_durable_id?/1) do
      {:ok,
       %{
         pending_prompts: pending,
         factory_feedback_inflight: inflight,
         seen_webhooks: MapSet.new(seen)
       }}
    else
      _invalid -> {:error, :invalid_durable_factory_feedback}
    end
  end

  defp validate_durable_prompt_map(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {issue_id, prompts}, {:ok, acc} ->
      with true <- valid_durable_id?(issue_id),
           true <- is_list(prompts) and length(prompts) <= 1_000,
           {:ok, prompts} <- validate_durable_prompts(prompts) do
        {:cont, {:ok, Map.put(acc, issue_id, prompts)}}
      else
        _invalid -> {:halt, {:error, :invalid_durable_factory_feedback}}
      end
    end)
  end

  defp validate_durable_prompt_map(_value), do: {:error, :invalid_durable_factory_feedback}

  defp validate_durable_prompts(prompts) do
    Enum.reduce_while(prompts, {:ok, []}, fn prompt, {:ok, acc} ->
      case normalize_durable_prompt(prompt) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_durable_prompt(%{"id" => id, "body" => body, "action" => action})
       when is_binary(id) and is_binary(body) and action in ["created", "prompted"] do
    if valid_durable_id?(id) and byte_size(body) <= 100_000,
      do: {:ok, %{id: id, body: body, action: action}},
      else: {:error, :invalid_durable_factory_feedback}
  end

  defp normalize_durable_prompt(_prompt), do: {:error, :invalid_durable_factory_feedback}

  defp valid_durable_id?(value) when is_binary(value), do: value != "" and byte_size(value) <= 500
  defp valid_durable_id?(_value), do: false

  defp persist_durable_feedback(%__MODULE__{durable_feedback_path: path} = state)
       when is_binary(path) do
    payload = %{
      "version" => @durable_feedback_version,
      "pendingPrompts" => durable_prompt_map(state.pending_prompts),
      "inflightFeedback" => durable_prompt_map(state.factory_feedback_inflight),
      "seenWebhooks" => state.seen_webhooks |> Enum.sort() |> Enum.take(-@max_seen_webhooks)
    }

    directory = Path.dirname(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- File.write(temporary, Jason.encode!(payload), [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o600) do
        File.rename(temporary, path)
      end

    case result do
      :ok ->
        state

      {:error, reason} ->
        _ = File.rm(temporary)
        raise "could not persist durable factory feedback: #{inspect(reason)}"
    end
  end

  defp persist_durable_feedback(%__MODULE__{} = state), do: state

  defp persist_webhook_state(state) do
    {:ok, persist_durable_feedback(state)}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp durable_prompt_map(prompt_map) do
    Map.new(prompt_map, fn {issue_id, prompts} ->
      serialized =
        Enum.map(prompts, fn prompt ->
          %{
            "id" => prompt_entry_id(prompt),
            "body" => prompt[:body] || prompt["body"],
            "action" => prompt[:action] || prompt["action"]
          }
        end)

      {issue_id, serialized}
    end)
  end
end
