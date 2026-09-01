defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Factory.Runner, as: FactoryRunner
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
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host =
      if Config.settings!().factory.enabled do
        nil
      else
        selected_worker_host_for_run(opts)
      end

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp selected_worker_host_for_run(opts) do
    if Keyword.has_key?(opts, :worker_host) do
      Keyword.get(opts, :worker_host)
    else
      selected_worker_host(Config.settings!().worker.ssh_hosts)
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    with {:ok, _session_id} <- ensure_linear_agent_session(issue),
         :ok <- start_linear_agent_work(issue),
         {:ok, workspace} <-
           prepare_workspace_with_repair(
             issue,
             codex_update_recipient,
             worker_host
           ) do
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

      try do
        with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
          run_selected_agent(workspace, issue, codex_update_recipient, opts, worker_host)
        end
      after
        Workspace.run_after_run_hook(workspace, issue, worker_host)
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_selected_agent(workspace, issue, codex_update_recipient, opts, worker_host)
       when is_binary(workspace) do
    if Config.settings!().factory.enabled do
      run_factory_lifecycles(workspace, issue, codex_update_recipient, opts)
    else
      run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp run_factory_lifecycles(workspace, issue, recipient, opts) do
    feedback =
      Keyword.get_lazy(opts, :review_feedback, fn -> checkout_factory_feedback(issue.id) end)

    case FactoryRunner.run(issue, workspace, Keyword.put(opts, :review_feedback, feedback)) do
      :ok ->
        case acknowledge_factory_feedback(issue.id, feedback) do
          {:ok, true} -> run_factory_lifecycles(workspace, issue, recipient, Keyword.delete(opts, :review_feedback))
          {:ok, false} -> send_run_outcome(recipient, issue, :inactive)
          {:error, _reason} = error -> error
        end

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp checkout_factory_feedback(issue_id) when is_binary(issue_id) do
    if Config.settings!().linear_agent.enabled,
      do: AgentBridge.checkout_factory_feedback(issue_id),
      else: []
  end

  defp checkout_factory_feedback(_issue_id), do: []

  defp acknowledge_factory_feedback(issue_id, feedback) when is_binary(issue_id) do
    if Config.settings!().linear_agent.enabled,
      do: AgentBridge.acknowledge_factory_feedback(issue_id, feedback),
      else: {:ok, false}
  end

  defp acknowledge_factory_feedback(_issue_id, _feedback), do: {:ok, false}

  defp prepare_workspace_with_repair(issue, codex_update_recipient, worker_host) do
    repair_attempts = Config.settings!().agent.setup_repair_attempts

    case Workspace.create_for_issue(issue, worker_host, preserve_on_failure: repair_attempts > 0) do
      {:ok, workspace} ->
        {:ok, workspace}

      {:error, {:workspace_setup_failed, workspace, reason}} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        repair_workspace_setup(
          workspace,
          issue,
          reason,
          repair_attempts,
          repair_attempts,
          codex_update_recipient,
          worker_host
        )

      {:error, reason} ->
        {:error, compact_workspace_setup_error(reason)}
    end
  end

  defp repair_workspace_setup(
         workspace,
         issue,
         reason,
         attempts_remaining,
         total_attempts,
         codex_update_recipient,
         worker_host
       )
       when attempts_remaining > 0 do
    attempt = total_attempts - attempts_remaining + 1
    :ok = report_setup_repair_started(issue, attempt, total_attempts)

    _repair_result =
      AppServer.run(
        workspace,
        setup_repair_prompt(reason, attempt, total_attempts),
        issue,
        worker_host: worker_host,
        on_message: setup_repair_message_handler(codex_update_recipient, issue)
      )

    case Workspace.retry_after_create_hook(workspace, issue, worker_host) do
      :ok ->
        :ok = report_setup_repair_succeeded(issue)
        {:ok, workspace}

      {:error, next_reason} when attempts_remaining > 1 ->
        repair_workspace_setup(
          workspace,
          issue,
          next_reason,
          attempts_remaining - 1,
          total_attempts,
          codex_update_recipient,
          worker_host
        )

      {:error, next_reason} ->
        Workspace.cleanup_failed_setup(workspace, worker_host)
        {:error, compact_workspace_setup_error(next_reason)}
    end
  end

  defp setup_repair_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, Map.put(message, :phase, :setup_repair))
    end
  end

  defp report_setup_repair_started(%Issue{id: issue_id}, attempt, total_attempts)
       when is_binary(issue_id) do
    AgentBridge.setup_repair_started(issue_id, attempt, total_attempts)
  end

  defp report_setup_repair_started(_issue, _attempt, _total_attempts), do: :ok

  defp report_setup_repair_succeeded(%Issue{id: issue_id}) when is_binary(issue_id) do
    AgentBridge.setup_repair_succeeded(issue_id)
  end

  defp report_setup_repair_succeeded(_issue), do: :ok

  defp setup_repair_prompt(reason, attempt, total_attempts) do
    """
    You are the bounded workspace-setup recovery phase for an unattended Symphony run.

    Workspace setup failed before ticket implementation could begin. Diagnose and fix only the setup problem, then stop. Symphony will rerun the configured setup hook after this turn and will continue the original ticket only if that hook succeeds.

    Recovery rules:
    - Do not implement the ticket or make product changes during this phase.
    - You may repair incomplete workspace state, dependency/tool versions, and required non-secret host tooling.
    - Never inspect, print, copy, rotate, or expose credentials, tokens, keychains, environment secrets, or private configuration.
    - Do not weaken authentication, sandboxing, repository protections, or verification checks.
    - Do not edit Symphony's WORKFLOW.md. Prefer the smallest reversible repair.
    - Validate the underlying failing tool when practical, and finish this turn once setup is ready to retry.

    Recovery attempt: #{attempt}/#{total_attempts}

    Sanitized setup failure:
    #{setup_failure_excerpt(reason)}
    """
  end

  defp setup_failure_excerpt({:workspace_hook_failed, hook_name, status, output}) do
    "hook=#{hook_name} exit_status=#{status}\n" <> sanitize_setup_output(output)
  end

  defp setup_failure_excerpt({:workspace_hook_timeout, hook_name, timeout_ms}) do
    "hook=#{hook_name} timed_out_after_ms=#{timeout_ms}"
  end

  defp setup_failure_excerpt(reason), do: reason |> inspect() |> sanitize_setup_output()

  defp sanitize_setup_output(output) do
    output
    |> IO.iodata_to_binary()
    |> tail_text(6_000)
    |> redact_configured_secrets()
    |> String.replace(~r{(?i)(authorization|bearer|token|secret|password)(\s*[:=]?\s+)[^\s]+}, "\\1\\2[REDACTED]")
    |> String.replace(~r{(?i)://[^/@\s:]+:[^/@\s]+@}, "://[REDACTED]@")
    |> String.replace(~r{\b(?:ghp|github_pat|lin_api)_[A-Za-z0-9_\-]+\b}, "[REDACTED]")
  end

  defp redact_configured_secrets(output) do
    settings = Config.settings!()

    [
      settings.tracker.api_key,
      settings.linear_agent.access_token,
      settings.linear_agent.client_secret,
      settings.linear_agent.webhook_secret
    ]
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= 8))
    |> Enum.reduce(output, fn secret, redacted ->
      String.replace(redacted, secret, "[REDACTED]")
    end)
  end

  defp tail_text(text, max_characters) when is_binary(text) do
    length = String.length(text)

    if length > max_characters do
      "... (earlier output omitted)\n" <> String.slice(text, length - max_characters, max_characters)
    else
      text
    end
  end

  defp compact_workspace_setup_error({:workspace_hook_failed, hook_name, status, _output}) do
    {:workspace_hook_failed, hook_name, status}
  end

  defp compact_workspace_setup_error(reason), do: reason

  defp ensure_linear_agent_session(issue) do
    case AgentBridge.ensure_session(issue) do
      :disabled -> {:ok, nil}
      {:ok, session_id} -> {:ok, session_id}
      {:error, reason} -> {:error, {:linear_agent_session_failed, reason}}
    end
  end

  defp start_linear_agent_work(issue) do
    case AgentBridge.start_work(issue) do
      :disabled -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, {:linear_agent_assignment_failed, reason}}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

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

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns) |> append_linear_agent_context(issue.id)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          send_run_outcome(codex_update_recipient, issue, :active)
          :ok

        {:done, refreshed_issue} ->
          send_run_outcome(
            codex_update_recipient,
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

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
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
    send_codex_update(recipient, issue, %{
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
