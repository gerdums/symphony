defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item with the configured coding-agent provider.
  """

  require Logger
  alias SymphonyElixir.{AgentClient, Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Linear.AgentBridge
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      if Keyword.has_key?(opts, :worker_host) do
        Keyword.get(opts, :worker_host)
      else
        selected_worker_host(Config.settings!().worker.ssh_hosts)
      end

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    with {:ok, _session_id} <- ensure_linear_agent_session(issue),
         {:ok, workspace} <- Workspace.create_for_issue(issue, worker_host) do
      send_worker_runtime_info(agent_update_recipient, issue, worker_host, workspace)

      try do
        with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
          run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host)
        end
      after
        Workspace.run_after_run_hook(workspace, issue, worker_host)
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_linear_agent_session(issue) do
    case AgentBridge.ensure_session(issue) do
      :disabled -> {:ok, nil}
      {:ok, session_id} -> {:ok, session_id}
      {:error, reason} -> {:error, {:linear_agent_session_failed, reason}}
    end
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    # Keep the established orchestrator mailbox shape for backwards compatibility.
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)
    agent_client = Keyword.get(opts, :agent_client, AgentClient.provider_module())

    with {:ok, session} <- agent_client.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_agent_turns(
          {agent_client, session},
          workspace,
          issue,
          agent_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        agent_client.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(
         {agent_client, agent_session} = agent,
         workspace,
         issue,
         agent_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns) |> append_linear_agent_context(issue.id)

    with {:ok, turn_session} <-
           agent_client.run_turn(
             agent_session,
             prompt,
             issue,
             on_message: agent_message_handler(agent_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_agent_turns(
            agent,
            workspace,
            refreshed_issue,
            agent_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          send_run_outcome(agent_update_recipient, issue, :active)
          :ok

        {:done, refreshed_issue} ->
          send_run_outcome(
            agent_update_recipient,
            issue,
            run_outcome_for_issue(refreshed_issue)
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp append_linear_agent_context(prompt, issue_id) do
    sections =
      [
        prompt,
        AgentBridge.prompt_guidance(),
        pending_linear_prompt(issue_id)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(sections, "\n\n")
  end

  defp pending_linear_prompt(issue_id) do
    if Config.settings!().linear_agent.enabled and is_binary(issue_id) do
      take_pending_linear_prompt(issue_id)
    end
  end

  defp take_pending_linear_prompt(issue_id) do
    case AgentBridge.take_prompt(issue_id) do
      {:ok, %{body: body}} ->
        """
        Linear agent session instruction:

        #{body}
        """

      :empty ->
        nil
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp run_outcome_for_issue(%Issue{state: state_name}) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    terminal? =
      Config.settings!().tracker.terminal_states
      |> Enum.any?(fn terminal_state -> normalize_issue_state(terminal_state) == normalized_state end)

    if terminal?, do: :terminal, else: :inactive
  end

  defp run_outcome_for_issue(_issue), do: :inactive

  defp send_run_outcome(recipient, %Issue{} = issue, outcome)
       when is_pid(recipient) and outcome in [:active, :inactive, :terminal] do
    send_agent_update(recipient, issue, %{
      event: :run_finished,
      outcome: outcome,
      timestamp: DateTime.utc_now()
    })
  end

  defp send_run_outcome(_recipient, _issue, _outcome), do: :ok

  defp issue_routable?(%Issue{} = issue) do
    tracker = Config.settings!().tracker

    Issue.routable?(
      issue,
      tracker.required_labels,
      tracker.include_labels,
      tracker.exclude_labels
    )
  end

  defp selected_worker_host([]), do: nil

  defp selected_worker_host(configured_hosts) when is_list(configured_hosts) do
    configured_hosts
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> List.first()
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
