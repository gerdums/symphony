defmodule SymphonyElixir.Factory.Grooming do
  @moduledoc false

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Factory.BoundedPort
  alias SymphonyElixir.Linear.AgentBridge
  alias SymphonyElixir.Tracker.Issue

  @max_output_bytes 1_048_576
  @fingerprint_version 1

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    settings = Config.settings!()
    stage = settings.factory.grooming

    cond do
      !settings.factory.enabled or !stage.enabled ->
        :ok

      settings.tracker.kind != "linear" ->
        {:error, :factory_grooming_requires_linear}

      true ->
        bridge = Keyword.get(opts, :bridge, AgentBridge)
        fetcher = Keyword.get(opts, :issue_fetcher, &Tracker.fetch_issues_by_states/1)

        with {:ok, issues} <- fetcher.([stage.backlog_state]) do
          groom_issues(issues, settings, stage, bridge, opts)
        end
    end
  end

  defp groom_issues([], _settings, _stage, _bridge, _opts), do: :ok

  defp groom_issues(issues, settings, stage, bridge, opts) do
    with {:ok, input_path, cleanup} <- write_private_input(issues),
         {:ok, executable} <- resolve_executable(settings.factory.command) do
      try do
        args = render_args(stage.args, input_path, settings.factory.project_key)

        with {:ok, output} <- run_command(executable, args, Path.dirname(input_path), stage.timeout_ms, opts),
             {:ok, decisions} <- parse_decisions(output, issues, stage, settings.factory.project_key),
             fingerprint_path <-
               Keyword.get(
                 opts,
                 :fingerprint_path,
                 Path.join(Config.factory_state_root(settings.factory), "grooming-fingerprints-v1.json")
               ),
             {:ok, fingerprints} <- load_fingerprints(fingerprint_path) do
          apply_decisions(
            decisions,
            issues,
            bridge,
            stage,
            settings.factory.project_key,
            fingerprint_path,
            fingerprints
          )
        end
      after
        cleanup.()
      end
    end
  end

  defp write_private_input(issues) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(System.tmp_dir!(), "symphony-grooming-#{nonce}")
    path = Path.join(directory, "backlog.json")
    payload = Enum.map(issues, &issue_payload/1)

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, Jason.encode!(payload), [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      cleanup = fn ->
        _ = File.rm(path)
        _ = File.rmdir(directory)
      end

      {:ok, path, cleanup}
    end
  end

  defp issue_payload(%Issue{} = issue) do
    %{
      "key" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "labels" => issue.labels,
      "status" => issue.state,
      "acceptanceCriteria" => acceptance_criteria(issue.description),
      "relations" => blocker_relations(issue.blocked_by)
    }
  end

  defp blocker_relations(blockers) when is_list(blockers) do
    blockers
    |> Enum.map(fn blocker -> blocker[:identifier] || blocker["identifier"] end)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{"type" => "blockedBy", "issueKey" => &1})
  end

  defp blocker_relations(_blockers), do: []

  defp acceptance_criteria(description) when is_binary(description) do
    Regex.scan(~r/^\s*[-*]\s+\[(?: |x|X)\]\s+(.+)$/m, description, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp acceptance_criteria(_description), do: []

  defp render_args(args, input_path, project) do
    args
    |> Enum.map(fn arg ->
      arg
      |> String.replace("{{ input }}", input_path)
      |> String.replace("{{ tracker.project_slug }}", project || "")
      |> String.replace("{{ factory.project_key }}", project || "")
    end)
    |> put_authoritative_option("--project", project)
  end

  defp put_authoritative_option(args, option, value) when is_binary(value) do
    drop_option(args, option) ++ [option, value]
  end

  defp drop_option([option, _value | rest], option), do: drop_option(rest, option)
  defp drop_option([option], option), do: []
  defp drop_option([head | rest], option), do: [head | drop_option(rest, option)]
  defp drop_option([], _option), do: []

  defp resolve_executable(command) when is_binary(command) do
    case Path.type(command) do
      :absolute ->
        if File.regular?(command), do: {:ok, command}, else: {:error, :factory_command_not_found}

      _relative ->
        case System.find_executable(command) do
          nil -> {:error, :factory_command_not_found}
          path -> {:ok, path}
        end
    end
  end

  defp run_command(executable, args, cwd, timeout_ms, opts) do
    executor = Keyword.get(opts, :executor)

    if is_function(executor, 4) do
      executor.(executable, args, cwd, timeout_ms)
    else
      run_port(executable, args, cwd, timeout_ms)
    end
  end

  defp run_port(executable, args, cwd, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, String.to_charlist(cwd)},
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:env, private_environment()}
        ]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_output(port, "", timeout_ms, deadline)
  end

  defp collect_output(port, output, timeout_ms, deadline) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      close_port(port, {:factory_grooming_timeout, timeout_ms})
    else
      receive do
        {^port, {:data, bytes}} ->
          next = output <> bytes

          if byte_size(next) <= @max_output_bytes,
            do: collect_output(port, next, timeout_ms, deadline),
            else: close_port(port, :factory_grooming_output_too_large)

        {^port, {:exit_status, 0}} ->
          {:ok, output}

        {^port, {:exit_status, status}} ->
          {:error, {:factory_grooming_exit_status, status}}
      after
        remaining_ms -> close_port(port, {:factory_grooming_timeout, timeout_ms})
      end
    end
  end

  defp close_port(port, reason) do
    :ok = BoundedPort.terminate(port)
    {:error, reason}
  end

  defp private_environment do
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

  defp parse_decisions(output, issues, stage, project) do
    issue_keys = MapSet.new(issues, & &1.identifier)

    with {:ok, %{"dryRun" => true, "agentLed" => true, "project" => ^project, "decisions" => decisions}} <-
           Jason.decode(String.trim(output)),
         true <- is_list(decisions),
         true <- length(decisions) == length(issues),
         :ok <- validate_decisions(decisions, issue_keys, stage) do
      {:ok, decisions}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_factory_grooming_result}
    end
  end

  defp validate_decisions(decisions, issue_keys, stage) do
    keys = Enum.map(decisions, & &1["key"])

    valid? = MapSet.new(keys) == issue_keys and Enum.uniq(keys) == keys and Enum.all?(decisions, &valid_decision?(&1, stage))

    if valid?, do: :ok, else: {:error, :invalid_factory_grooming_decision}
  end

  defp valid_decision?(decision, stage) do
    valid_decision_keys?(decision) and decision["from"] == stage.backlog_state and
      valid_grooming_target?(decision["to"], stage) and valid_reason?(decision["reason"]) and
      valid_enrichment?(decision, stage) and
      is_nil(decision["relatedIssue"])
  end

  defp valid_decision_keys?(decision) do
    Enum.all?(
      Map.keys(decision),
      &(&1 in ["key", "from", "to", "reason", "summary", "acceptanceCriteria", "relatedIssue"])
    )
  end

  defp valid_grooming_target?(target, stage) when is_binary(target),
    do: target in [stage.backlog_state, stage.todo_state]

  defp valid_grooming_target?(_target, _stage), do: false

  defp valid_enrichment?(%{"to" => target} = decision, stage) when target == stage.todo_state do
    valid_reason?(decision["summary"]) and valid_acceptance_criteria?(decision["acceptanceCriteria"])
  end

  defp valid_enrichment?(_decision, _stage), do: true

  defp valid_acceptance_criteria?(criteria) when is_list(criteria) do
    criteria != [] and Enum.uniq(criteria) == criteria and Enum.all?(criteria, &valid_reason?/1)
  end

  defp valid_acceptance_criteria?(_criteria), do: false

  defp valid_reason?(reason) when is_binary(reason), do: String.trim(reason) != ""
  defp valid_reason?(_reason), do: false

  defp apply_decisions(decisions, issues, bridge, stage, project, fingerprint_path, fingerprints) do
    by_identifier = Map.new(issues, &{&1.identifier, &1})

    Enum.reduce_while(decisions, {:ok, fingerprints}, fn decision, {:ok, current_fingerprints} ->
      issue = Map.fetch!(by_identifier, decision["key"])
      fingerprint = grooming_fingerprint(issue, project)

      case apply_decision(
             decision,
             issue,
             bridge,
             stage,
             fingerprint_path,
             current_fingerprints,
             fingerprint
           ) do
        {:ok, next_fingerprints} -> {:cont, {:ok, next_fingerprints}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _fingerprints} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp apply_decision(decision, issue, bridge, stage, fingerprint_path, fingerprints, fingerprint) do
    if unchanged_backlog_decision?(decision, issue, stage, fingerprints, fingerprint) do
      {:ok, fingerprints}
    else
      with :ok <- apply_bridge_decision(bridge, issue, decision) do
        maybe_persist_backlog_fingerprint(
          decision,
          issue,
          stage,
          fingerprint_path,
          fingerprints,
          fingerprint
        )
      end
    end
  end

  defp apply_bridge_decision(bridge, issue, decision) do
    case bridge_call(bridge, issue, decision) do
      :ok -> :ok
      {:error, reason} -> {:error, {:factory_grooming_apply_failed, issue.identifier, reason}}
      other -> {:error, {:factory_grooming_apply_failed, issue.identifier, other}}
    end
  end

  defp maybe_persist_backlog_fingerprint(
         %{"to" => target},
         issue,
         stage,
         fingerprint_path,
         fingerprints,
         fingerprint
       )
       when target == stage.backlog_state do
    next_fingerprints = Map.put(fingerprints, issue.identifier, fingerprint)

    case write_fingerprints(fingerprint_path, next_fingerprints) do
      :ok -> {:ok, next_fingerprints}
      {:error, reason} -> {:error, {:factory_grooming_fingerprint_write_failed, reason}}
    end
  end

  defp maybe_persist_backlog_fingerprint(
         _decision,
         _issue,
         _stage,
         _fingerprint_path,
         fingerprints,
         _fingerprint
       ),
       do: {:ok, fingerprints}

  defp unchanged_backlog_decision?(decision, issue, stage, fingerprints, fingerprint) do
    decision["from"] == stage.backlog_state and decision["to"] == stage.backlog_state and
      fingerprints[issue.identifier] == fingerprint
  end

  defp grooming_fingerprint(issue, project) do
    [
      project || "",
      issue.id || "",
      issue.identifier || "",
      issue.title || "",
      issue.description || "",
      issue.state || "",
      Enum.sort(issue.labels || []),
      acceptance_criteria(issue.description),
      blocker_relations(issue.blocked_by)
    ]
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp load_fingerprints(path) do
    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, %{"version" => @fingerprint_version, "fingerprints" => fingerprints}} <-
               Jason.decode(bytes),
             true <- valid_fingerprints?(fingerprints) do
          {:ok, fingerprints}
        else
          _invalid -> {:error, :invalid_factory_grooming_fingerprints}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:factory_grooming_fingerprint_read_failed, reason}}
    end
  end

  defp valid_fingerprints?(fingerprints) when is_map(fingerprints) do
    Enum.all?(fingerprints, fn {identifier, digest} ->
      is_binary(identifier) and String.trim(identifier) != "" and is_binary(digest) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
    end)
  end

  defp valid_fingerprints?(_fingerprints), do: false

  defp write_fingerprints(path, fingerprints) do
    directory = Path.dirname(path)
    temp = path <> ".tmp-#{System.unique_integer([:positive])}"
    payload = Jason.encode!(%{"version" => @fingerprint_version, "fingerprints" => fingerprints})

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(temp, payload, [:binary, :exclusive]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp)
        {:error, reason}
    end
  end

  defp bridge_call(bridge, issue, decision) when is_function(bridge, 2), do: bridge.(issue, decision)
  defp bridge_call(bridge, issue, decision), do: bridge.report_grooming_decision(issue, decision)
end
