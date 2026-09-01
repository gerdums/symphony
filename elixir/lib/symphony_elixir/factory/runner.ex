defmodule SymphonyElixir.Factory.Runner do
  @moduledoc """
  Runs the configured software factory one phase at a time and relays JSONL
  events to native Linear agent sessions.

  The runner starts locally. The factory command owns any decision to send work
  to another computer.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety}
  alias SymphonyElixir.Factory.{BoundedPort, GitHub, Protocol}
  alias SymphonyElixir.Linear.{AgentBridge, AgentClient}
  alias SymphonyElixir.Tracker.Issue

  @journal_version 7
  @max_line_bytes 1_048_576
  @max_media_dimension 10_000
  @max_video_duration_ms 600_000
  @media_commands ~w(sips ffprobe ffmpeg)
  @media_command_timeout_ms 600_000
  @max_media_command_output_bytes 1_048_576

  @spec run(Issue.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def run(%Issue{} = issue, workspace, opts \\ []) when is_binary(workspace) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings!().factory end)
    bridge = Keyword.get(opts, :bridge, AgentBridge)
    project = settings.project_key
    feedback = Keyword.get(opts, :review_feedback, [])

    feedback_digest = identity_digest([feedback_json(feedback)])

    with {:ok, journal_path} <-
           trusted_journal_path(issue, project, workspace, settings, feedback_digest, opts),
         {:ok, journal} <-
           load_journal(
             journal_path,
             issue,
             project,
             feedback_digest,
             Keyword.get_lazy(opts, :factory_run_id, &random_run_id/0)
           ) do
      if journal["completed"] do
        # The durable marker is written before the Linear transition. Replaying
        # the transition is therefore safe after a crash or an uncertain API
        # response, including when the issue is already In Review.
        complete_factory_lifecycle(%{issue: issue, settings: settings, bridge: bridge}, journal)
      else
        continue_factory_run(issue, workspace, settings, bridge, journal_path, feedback, opts, journal)
      end
    end
  end

  defp continue_factory_run(issue, workspace, settings, bridge, journal_path, feedback, opts, journal) do
    context = %{
      issue: issue,
      workspace: workspace,
      settings: settings,
      bridge: bridge,
      journal_path: journal_path,
      feedback: feedback,
      opts: opts
    }

    with {:ok, phase_journal} <- run_phases(settings.phases, journal, context),
         :ok <- require_all_phases_completed(phase_journal, settings.phases),
         :ok <- restore_factory_lifecycle(context, phase_journal),
         {:ok, final_journal} <- maybe_finalize_github(phase_journal, context),
         :ok <- write_journal(journal_path, Map.put(final_journal, "completed", true)) do
      complete_factory_lifecycle(context, Map.put(final_journal, "completed", true))
    end
  end

  @doc false
  @spec prepare_event_for_test(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_event_for_test(event, workspace, opts \\ [])
      when is_map(event) and is_binary(workspace) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings!().factory end)
    prepare_event(event, %{workspace: workspace, settings: settings, opts: opts})
  end

  @doc false
  @spec trusted_quality_evidence_for_test(map()) :: :ok | {:error, term()}
  def trusted_quality_evidence_for_test(journal), do: require_trusted_quality_evidence(journal)

  @doc false
  @spec run_bounded_command_for_test(Path.t(), [String.t()], Path.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def run_bounded_command_for_test(executable, args, workspace, timeout_ms) do
    run_bounded_command(
      executable,
      args,
      workspace,
      %Issue{id: "timeout-test", identifier: "APP-1"},
      [],
      timeout_ms
    )
  end

  @doc false
  @spec run_media_command_for_test(String.t(), [String.t()], Path.t(), keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run_media_command_for_test(command, args, cwd, opts \\ []) do
    run_media_command(command, args, cwd, opts)
  end

  defp run_phases(phases, journal, context) do
    Enum.reduce_while(phases, {:ok, journal}, fn phase, {:ok, current_journal} ->
      case run_or_restore_phase(phase, current_journal, context) do
        {:ok, next_journal} -> {:cont, {:ok, next_journal}}
        {:error, reason} -> {:halt, {:error, {:factory_phase_failed, phase, reason}}}
      end
    end)
  end

  defp run_or_restore_phase(phase, journal, context) do
    if get_in(journal, ["completed_phases", phase]) == true do
      restore_completed_phase(phase, journal, context)
    else
      run_phase(phase, journal, context)
    end
  end

  defp restore_completed_phase(phase, journal, context) do
    with session_id when is_binary(session_id) <- get_in(journal, ["phase_sessions", phase]),
         :ok <- bridge_call(context.bridge, :register_phase_session, [context.issue.id, phase, session_id]),
         :ok <- restore_agent_sessions(phase, journal, context) do
      {:ok, journal}
    else
      nil -> {:error, :completed_phase_session_missing}
      {:error, _reason} = error -> error
      other -> {:error, {:completed_phase_restore_failed, other}}
    end
  end

  defp restore_agent_sessions(phase, journal, context) do
    journal["agent_sessions"]
    |> Enum.filter(fn {key, _session_id} -> String.starts_with?(key, phase <> ":") end)
    |> Enum.reduce_while(:ok, fn {key, session_id}, :ok ->
      agent_id = String.replace_prefix(key, phase <> ":", "")

      case bridge_call(context.bridge, :register_factory_agent_session, [
             context.issue.id,
             phase,
             agent_id,
             session_id
           ]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:agent_session_restore_failed, agent_id, other}}}
      end
    end)
  end

  defp maybe_finalize_github(journal, context) do
    if context.settings.github.enabled do
      finalize_github(journal, context)
    else
      {:ok, journal}
    end
  end

  defp complete_factory_lifecycle(context, journal) do
    with :ok <- restore_factory_lifecycle(context, journal),
         :ok <- bridge_call(context.bridge, :complete_factory_lifecycle, [context.issue]) do
      :ok
    else
      {:error, reason} -> {:error, {:factory_lifecycle_completion_failed, reason}}
      other -> {:error, {:factory_lifecycle_completion_failed, other}}
    end
  end

  defp restore_factory_lifecycle(context, journal) do
    facts = lifecycle_facts(journal, context.settings.github.enabled)
    bridge_call(context.bridge, :restore_factory_lifecycle, [context.issue, facts])
  end

  defp lifecycle_facts(journal, github_enabled) do
    %{
      qa_completed: get_in(journal, ["completed_phases", "qa"]) == true,
      github_enabled: github_enabled,
      merged: journal["github_state"] == "merged",
      quality_passed: journal["quality_passed"] == true,
      post_merge_completed: journal["post_merge_internal_build"] == false or is_map(journal["post_merge_result"]),
      integrated_head: journal["integrated_head"],
      change_bindings:
        Enum.map(journal["change_bindings"], fn binding ->
          %{
            phase: binding["phase"],
            agent_id: binding["agent_id"],
            session_id: binding["session_id"],
            commit_shas: binding["commit_shas"]
          }
        end)
    }
  end

  defp finalize_github(journal, context) do
    with session_id when is_binary(session_id) <- get_in(journal, ["phase_sessions", "qa"]),
         github_context <- Map.put(context, :session_id, session_id),
         :ok <- require_all_phases_completed(journal, context.settings.phases),
         :ok <- require_trusted_quality_evidence(journal),
         :ok <- require_issue_active(context, :before_push),
         {:ok, pull_request} <-
           GitHub.prepare(context.issue, context.workspace, context.settings.github, context.opts),
         {:ok, journal} <-
           maybe_publish_open_pull_request(pull_request, journal, github_context),
         :ok <- maybe_publish_quality_gate(pull_request, journal, context),
         {:ok, merged_pull_request} <-
           GitHub.merge_after_required_check(
             pull_request,
             context.workspace,
             context.settings.github,
             Keyword.put(context.opts, :pre_merge_guard, fn ->
               require_issue_active(context, :before_merge)
             end)
           ),
         {:ok, journal} <-
           maybe_run_post_merge_internal_build(merged_pull_request, journal, github_context),
         {:ok, merged_event} <-
           github_pull_request_event(
             context.issue,
             merged_pull_request,
             context.settings.github.required_check,
             "merged",
             "passed",
             journal["run_id"],
             journal["started_at"]
           ),
         {:ok, journal} <-
           publish_generated_event(merged_event, journal, github_context) do
      {:ok, journal}
    else
      nil -> {:error, {:github_finalization_failed, :qa_session_missing}}
      {:error, reason} -> {:error, {:github_finalization_failed, reason}}
    end
  end

  defp maybe_run_post_merge_internal_build(_pull_request, %{"post_merge_internal_build" => false} = journal, _context),
    do: {:ok, journal}

  defp maybe_run_post_merge_internal_build(pull_request, journal, context) do
    stage = context.settings.post_merge

    cond do
      !stage.enabled ->
        {:error, :post_merge_internal_build_not_configured}

      is_map(journal["post_merge_result"]) ->
        publish_post_merge_result(pull_request, journal, context)

      true ->
        with {:ok, result} <- execute_post_merge_internal_build(pull_request, journal, context),
             next_journal = Map.put(journal, "post_merge_result", result),
             :ok <- write_journal(context.journal_path, next_journal) do
          publish_post_merge_result(pull_request, next_journal, context)
        end
    end
  end

  defp execute_post_merge_internal_build(pull_request, journal, context) do
    with {:ok, executable} <- resolve_executable(context.settings.command),
         args <- render_post_merge_args(context.settings.post_merge.args, pull_request, journal, context),
         {:ok, output} <-
           run_bounded_command(
             executable,
             args,
             context.workspace,
             context.issue,
             context.feedback,
             context.settings.post_merge.timeout_ms
           ),
         {:ok, result} <- decode_post_merge_result(output),
         :ok <- validate_post_merge_result(result, pull_request, context.settings.github.repository) do
      {:ok, result}
    end
  end

  defp render_post_merge_args(args, pull_request, journal, context) do
    replacements = %{
      "{{ tracker.project_slug }}" => context.settings.project_key || "",
      "{{ factory.project_key }}" => context.settings.project_key || "",
      "{{ issue.id }}" => context.issue.id || "",
      "{{ issue.identifier }}" => context.issue.identifier || "",
      "{{ workspace }}" => context.workspace,
      "{{ commit_sha }}" => pull_request.head_sha,
      "{{ pr_number }}" => Integer.to_string(pull_request.number),
      "{{ run_id }}" => journal["run_id"]
    }

    args
    |> Enum.map(fn arg ->
      Enum.reduce(replacements, arg, fn {placeholder, value}, rendered ->
        String.replace(rendered, placeholder, value)
      end)
    end)
    |> put_authoritative_option("--project", context.settings.project_key)
    |> put_authoritative_option("--issue", context.issue.identifier)
    |> put_authoritative_option("--commit", pull_request.head_sha)
    |> put_authoritative_option("--pr-number", Integer.to_string(pull_request.number))
    |> put_authoritative_option("--run-id", journal["run_id"])
  end

  defp run_bounded_command(executable, args, workspace, issue, feedback, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, String.to_charlist(workspace)},
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:env, factory_env(issue, "qa", feedback)}
        ]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_command_output(port, "", timeout_ms, deadline)
  rescue
    error -> {:error, {:post_merge_command_failed, Exception.message(error)}}
  end

  defp collect_command_output(port, output, timeout_ms, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      stop_with_error(port, {:post_merge_timeout, timeout_ms})
    else
      receive do
        {^port, {:data, bytes}} ->
          next = output <> bytes

          if byte_size(next) <= @max_line_bytes,
            do: collect_command_output(port, next, timeout_ms, deadline),
            else: stop_with_error(port, :post_merge_result_too_large)

        {^port, {:exit_status, 0}} ->
          {:ok, output}

        {^port, {:exit_status, status}} ->
          {:error, {:post_merge_exit_status, status}}
      after
        remaining_ms -> stop_with_error(port, {:post_merge_timeout, timeout_ms})
      end
    end
  end

  defp decode_post_merge_result(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _invalid -> {:error, :invalid_post_merge_result}
    end
  end

  defp validate_post_merge_result(result, pull_request, repository) do
    allowed = ["required", "status", "commitSha", "runUrl"]

    cond do
      !Enum.all?(Map.keys(result), &(&1 in allowed)) ->
        {:error, :invalid_post_merge_result}

      result["required"] != true or result["status"] != "passed" ->
        {:error, :post_merge_internal_build_not_passed}

      !is_binary(result["commitSha"]) or
          String.downcase(result["commitSha"]) != pull_request.head_sha ->
        {:error, :post_merge_commit_mismatch}

      true ->
        GitHub.validate_actions_run_url(result["runUrl"], repository)
    end
  end

  defp publish_post_merge_result(pull_request, journal, context) do
    result = journal["post_merge_result"]

    event = %{
      "protocolVersion" => 1,
      "eventId" => deterministic_uuid("event:#{journal["run_id"]}:post-merge-internal-build"),
      "runId" => journal["run_id"],
      "occurredAt" => journal["started_at"],
      "project" => context.settings.project_key,
      "issue" => context.issue.identifier,
      "type" => "check.completed",
      "phase" => "qa",
      "payload" => %{
        "name" => "post-merge/internal-build",
        "status" => "passed",
        "summary" => "Internal build completed for the merged exact head.",
        "required" => true,
        "acceptance" => true,
        "external" => true,
        "commitSha" => pull_request.head_sha,
        "url" => result["runUrl"]
      }
    }

    with {:ok, event} <- Protocol.parse_line(Jason.encode!(event)) do
      publish_generated_event(event, journal, context)
    end
  end

  defp require_trusted_quality_evidence(journal) do
    head = journal["integrated_head"]

    cond do
      !is_binary(head) ->
        {:error, :integrated_head_missing}

      head not in get_in(journal, ["trusted_check_heads", "review"]) ->
        {:error, :trusted_review_missing}

      head not in get_in(journal, ["trusted_check_heads", "qa"]) ->
        {:error, :trusted_qa_missing}

      true ->
        require_scope_proof(journal, head)
    end
  end

  defp require_scope_proof(%{"work_scope" => "non-runtime"}, _head), do: :ok

  defp require_scope_proof(journal, head) do
    artifacts = Enum.filter(journal["proof_artifacts"], &(&1["commitSha"] == head))
    targets = journal["proof_targets"]

    cond do
      journal["work_scope"] not in ["runtime-static", "runtime-interactive"] ->
        {:error, :factory_work_scope_missing}

      targets != [] ->
        require_proof_targets(targets, artifacts)

      journal["work_scope"] == "runtime-static" and Enum.any?(artifacts, &(&1["kind"] == "image")) ->
        :ok

      journal["work_scope"] == "runtime-interactive" and
        Enum.any?(artifacts, &(&1["kind"] == "image")) and
          Enum.any?(artifacts, &(&1["kind"] == "video")) ->
        :ok

      true ->
        {:error, :trusted_proof_missing}
    end
  end

  defp require_proof_targets(targets, artifacts) do
    satisfied? =
      Enum.all?(targets, fn target ->
        bound =
          Enum.filter(
            artifacts,
            &(&1["platform"] == target["platform"] and &1["flow"] == target["flow"])
          )

        Enum.all?(target["requiredMedia"], fn kind -> Enum.any?(bound, &(&1["kind"] == kind)) end) and
          Enum.all?(target["requiredRelations"] || [], fn relation ->
            Enum.any?(bound, &(&1["relation"] == relation))
          end)
      end)

    if satisfied?, do: :ok, else: {:error, :trusted_proof_target_missing}
  end

  defp maybe_publish_quality_gate(%{state: :merged}, _journal, _context), do: :ok

  defp maybe_publish_quality_gate(pull_request, journal, context) do
    if pull_request.head_sha == journal["integrated_head"] do
      GitHub.publish_quality_gate(
        pull_request,
        context.workspace,
        context.settings.github,
        context.opts
      )
    else
      {:error, :quality_gate_head_mismatch}
    end
  end

  defp require_issue_active(context, checkpoint) do
    reader = Keyword.get(context.opts, :linear_issue_state_reader, &default_issue_state_reader/1)

    with {:ok, state_name} <- reader.(context.issue.id),
         false <- terminal_issue_state?(state_name) do
      :ok
    else
      true -> {:error, {:terminal_issue_state, checkpoint}}
      {:error, reason} -> {:error, {:issue_state_read_failed, checkpoint, reason}}
      other -> {:error, {:issue_state_read_failed, checkpoint, other}}
    end
  end

  defp default_issue_state_reader(issue_id), do: AgentClient.issue_state(issue_id)

  defp terminal_issue_state?(state_name) when is_binary(state_name) do
    normalized = Config.Schema.normalize_issue_state(state_name)

    Config.settings!().tracker.terminal_states
    |> Enum.map(&Config.Schema.normalize_issue_state/1)
    |> Enum.member?(normalized)
  end

  defp terminal_issue_state?(_state_name), do: true

  defp maybe_publish_open_pull_request(%{state: :open} = pull_request, journal, context) do
    with {:ok, event} <-
           github_pull_request_event(
             context.issue,
             pull_request,
             context.settings.github.required_check,
             "open",
             "pending",
             journal["run_id"],
             journal["started_at"]
           ) do
      publish_generated_event(event, journal, context)
    end
  end

  defp maybe_publish_open_pull_request(%{state: :merged}, journal, _context),
    do: {:ok, journal}

  defp github_pull_request_event(
         issue,
         pr,
         required_check,
         state,
         check_status,
         run_id,
         occurred_at
       ) do
    project = Config.settings!().factory.project_key

    if is_binary(project) and String.trim(project) != "" do
      identifier = String.downcase(issue.identifier)

      event = %{
        "protocolVersion" => 1,
        "eventId" => deterministic_uuid("event:#{identifier}:#{pr.number}:#{state}"),
        "runId" => run_id,
        "occurredAt" => occurred_at,
        "project" => project,
        "issue" => issue.identifier,
        "type" => "pr.updated",
        "phase" => "qa",
        "payload" => %{
          "state" => state,
          "number" => pr.number,
          "url" => pr.url,
          "headSha" => pr.head_sha,
          "qualityCheck" => %{"name" => required_check, "status" => check_status}
        }
      }

      Protocol.parse_line(Jason.encode!(event))
    else
      {:error, :factory_project_key_missing}
    end
  end

  defp publish_generated_event(event, journal, run_context) do
    event_context = %{
      phase: "qa",
      issue: run_context.issue,
      session_id: run_context.session_id,
      workspace: run_context.workspace,
      settings: run_context.settings,
      bridge: run_context.bridge,
      journal_path: run_context.journal_path,
      opts: run_context.opts,
      factory_phase_stream: false
    }

    with :ok <- validate_issue(event, run_context.issue.identifier),
         :ok <- validate_project(event, run_context.settings.project_key),
         :ok <- validate_event_urls(event, run_context.settings) do
      publish_event(event, event_context, journal)
    end
  end

  defp run_phase(phase, journal, context) do
    with {:ok, journal} <- prepare_phase_retry(phase, journal, context.journal_path),
         {:ok, session_id, journal} <-
           phase_session(context.issue, phase, context.workspace, context.bridge, journal),
         :ok <- write_journal(context.journal_path, journal),
         {:ok, executable} <- resolve_executable(context.settings.command),
         {:ok, args} <-
           render_args(
             context.settings.args,
             context.issue,
             phase,
             context.workspace,
             context.feedback,
             journal,
             context.settings.project_key
           ),
         {:ok, port} <-
           open_port(
             executable,
             args,
             context.workspace,
             context.issue,
             phase,
             context.feedback
           ) do
      event_context = %{
        phase: phase,
        issue: context.issue,
        session_id: session_id,
        workspace: context.workspace,
        settings: context.settings,
        bridge: context.bridge,
        journal_path: context.journal_path,
        opts: context.opts,
        factory_phase_stream: true,
        timeout_ms: Keyword.get(context.opts, :phase_timeout_ms, context.settings.phase_timeout_ms)
      }

      read_events(port, event_context, journal)
    end
  end

  defp prepare_phase_retry(phase, journal, journal_path) do
    if get_in(journal, ["phase_events", phase]) in [nil, []] do
      {:ok, journal}
    else
      journal = reset_incomplete_phase(journal, phase)

      case write_journal(journal_path, journal) do
        :ok -> {:ok, journal}
        {:error, reason} -> {:error, {:journal_write_failed, reason}}
      end
    end
  end

  defp reset_incomplete_phase(journal, phase) do
    journal =
      journal
      |> update_in(["phase_events"], &Map.delete(&1, phase))
      |> update_in(["phase_commits"], &Map.delete(&1, phase))
      |> update_in(["phase_attempts"], &Map.delete(&1, phase))
      |> Map.update!("proof_artifacts", &Enum.reject(&1, fn artifact -> artifact["phase"] == phase end))

    journal =
      if phase in ["review", "qa"],
        do:
          journal
          |> put_in(["trusted_check_heads", phase], [])
          |> Map.put("#{phase}_trusted", false),
        else: journal

    journal =
      if phase == "planning" do
        journal
        |> Map.put("work_scope", nil)
        |> Map.put("proof_targets", [])
        |> Map.put("post_merge_internal_build", false)
      else
        journal
      end

    rebuild_derived_phase_facts(journal)
  end

  defp rebuild_derived_phase_facts(journal) do
    integrated_head =
      Protocol.phases()
      |> Enum.filter(&(get_in(journal, ["completed_phases", &1]) == true))
      |> Enum.flat_map(&(get_in(journal, ["phase_commits", &1]) || []))
      |> List.last()

    proof_artifacts = journal["proof_artifacts"]
    proof_heads = proof_artifacts |> Enum.map(& &1["commitSha"]) |> Enum.uniq()

    journal
    |> Map.put("integrated_head", integrated_head)
    |> Map.put("proof_count", length(proof_artifacts))
    |> Map.put("proof_heads", proof_heads)
  end

  defp phase_session(issue, phase, _workspace, bridge, journal) do
    case get_in(journal, ["phase_sessions", phase]) do
      session_id when is_binary(session_id) ->
        :ok = bridge_call(bridge, :register_phase_session, [issue.id, phase, session_id])
        {:ok, session_id, journal}

      _ ->
        case bridge_call(bridge, :ensure_phase_session, [issue, phase]) do
          {:ok, session_id} ->
            {:ok, session_id, put_in(journal, ["phase_sessions", phase], session_id)}

          other ->
            {:error, {:phase_session_failed, other}}
        end
    end
  end

  defp read_events(port, context, journal) do
    deadline = System.monotonic_time(:millisecond) + context.timeout_ms
    do_read_events(port, context, journal, "", nil, 0, deadline)
  end

  defp do_read_events(port, context, journal, buffer, terminal_type, event_index, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = buffer <> to_string(line)

        with :ok <- validate_line_size(full_line),
             {:ok, event} <- Protocol.parse_line(full_line, context.settings.protocol_version),
             :ok <- require_before_terminal(terminal_type, event),
             :ok <- validate_phase(event, context.phase),
             :ok <- validate_issue(event, context.issue.identifier),
             :ok <- validate_project(event, context.settings.project_key),
             :ok <- validate_event_urls(event, context.settings),
             :ok <- validate_factory_event_policy(event),
             :ok <- validate_phase_event_sequence(journal, context.phase, event, event_index),
             {:ok, journal} <- publish_event(event, context, journal) do
          do_read_events(
            port,
            context,
            journal,
            "",
            terminal_type_for_event(terminal_type, event),
            event_index + 1,
            deadline
          )
        else
          {:error, reason} -> stop_with_error(port, reason)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        next_buffer = buffer <> to_string(chunk)

        case validate_line_size(next_buffer) do
          :ok ->
            do_read_events(
              port,
              context,
              journal,
              next_buffer,
              terminal_type,
              event_index,
              deadline
            )

          {:error, reason} ->
            stop_with_error(port, reason)
        end

      {^port, {:exit_status, 0}} when terminal_type == "phase.completed" and buffer == "" ->
        case require_complete_phase_sequence(journal, context.phase, event_index) do
          :ok -> {:ok, journal}
          {:error, _reason} = error -> error
        end

      {^port, {:exit_status, 0}} when is_binary(terminal_type) and buffer == "" ->
        {:error, {:phase_terminated, terminal_type}}

      {^port, {:exit_status, 0}} ->
        {:error, :phase_completion_event_missing}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      remaining_ms ->
        stop_with_error(port, {:timeout, context.timeout_ms})
    end
  end

  defp publish_event(event, context, journal) do
    event_id = event["eventId"]
    digest = Protocol.canonical_digest(event)

    with {:ok, journal} <- bind_journal_run(journal, event["runId"]) do
      publish_bound_event(event, event_id, digest, context, journal)
    end
  end

  defp publish_bound_event(event, event_id, digest, context, journal) do
    case get_in(journal, ["processed_events", event_id]) do
      ^digest ->
        restore_processed_event(event, event_id, context, journal)

      existing_digest when is_binary(existing_digest) ->
        {:error, {:conflicting_event_replay, event_id}}

      nil ->
        publish_new_event(event, event_id, digest, context, journal)
    end
  end

  defp publish_new_event(event, event_id, digest, context, journal) do
    with :ok <- validate_event_against_journal(event, journal),
         {:ok, prepared_event} <- prepare_event(event, context) do
      publish_prepared_event(prepared_event, event_id, digest, context, journal)
    end
  end

  defp restore_processed_event(event, event_id, context, journal) do
    with {:ok, journal} <- ensure_event_agent_session(event, context, journal) do
      case bridge_call(context.bridge, :restore_factory_event, [context.issue, context.session_id, event]) do
        :ok ->
          record_published_event(
            context.journal_path,
            journal,
            context.phase,
            event_id,
            Protocol.canonical_digest(event),
            context.factory_phase_stream,
            event
          )

        {:error, reason} ->
          {:error, {:event_restore_failed, event_id, reason}}

        other ->
          {:error, {:event_restore_failed, event_id, other}}
      end
    end
  end

  defp publish_prepared_event(event, event_id, digest, context, journal) do
    with {:ok, journal} <- ensure_event_agent_session(event, context, journal) do
      case bridge_call(context.bridge, :report_factory_event, [context.issue, context.session_id, event]) do
        :ok ->
          record_published_event(
            context.journal_path,
            journal,
            context.phase,
            event_id,
            digest,
            context.factory_phase_stream,
            event
          )

        {:error, reason} ->
          {:error, {:event_publish_failed, event_id, reason}}

        other ->
          {:error, {:event_publish_failed, event_id, other}}
      end
    end
  end

  defp ensure_event_agent_session(%{"type" => "agent.started"} = event, context, journal) do
    agent_id = event["agentId"] || event["eventId"]
    role = get_in(event, ["payload", "role"]) || event["phase"]
    ensure_journal_agent_session(agent_id, role, event["phase"], context, journal)
  end

  defp ensure_event_agent_session(%{"agentId" => agent_id} = event, context, journal)
       when is_binary(agent_id) do
    ensure_journal_agent_session(agent_id, event["phase"], event["phase"], context, journal)
  end

  defp ensure_event_agent_session(_event, _context, journal), do: {:ok, journal}

  defp ensure_journal_agent_session(agent_id, role, phase, context, journal) do
    key = "#{phase}:#{agent_id}"

    case get_in(journal, ["agent_sessions", key]) do
      session_id when is_binary(session_id) ->
        with :ok <-
               bridge_call(context.bridge, :register_factory_agent_session, [
                 context.issue.id,
                 phase,
                 agent_id,
                 session_id
               ]) do
          {:ok, journal}
        end

      _missing ->
        case bridge_call(context.bridge, :ensure_factory_agent_session, [
               context.issue,
               phase,
               agent_id,
               role
             ]) do
          {:ok, session_id} when is_binary(session_id) ->
            journal = put_in(journal, ["agent_sessions", key], session_id)
            persist_agent_session_journal(context.journal_path, journal)

          other ->
            {:error, {:agent_session_failed, agent_id, other}}
        end
    end
  end

  defp persist_agent_session_journal(path, journal) do
    case write_journal(path, journal) do
      :ok -> {:ok, journal}
      {:error, reason} -> {:error, {:journal_write_failed, reason}}
    end
  end

  defp prepare_event(
         %{
           "type" => "artifact.created",
           "payload" => %{"artifact" => %{"storage" => "local_file"} = artifact} = payload
         } = event,
         context
       ) do
    with {:ok, uploaded_artifact} <-
           upload_local_artifact(
             artifact,
             context.workspace,
             context.settings.proof_url_hosts,
             context.opts
           ) do
      {:ok, put_in(event, ["payload"], %{payload | "artifact" => uploaded_artifact})}
    end
  end

  defp prepare_event(
         %{
           "type" => "artifact.created",
           "payload" => %{
             "artifact" => %{"storage" => storage, "uri" => uri}
           }
         } = event,
         context
       )
       when storage in ["remote_url", "linear_attachment"] do
    with :ok <- require_allowed_artifact_uri(uri, context.settings.proof_url_hosts),
         :ok <- verify_remote_artifact_receipt(event, context.opts) do
      {:ok, event}
    end
  end

  defp prepare_event(%{"type" => "artifact.created"}, _context),
    do: {:error, :invalid_factory_artifact}

  defp prepare_event(event, _context), do: {:ok, event}

  defp upload_local_artifact(artifact, workspace, allowed_hosts, opts) do
    with {:ok, path} <- local_artifact_path(artifact["uri"], workspace),
         {:ok, stat} <- File.stat(path),
         :ok <- require_regular_file(stat),
         :ok <- require_artifact_under_limit(stat.size, opts),
         :ok <- require_artifact_size(stat.size, artifact["byteSize"]),
         {:ok, bytes} <- File.read(path),
         :ok <- require_artifact_sha(bytes, artifact["sha256"]) do
      validate_and_upload_immutable_artifact(artifact, path, bytes, allowed_hosts, opts)
    end
  end

  defp validate_and_upload_immutable_artifact(artifact, path, bytes, allowed_hosts, opts) do
    with_private_artifact_copy(path, bytes, fn immutable_path ->
      with :ok <- validate_media_content(artifact, immutable_path, bytes, opts),
           {:ok, asset_url} <- upload_artifact(immutable_path, artifact["mimeType"], bytes, opts),
           :ok <- require_allowed_artifact_uri(asset_url, allowed_hosts) do
        {:ok, %{artifact | "storage" => "linear_attachment", "uri" => asset_url}}
      end
    end)
  end

  defp with_private_artifact_copy(source_path, bytes, function) when is_function(function, 1) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(System.tmp_dir!(), "symphony-artifact-#{nonce}")
    private_path = Path.join(directory, Path.basename(source_path))

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(private_path, bytes, [:binary, :exclusive]),
         :ok <- File.chmod(private_path, 0o600) do
      try do
        function.(private_path)
      after
        _ = File.rm(private_path)
        _ = File.rmdir(directory)
      end
    else
      {:error, reason} ->
        _ = File.rm(private_path)
        _ = File.rmdir(directory)
        {:error, {:artifact_private_copy_failed, reason}}
    end
  end

  defp local_artifact_path(uri, workspace) when is_binary(uri) and is_binary(workspace) do
    with true <- Path.type(uri) == :absolute,
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_path} <- PathSafety.canonicalize(uri),
         true <- inside_workspace?(canonical_path, canonical_workspace) do
      {:ok, canonical_path}
    else
      false -> {:error, :artifact_path_outside_workspace}
      {:error, _reason} -> {:error, :artifact_file_not_found}
    end
  end

  defp local_artifact_path(_uri, _workspace), do: {:error, :artifact_path_must_be_absolute}

  defp inside_workspace?(path, workspace) do
    path != workspace and String.starts_with?(path, workspace <> "/")
  end

  defp require_regular_file(%File.Stat{type: :regular}), do: :ok
  defp require_regular_file(_stat), do: {:error, :artifact_not_regular_file}

  defp require_artifact_size(actual, actual), do: :ok
  defp require_artifact_size(_actual, _expected), do: {:error, :artifact_byte_size_mismatch}

  defp require_artifact_sha(bytes, expected) when is_binary(expected) do
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    if actual == String.downcase(expected), do: :ok, else: {:error, :artifact_sha256_mismatch}
  end

  defp require_artifact_sha(_bytes, _expected), do: {:error, :artifact_sha256_mismatch}

  defp require_artifact_under_limit(size, opts) do
    limit = Keyword.get(opts, :max_artifact_bytes, Config.settings!().linear_agent.proof.max_file_bytes)
    if is_integer(limit) and size <= limit, do: :ok, else: {:error, :artifact_too_large}
  end

  defp validate_media_content(%{"kind" => "image"} = artifact, path, bytes, opts) do
    with {:ok, detected_mime, header_width, header_height} <- image_dimensions(bytes),
         {:ok, width, height} <- decode_image_dimensions(path, opts),
         true <- detected_mime == normalized_image_mime(artifact["mimeType"]),
         true <- width == header_width and height == header_height,
         :ok <- validate_media_dimensions(width, height, opts),
         true <- width == artifact["width"] and height == artifact["height"] do
      :ok
    else
      false -> {:error, :artifact_image_metadata_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_media_content(%{"kind" => "video"} = artifact, path, _bytes, opts) do
    executor = Keyword.get(opts, :ffprobe_executor, &default_ffprobe/2)

    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=codec_type,width,height:format=duration",
      "-of",
      "json",
      path
    ]

    with {output, 0} <- executor.(args, Path.dirname(path)),
         {:ok, payload} <- Jason.decode(output),
         [%{"codec_type" => "video"} = stream | _] <- payload["streams"],
         {duration, ""} <- Float.parse(get_in(payload, ["format", "duration"]) || ""),
         :ok <- validate_video_dimensions(artifact, stream),
         :ok <- validate_media_dimensions(stream["width"], stream["height"], opts),
         :ok <- validate_video_duration(duration, opts),
         true <- abs(round(duration * 1_000) - artifact["durationMs"]) <= 50,
         :ok <- validate_video_decode(path, opts) do
      :ok
    else
      false -> {:error, :artifact_video_duration_mismatch}
      _invalid -> {:error, :artifact_video_decode_failed}
    end
  end

  defp validate_media_content(_artifact, _path, _bytes, _opts), do: {:error, :invalid_factory_artifact}

  defp image_dimensions(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", width::32, height::32, _::binary>>)
       when width > 0 and height > 0,
       do: {:ok, "image/png", width, height}

  defp image_dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg_dimensions(rest)
  defp image_dimensions(_bytes), do: {:error, :artifact_image_decode_failed}

  defp normalized_image_mime("image/jpg"), do: "image/jpeg"
  defp normalized_image_mime(mime), do: mime

  defp jpeg_dimensions(<<0xFF, marker, length::16, rest::binary>>)
       when marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF] and
              length >= 7 do
    case rest do
      <<_precision, height::16, width::16, _::binary>> when width > 0 and height > 0 ->
        {:ok, "image/jpeg", width, height}

      _invalid ->
        {:error, :artifact_image_decode_failed}
    end
  end

  defp jpeg_dimensions(<<0xFF, marker, rest::binary>>) when marker in [0xD8, 0xD9, 0x01] or marker in 0xD0..0xD7,
    do: jpeg_dimensions(rest)

  defp jpeg_dimensions(<<0xFF, _marker, length::16, rest::binary>>) when length >= 2 do
    skip = length - 2

    if byte_size(rest) >= skip,
      do: jpeg_dimensions(binary_part(rest, skip, byte_size(rest) - skip)),
      else: {:error, :artifact_image_decode_failed}
  end

  defp jpeg_dimensions(<<_byte, rest::binary>>), do: jpeg_dimensions(rest)
  defp jpeg_dimensions(_bytes), do: {:error, :artifact_image_decode_failed}

  defp validate_video_dimensions(artifact, stream) do
    matches_width = is_nil(artifact["width"]) or artifact["width"] == stream["width"]
    matches_height = is_nil(artifact["height"]) or artifact["height"] == stream["height"]
    if matches_width and matches_height, do: :ok, else: {:error, :artifact_video_dimensions_mismatch}
  end

  defp validate_media_dimensions(width, height, opts)
       when is_integer(width) and is_integer(height) and width > 0 and height > 0 do
    limit = Keyword.get(opts, :max_media_dimension, @max_media_dimension)
    if width <= limit and height <= limit, do: :ok, else: {:error, :artifact_dimensions_too_large}
  end

  defp validate_media_dimensions(_width, _height, _opts), do: {:error, :artifact_invalid_dimensions}

  defp validate_video_duration(duration_seconds, opts) when is_number(duration_seconds) and duration_seconds > 0 do
    limit = Keyword.get(opts, :max_video_duration_ms, @max_video_duration_ms)
    if round(duration_seconds * 1_000) <= limit, do: :ok, else: {:error, :artifact_duration_too_long}
  end

  defp validate_video_duration(_duration_seconds, _opts), do: {:error, :artifact_video_duration_mismatch}

  defp decode_image_dimensions(path, opts) do
    executor = Keyword.get(opts, :image_decoder_executor, &default_image_decoder/2)

    with {output, 0} <- executor.(["-g", "pixelWidth", "-g", "pixelHeight", path], Path.dirname(path)),
         [_, width_text] <- Regex.run(~r/pixelWidth:\s*(\d+)/, output),
         [_, height_text] <- Regex.run(~r/pixelHeight:\s*(\d+)/, output),
         {width, ""} <- Integer.parse(width_text),
         {height, ""} <- Integer.parse(height_text) do
      {:ok, width, height}
    else
      _invalid -> {:error, :artifact_image_decode_failed}
    end
  end

  defp default_image_decoder(args, cwd), do: media_executor_result("sips", args, cwd)

  defp default_ffprobe(args, cwd), do: media_executor_result("ffprobe", args, cwd)

  defp validate_video_decode(path, opts) do
    decoder = Keyword.get(opts, :video_decoder_executor, &default_video_decoder/2)

    case decoder.(["-v", "error", "-i", path, "-map", "0:v:0", "-f", "null", "-"], Path.dirname(path)) do
      {_output, 0} -> :ok
      _failed -> {:error, :artifact_video_decode_failed}
    end
  end

  defp default_video_decoder(args, cwd), do: media_executor_result("ffmpeg", args, cwd)

  defp media_executor_result(command, args, cwd) do
    case run_media_command(command, args, cwd, []) do
      {:ok, result} -> result
      {:error, reason} -> {"media command failed: #{inspect(reason)}", 1}
    end
  end

  defp run_media_command(command, args, cwd, opts)
       when command in @media_commands and is_list(args) and is_binary(cwd) do
    resolver = Keyword.get(opts, :executable_resolver, &System.find_executable/1)
    timeout_ms = Keyword.get(opts, :timeout_ms, @media_command_timeout_ms)
    output_limit = Keyword.get(opts, :max_output_bytes, @max_media_command_output_bytes)

    with executable when is_binary(executable) <- resolver.(command),
         true <- File.regular?(executable),
         {:ok, port} <- open_media_port(executable, args, cwd) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect_media_output(port, "", timeout_ms, output_limit, deadline)
    else
      nil -> {:error, {:media_command_not_found, command}}
      false -> {:error, {:media_command_not_found, command}}
      {:error, _reason} = error -> error
    end
  end

  defp run_media_command(command, _args, _cwd, _opts),
    do: {:error, {:media_command_not_allowed, command}}

  defp open_media_port(executable, args, cwd) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, String.to_charlist(cwd)},
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:env, private_media_environment()}
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, {:media_port_open_failed, Exception.message(error)}}
  end

  defp collect_media_output(port, output, timeout_ms, output_limit, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      close_media_port(port, {:media_command_timeout, timeout_ms})
    else
      receive do
        {^port, {:data, bytes}} ->
          next = output <> bytes

          if byte_size(next) <= output_limit do
            collect_media_output(port, next, timeout_ms, output_limit, deadline)
          else
            close_media_port(port, :media_command_output_too_large)
          end

        {^port, {:exit_status, status}} ->
          {:ok, {output, status}}
      after
        remaining_ms -> close_media_port(port, {:media_command_timeout, timeout_ms})
      end
    end
  end

  defp close_media_port(port, reason) do
    :ok = BoundedPort.terminate(port)
    {:error, reason}
  end

  defp private_media_environment do
    cleared = System.get_env() |> Map.keys() |> Enum.map(&{String.to_charlist(&1), false})

    inherited =
      ["PATH", "TMPDIR", "LANG", "LC_ALL"]
      |> Enum.flat_map(fn name ->
        case System.get_env(name) do
          value when is_binary(value) -> [{String.to_charlist(name), String.to_charlist(value)}]
          _missing -> []
        end
      end)

    cleared ++ inherited
  end

  defp verify_remote_artifact_receipt(event, opts) do
    case Keyword.get(opts, :artifact_receipt_verifier) do
      verifier when is_function(verifier, 1) ->
        with {:ok, receipt} when is_map(receipt) <- verifier.(event),
             :ok <- validate_remote_artifact_receipt(event, receipt) do
          :ok
        else
          :ok -> {:error, :invalid_remote_artifact_receipt}
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_remote_artifact_receipt}
        end

      _missing ->
        {:error, :untrusted_remote_artifact}
    end
  end

  defp validate_remote_artifact_receipt(
         %{"runId" => run_id, "issue" => issue, "payload" => %{"artifact" => artifact}},
         %{"runId" => run_id, "issue" => issue, "commitSha" => commit, "artifactSha256" => digest, "uri" => uri}
       )
       when is_binary(commit) and is_binary(digest) and is_binary(uri) do
    if String.downcase(commit) == String.downcase(artifact["commitSha"]) and
         String.downcase(digest) == String.downcase(artifact["sha256"]) and uri == artifact["uri"] do
      :ok
    else
      {:error, :remote_artifact_receipt_binding_mismatch}
    end
  end

  defp validate_remote_artifact_receipt(_event, _receipt), do: {:error, :invalid_remote_artifact_receipt}

  defp validate_event_against_journal(
         %{
           "type" => "artifact.created",
           "phase" => phase,
           "payload" => %{"artifact" => artifact}
         },
         journal
       ) do
    head = journal["integrated_head"]
    artifact_head = artifact["commitSha"]
    expected_attempt = get_in(journal, ["phase_attempts", phase])

    cond do
      !is_binary(head) or !is_binary(artifact_head) or String.downcase(artifact_head) != head ->
        {:error, :artifact_commit_not_integrated}

      artifact["runId"] != journal["run_id"] ->
        {:error, :artifact_run_not_bound}

      !is_integer(expected_attempt) or artifact["attempt"] != expected_attempt ->
        {:error, :artifact_attempt_not_bound}

      true ->
        :ok
    end
  end

  defp validate_event_against_journal(
         %{
           "type" => "check.completed",
           "phase" => phase,
           "payload" => %{"status" => "passed"} = payload
         },
         journal
       )
       when phase in ["review", "qa"] do
    trusted = Map.get(payload, "required", true) and Map.get(payload, "acceptance", true)
    commit = payload["commitSha"]

    if !trusted or (is_binary(commit) and String.downcase(commit) == journal["integrated_head"]),
      do: :ok,
      else: {:error, :check_commit_not_integrated}
  end

  defp validate_event_against_journal(_event, _journal), do: :ok

  defp upload_artifact(path, content_type, bytes, opts)
       when is_binary(content_type) and is_binary(bytes) do
    client = Keyword.get(opts, :linear_agent_client, AgentClient)
    client_opts = Keyword.get(opts, :linear_agent_client_opts, [])

    if is_function(client, 4) do
      client.(Path.basename(path), content_type, bytes, client_opts)
    else
      client.upload_file(Path.basename(path), content_type, bytes, client_opts)
    end
  end

  defp upload_artifact(_path, _content_type, _bytes, _opts),
    do: {:error, :invalid_artifact_content_type}

  defp require_allowed_artifact_uri(uri, allowed_hosts)
       when is_binary(uri) and is_list(allowed_hosts) do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host, userinfo: nil, port: port}
      when is_binary(host) and host != "" and port in [nil, 443] ->
        if String.downcase(host) in Enum.map(allowed_hosts, &String.downcase/1) do
          :ok
        else
          {:error, {:artifact_url_host_not_allowed, host}}
        end

      _uri ->
        {:error, :artifact_uri_must_be_https}
    end
  end

  defp require_allowed_artifact_uri(_uri, _allowed_hosts), do: {:error, :artifact_uri_must_be_https}

  defp record_published_event(
         journal_path,
         journal,
         phase,
         event_id,
         digest,
         factory_phase_stream?,
         event
       ) do
    journal = put_in(journal, ["processed_events", event_id], digest)
    journal = record_event_facts(journal, event)

    journal =
      if factory_phase_stream? do
        phase_events = get_in(journal, ["phase_events", phase]) || []
        put_in(journal, ["phase_events", phase], phase_events ++ [event_id])
      else
        journal
      end

    case write_journal(journal_path, journal) do
      :ok -> {:ok, journal}
      {:error, reason} -> {:error, {:journal_write_failed, reason}}
    end
  end

  defp record_event_facts(journal, %{
         "type" => "plan.updated",
         "phase" => "planning",
         "payload" => payload
       }) do
    journal
    |> Map.put("work_scope", payload["workScope"])
    |> Map.put("post_merge_internal_build", payload["postMergeInternalBuild"])
    |> Map.put("proof_targets", payload["proofTargets"] || [])
  end

  defp record_event_facts(journal, %{
         "type" => "phase.started",
         "phase" => phase,
         "payload" => %{"attempt" => attempt}
       }) do
    put_in(journal, ["phase_attempts", phase], attempt)
  end

  defp record_event_facts(
         journal,
         %{
           "type" => type,
           "phase" => phase,
           "payload" => %{"commitShas" => commits}
         } = event
       )
       when type in ["diff.updated", "phase.completed"] and is_list(commits) do
    normalized = Enum.map(commits, &String.downcase/1)
    journal = put_in(journal, ["phase_commits", phase], normalized)
    journal = if type == "phase.completed", do: put_in(journal, ["completed_phases", phase], true), else: journal

    journal =
      if type == "diff.updated" do
        record_change_binding(journal, event, normalized)
      else
        journal
      end

    if normalized == [], do: journal, else: Map.put(journal, "integrated_head", List.last(normalized))
  end

  defp record_event_facts(journal, %{
         "type" => "artifact.created",
         "phase" => phase,
         "payload" => %{"artifact" => %{"storage" => storage, "commitSha" => commit} = artifact}
       })
       when storage in ["linear_attachment", "remote_url"] do
    normalized = String.downcase(commit)

    proof =
      Map.take(artifact, ["kind", "platform", "flow", "relation"])
      |> Map.put("commitSha", normalized)
      |> Map.put("phase", phase)

    journal
    |> Map.update!("proof_count", &(&1 + 1))
    |> Map.update!("proof_heads", &Enum.uniq(&1 ++ [normalized]))
    |> Map.update!("proof_artifacts", &Enum.uniq(&1 ++ [proof]))
  end

  defp record_event_facts(journal, %{
         "type" => "check.completed",
         "phase" => phase,
         "payload" => %{"status" => "passed", "commitSha" => commit} = payload
       })
       when phase in ["review", "qa"] do
    trusted = Map.get(payload, "required", true) and Map.get(payload, "acceptance", true)

    if trusted do
      journal
      |> Map.put("#{phase}_trusted", true)
      |> update_in(["trusted_check_heads", phase], &Enum.uniq(&1 ++ [String.downcase(commit)]))
    else
      journal
    end
  end

  defp record_event_facts(journal, %{
         "type" => "pr.updated",
         "payload" => %{"state" => state, "qualityCheck" => quality}
       }) do
    journal
    |> Map.put("github_state", state)
    |> Map.put(
      "quality_passed",
      quality == %{"name" => "factory/quality-gate", "status" => "passed"}
    )
  end

  defp record_event_facts(journal, _event), do: journal

  defp record_change_binding(journal, event, commit_shas) do
    phase = event["phase"]
    agent_id = event["agentId"] || "phase"

    session_id =
      if agent_id == "phase" do
        get_in(journal, ["phase_sessions", phase])
      else
        get_in(journal, ["agent_sessions", "#{phase}:#{agent_id}"])
      end

    if is_binary(session_id) and String.trim(session_id) != "" do
      key = {phase, agent_id, session_id}

      prior_commits =
        journal["change_bindings"]
        |> Enum.find_value([], &commits_for_change_binding(&1, key))

      binding = %{
        "phase" => phase,
        "agent_id" => agent_id,
        "session_id" => session_id,
        "commit_shas" => Enum.uniq(prior_commits ++ commit_shas)
      }

      bindings =
        journal["change_bindings"]
        |> Enum.reject(&({&1["phase"], &1["agent_id"], &1["session_id"]} == key))
        |> Kernel.++([binding])

      Map.put(journal, "change_bindings", bindings)
    else
      journal
    end
  end

  defp commits_for_change_binding(binding, key) do
    if {binding["phase"], binding["agent_id"], binding["session_id"]} == key,
      do: binding["commit_shas"]
  end

  defp bind_journal_run(%{"run_id" => nil} = journal, run_id) when is_binary(run_id),
    do: {:ok, %{journal | "run_id" => run_id}}

  defp bind_journal_run(%{"run_id" => run_id} = journal, run_id), do: {:ok, journal}

  defp bind_journal_run(%{"run_id" => expected}, actual),
    do: {:error, {:factory_run_id_mismatch, actual, expected}}

  defp require_before_terminal(nil, _event), do: :ok

  defp require_before_terminal(terminal_type, event),
    do: {:error, {:event_after_terminal, terminal_type, event["type"]}}

  defp terminal_type_for_event(nil, event) do
    if Protocol.terminal_event?(event), do: event["type"], else: nil
  end

  defp terminal_type_for_event(terminal_type, _event), do: terminal_type

  defp validate_phase_event_sequence(journal, phase, event, event_index) do
    expected_events = get_in(journal, ["phase_events", phase]) || []
    actual_event_id = event["eventId"]

    case Enum.fetch(expected_events, event_index) do
      {:ok, expected_event_id} when expected_event_id == actual_event_id ->
        :ok

      {:ok, expected_event_id} ->
        {:error, {:factory_phase_replay_mismatch, phase, event_index, actual_event_id, expected_event_id}}

      :error ->
        :ok
    end
  end

  defp require_complete_phase_sequence(journal, phase, event_count) do
    expected_count = journal |> get_in(["phase_events", phase]) |> Kernel.||([]) |> length()

    if event_count == expected_count do
      :ok
    else
      {:error, {:factory_phase_replay_incomplete, phase, event_count, expected_count}}
    end
  end

  defp require_all_phases_completed(journal, phases) do
    if Enum.all?(phases, &(get_in(journal, ["completed_phases", &1]) == true)) do
      :ok
    else
      {:error, :factory_phase_completion_missing}
    end
  end

  defp validate_phase(%{"phase" => phase}, phase), do: :ok
  defp validate_phase(%{"phase" => actual}, expected), do: {:error, {:wrong_phase, actual, expected}}

  defp validate_issue(%{"issue" => identifier}, identifier), do: :ok
  defp validate_issue(%{"issue" => actual}, expected), do: {:error, {:wrong_issue, actual, expected}}

  defp validate_project(%{"project" => project}, project), do: :ok
  defp validate_project(%{"project" => actual}, expected), do: {:error, {:wrong_project, actual, expected}}

  defp validate_event_urls(%{"type" => "pr.updated", "payload" => %{"url" => url}}, settings)
       when is_binary(url) do
    GitHub.validate_pull_request_url(url, settings.github.repository)
  end

  defp validate_event_urls(
         %{
           "type" => "check.completed",
           "payload" => %{"name" => "post-merge/internal-build", "url" => url}
         },
         settings
       ) do
    GitHub.validate_actions_run_url(url, settings.github.repository)
  end

  defp validate_event_urls(
         %{"type" => "artifact.created", "payload" => %{"artifact" => %{"storage" => "local_file"}}},
         _settings
       ),
       do: :ok

  defp validate_event_urls(
         %{"type" => "artifact.created", "payload" => %{"artifact" => %{"uri" => uri}}},
         settings
       ) do
    require_allowed_artifact_uri(uri, settings.proof_url_hosts)
  end

  defp validate_event_urls(_event, _settings), do: :ok

  defp validate_factory_event_policy(%{
         "type" => "pr.updated",
         "payload" => %{"state" => "merged"}
       }),
       do: {:error, :github_finalization_is_symphony_owned}

  defp validate_factory_event_policy(%{
         "type" => "pr.updated",
         "payload" => %{"qualityCheck" => %{"status" => "passed"}}
       }),
       do: {:error, :quality_gate_is_symphony_owned}

  defp validate_factory_event_policy(_event), do: :ok

  defp validate_line_size(line) when byte_size(line) <= @max_line_bytes, do: :ok
  defp validate_line_size(_line), do: {:error, :event_line_too_large}

  defp stop_with_error(port, reason) do
    :ok = BoundedPort.terminate(port)
    {:error, reason}
  end

  defp open_port(executable, args, workspace, issue, phase, feedback) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          {:line, @max_line_bytes},
          {:cd, String.to_charlist(workspace)},
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:env, factory_env(issue, phase, feedback)}
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, {:port_open_failed, Exception.message(error)}}
  end

  defp factory_env(issue, phase, feedback) do
    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.map(&{String.to_charlist(&1), false})

    inherited =
      ["PATH", "TMPDIR", "LANG", "LC_ALL"]
      |> Enum.flat_map(fn name ->
        case System.get_env(name) do
          value when is_binary(value) -> [{String.to_charlist(name), String.to_charlist(value)}]
          _missing -> []
        end
      end)

    factory = [
      {~c"SYMPHONY_FACTORY_PROTOCOL_VERSION", ~c"1"},
      {~c"SYMPHONY_FACTORY_ISSUE_ID", String.to_charlist(issue.id || "")},
      {~c"SYMPHONY_FACTORY_ISSUE_IDENTIFIER", String.to_charlist(issue.identifier || "")},
      {~c"SYMPHONY_FACTORY_PHASE", String.to_charlist(phase)},
      {~c"SYMPHONY_FACTORY_REVIEW_FEEDBACK_JSON", feedback_json(feedback) |> String.to_charlist()}
    ]

    cleared ++ inherited ++ factory
  end

  defp resolve_executable(command) when is_binary(command) do
    case Path.type(command) do
      :absolute ->
        if File.regular?(command), do: {:ok, command}, else: {:error, :factory_command_not_found}

      _ ->
        case System.find_executable(command) do
          nil -> {:error, :factory_command_not_found}
          executable -> {:ok, executable}
        end
    end
  end

  defp render_args(args, issue, phase, workspace, feedback, journal, project_key) do
    replacements = %{
      "{{ tracker.project_slug }}" => project_key || "",
      "{{ factory.project_key }}" => project_key || "",
      "{{ issue.id }}" => issue.id || "",
      "{{ issue.identifier }}" => issue.identifier || "",
      "{{ workspace }}" => workspace,
      "{{ phase }}" => phase,
      "{{ review_feedback }}" => feedback_json(feedback)
    }

    rendered =
      Enum.map(args, fn arg ->
        Enum.reduce(replacements, arg, fn {placeholder, replacement}, current ->
          String.replace(current, placeholder, replacement)
        end)
      end)

    rendered = put_authoritative_option(rendered, "--project", project_key)
    rendered = put_authoritative_option(rendered, "--run-id", journal["run_id"])

    case {phase, journal["work_scope"]} do
      {"planning", _scope} -> {:ok, drop_option(rendered, "--work-scope")}
      {_phase, scope} when is_binary(scope) -> {:ok, put_authoritative_option(rendered, "--work-scope", scope)}
      _missing -> {:error, :planning_work_scope_missing}
    end
  end

  defp put_authoritative_option(args, option, value) when is_binary(value) do
    drop_option(args, option) ++ [option, value]
  end

  defp drop_option([option, _value | rest], option), do: drop_option(rest, option)
  defp drop_option([option], option), do: []
  defp drop_option([head | rest], option), do: [head | drop_option(rest, option)]
  defp drop_option([], _option), do: []

  defp feedback_json(feedback) when is_list(feedback) do
    feedback
    |> Enum.map(fn entry ->
      %{
        "id" => entry[:id] || entry["id"],
        "body" => entry[:body] || entry["body"],
        "action" => entry[:action] || entry["action"]
      }
    end)
    |> Jason.encode!()
  end

  defp feedback_json(_feedback), do: "[]"

  defp trusted_journal_path(issue, project, workspace, settings, feedback_digest, opts) do
    state_root = Keyword.get(opts, :factory_state_root, Config.factory_state_root(settings))

    with true <- is_binary(project) and String.trim(project) != "",
         :ok <- File.mkdir_p(state_root),
         :ok <- File.chmod(state_root, 0o700),
         {:ok, canonical_root} <- PathSafety.canonicalize(state_root),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         false <- inside_workspace?(canonical_root, canonical_workspace) do
      issue_key = identity_digest([project, issue.id, issue.identifier])
      issue_root = Path.join(canonical_root, issue_key)

      with :ok <- File.mkdir_p(issue_root),
           :ok <- File.chmod(issue_root, 0o700) do
        select_lifecycle_journal(issue_root, feedback_digest)
      end
    else
      false -> {:error, :factory_project_key_missing}
      true -> {:error, :factory_state_root_inside_workspace}
      {:error, reason} -> {:error, {:factory_state_root_unavailable, reason}}
    end
  end

  defp identity_digest(parts) do
    parts
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp select_lifecycle_journal(issue_root, feedback_digest) do
    matching =
      issue_root
      |> Path.join("generation-*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.filter(fn path -> matching_journal?(path, feedback_digest) end)

    completed = Enum.filter(matching, &completed_journal?/1)
    resumable = Enum.reject(matching, &completed_journal?/1)

    case {completed, resumable} do
      {[path], []} -> {:ok, path}
      {[], []} -> {:ok, Path.join(issue_root, "generation-#{random_generation_id()}.json")}
      {[], [path]} -> {:ok, path}
      _multiple -> {:error, :ambiguous_factory_lifecycle_generation}
    end
  end

  defp matching_journal?(path, feedback_digest) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"feedback_digest" => ^feedback_digest}} <- Jason.decode(bytes) do
      true
    else
      _other -> false
    end
  end

  defp completed_journal?(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"completed" => true}} <- Jason.decode(bytes) do
      true
    else
      _other -> false
    end
  end

  defp random_generation_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp load_journal(path, issue, project, feedback_digest, run_id) do
    case File.read(path) do
      {:ok, bytes} ->
        decode_journal(bytes, issue, project, feedback_digest)

      {:error, :enoent} ->
        {:ok, new_journal(issue, project, feedback_digest, Path.basename(path, ".json"), run_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_journal(bytes, issue, project, feedback_digest) do
    with {:ok, journal} <- decode_journal_json(bytes),
         {:ok, binding} <- validate_journal_shape(journal) do
      validate_loaded_journal(journal, binding, issue, project, feedback_digest)
    end
  end

  defp decode_journal_json(bytes) do
    case Jason.decode(bytes) do
      {:ok, journal} -> {:ok, journal}
      {:error, reason} -> {:error, {:invalid_factory_journal, Exception.message(reason)}}
    end
  end

  defp validate_journal_shape(%{"version" => @journal_version, "binding" => binding} = journal)
       when is_map(binding) do
    if valid_journal_fields?(journal), do: {:ok, binding}, else: {:error, :invalid_factory_journal}
  end

  defp validate_journal_shape(_journal), do: {:error, :invalid_factory_journal}

  defp valid_journal_fields?(journal) do
    required_maps =
      ~w(phase_sessions agent_sessions processed_events phase_events phase_commits phase_attempts completed_phases trusted_check_heads)

    required_booleans = ~w(review_trusted qa_trusted completed)

    valid_journal_identity?(journal) and valid_journal_collections?(journal, required_maps, required_booleans) and
      valid_journal_proof?(journal) and valid_change_bindings?(journal["change_bindings"])
  end

  defp valid_journal_identity?(journal) do
    is_binary(journal["generation_id"]) and is_binary(journal["feedback_digest"]) and
      is_binary(journal["started_at"]) and optional_binary?(journal["run_id"]) and
      optional_binary?(journal["integrated_head"])
  end

  defp valid_journal_collections?(journal, required_maps, required_booleans) do
    is_integer(journal["proof_count"]) and journal["proof_count"] >= 0 and
      Enum.all?(required_maps, &is_map(journal[&1])) and
      Enum.all?(required_booleans, &is_boolean(journal[&1]))
  end

  defp valid_journal_proof?(journal) do
    valid_sha_list?(journal["proof_heads"]) and is_list(journal["proof_artifacts"]) and
      is_list(journal["proof_targets"]) and valid_work_scope?(journal["work_scope"]) and
      is_boolean(journal["post_merge_internal_build"]) and valid_optional_map?(journal["post_merge_result"]) and
      journal["github_state"] in [nil, "draft", "open", "merged", "closed"] and
      is_boolean(journal["quality_passed"]) and
      Enum.all?(["review", "qa"], &valid_sha_list?(get_in(journal, ["trusted_check_heads", &1])))
  end

  defp valid_work_scope?(nil), do: true
  defp valid_work_scope?(scope), do: scope in ["non-runtime", "runtime-static", "runtime-interactive"]

  defp valid_optional_map?(nil), do: true
  defp valid_optional_map?(value), do: is_map(value)

  defp valid_sha_list?(values) when is_list(values) do
    Enum.uniq(values) == values and
      Enum.all?(values, &(is_binary(&1) and Regex.match?(~r/\A[0-9a-f]{40}\z/, &1)))
  end

  defp valid_sha_list?(_values), do: false

  defp valid_change_bindings?(bindings) when is_list(bindings) do
    keys = Enum.map(bindings, &{&1["phase"], &1["agent_id"], &1["session_id"]})

    Enum.uniq(keys) == keys and
      Enum.all?(bindings, fn binding ->
        is_map(binding) and binding["phase"] in Protocol.phases() and
          nonempty_binary?(binding["agent_id"]) and nonempty_binary?(binding["session_id"]) and
          valid_sha_list?(binding["commit_shas"])
      end)
  end

  defp valid_change_bindings?(_bindings), do: false

  defp nonempty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value)

  defp validate_loaded_journal(journal, binding, issue, project, feedback_digest) do
    expected = journal_binding(issue, project)

    cond do
      binding != expected ->
        {:error, {:factory_journal_binding_mismatch, binding, expected}}

      journal["feedback_digest"] != feedback_digest ->
        {:error, :factory_journal_feedback_mismatch}

      !valid_timestamp?(journal["started_at"]) ->
        {:error, :invalid_factory_journal}

      !valid_processed_events?(journal["processed_events"]) ->
        {:error, :invalid_factory_journal}

      !valid_phase_events?(journal["phase_events"], journal["processed_events"]) ->
        {:error, :invalid_factory_journal}

      !valid_completed_phases?(journal["completed_phases"], journal["phase_events"]) ->
        {:error, :invalid_factory_journal}

      true ->
        {:ok, journal}
    end
  end

  defp valid_processed_events?(events) do
    Enum.all?(events, fn {event_id, digest} ->
      is_binary(event_id) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
    end)
  end

  defp valid_phase_events?(phase_events, processed_events) do
    Map.keys(phase_events) -- Protocol.phases() == [] and
      Enum.all?(phase_events, fn {_phase, event_ids} ->
        is_list(event_ids) and event_ids != [] and Enum.uniq(event_ids) == event_ids and
          Enum.all?(event_ids, &Map.has_key?(processed_events, &1))
      end)
  end

  defp valid_completed_phases?(completed_phases, phase_events) do
    Map.keys(completed_phases) -- Protocol.phases() == [] and
      Enum.all?(completed_phases, fn {phase, completed} ->
        completed == true and is_list(phase_events[phase]) and phase_events[phase] != []
      end)
  end

  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false

  defp new_journal(issue, project, feedback_digest, generation_id, run_id) do
    %{
      "version" => @journal_version,
      "generation_id" => generation_id,
      "feedback_digest" => feedback_digest,
      "binding" => journal_binding(issue, project),
      "started_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "run_id" => run_id,
      "phase_sessions" => %{},
      "agent_sessions" => %{},
      "processed_events" => %{},
      "phase_events" => %{},
      "phase_commits" => %{},
      "change_bindings" => [],
      "phase_attempts" => %{},
      "completed_phases" => %{},
      "integrated_head" => nil,
      "proof_count" => 0,
      "proof_heads" => [],
      "proof_artifacts" => [],
      "proof_targets" => [],
      "work_scope" => nil,
      "post_merge_internal_build" => false,
      "post_merge_result" => nil,
      "github_state" => nil,
      "quality_passed" => false,
      "review_trusted" => false,
      "qa_trusted" => false,
      "trusted_check_heads" => %{"review" => [], "qa" => []},
      "completed" => false
    }
  end

  defp journal_binding(issue, project) do
    %{
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "project" => project
    }
  end

  defp write_journal(path, journal) do
    temporary_path = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(temporary_path, Jason.encode!(journal, pretty: true)),
         :ok <- File.chmod(temporary_path, 0o600) do
      File.rename(temporary_path, path)
    end
  end

  defp deterministic_uuid(seed) do
    <<a::binary-size(6), version_byte, b::binary-size(1), variant_byte, c::binary-size(7), _rest::binary>> =
      :crypto.hash(:sha256, seed)

    bytes =
      a <>
        <<Bitwise.band(version_byte, 0x0F) |> Bitwise.bor(0x40)>> <>
        b <>
        <<Bitwise.band(variant_byte, 0x3F) |> Bitwise.bor(0x80)>> <> c

    Base.encode16(bytes, case: :lower)
    |> then(fn hex ->
      binary_part(hex, 0, 8) <>
        "-" <>
        binary_part(hex, 8, 4) <>
        "-" <>
        binary_part(hex, 12, 4) <>
        "-" <>
        binary_part(hex, 16, 4) <>
        "-" <>
        binary_part(hex, 20, 12)
    end)
  end

  defp random_run_id, do: deterministic_uuid(:crypto.strong_rand_bytes(32))

  defp bridge_call(bridge, function, arguments) when is_atom(bridge) do
    apply(bridge, function, arguments)
  end

  defp bridge_call(bridge, function, arguments) when is_function(bridge) do
    bridge.(function, arguments)
  end
end
