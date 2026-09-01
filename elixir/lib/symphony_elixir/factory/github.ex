defmodule SymphonyElixir.Factory.GitHub do
  @moduledoc """
  Pushes a completed factory branch and merges its pull request after the
  required GitHub check passes.

  Commands run as bounded executable ports with argument lists. No command is
  passed through a shell.
  """

  alias SymphonyElixir.Factory.BoundedPort
  alias SymphonyElixir.Tracker.Issue

  @pr_json_fields "number,url,state,headRefName,baseRefName,headRefOid,baseRefOid"
  @required_check "factory/quality-gate"
  @pending_check_states ~w(EXPECTED IN_PROGRESS PENDING QUEUED REQUESTED WAITING)
  @safe_ref ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/
  @safe_issue_identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @sha ~r/\A[0-9a-f]{40}\z/i
  @max_command_output_bytes 1_048_576
  @default_command_timeout_ms 600_000

  @type pull_request :: %{
          number: pos_integer(),
          url: String.t(),
          state: :open | :merged | :closed,
          head_ref: String.t(),
          base_ref: String.t(),
          head_sha: String.t(),
          base_sha: String.t()
        }

  @doc false
  @spec run_default_command_for_test(String.t(), [String.t()], Path.t(), pos_integer(), pos_integer()) ::
          {String.t(), non_neg_integer()} | {:error, term()}
  def run_default_command_for_test(command, args, workspace, timeout_ms, max_output_bytes) do
    default_execute(command, args, workspace, timeout_ms, max_output_bytes)
  end

  @spec prepare(Issue.t(), Path.t(), map(), keyword()) ::
          {:ok, pull_request()} | {:error, term()}
  def prepare(%Issue{} = issue, workspace, settings, opts \\ [])
      when is_binary(workspace) and is_map(settings) do
    with {:ok, branch} <- implementation_branch(issue.identifier),
         :ok <- validate_settings(settings),
         :ok <- require_expected_origin(workspace, settings.repository, opts),
         :ok <- require_clean_workspace(workspace, opts),
         {:ok, head_sha} <- read_head_sha(workspace, opts) do
      prepare_unless_already_merged(
        nil,
        issue,
        workspace,
        branch,
        settings,
        head_sha,
        opts
      )
    end
  end

  defp prepare_unless_already_merged(_before_push_pr, issue, workspace, branch, settings, head_sha, opts) do
    with :ok <- require_expected_origin(workspace, settings.repository, opts),
         :ok <- push_branch(workspace, branch, head_sha, opts),
         :ok <- require_expected_origin(workspace, settings.repository, opts),
         {:ok, existing_pr} <-
           find_pull_request(
             workspace,
             branch,
             settings.base_branch,
             head_sha,
             settings.repository,
             opts
           ) do
      reuse_or_create_pull_request(
        existing_pr,
        issue,
        workspace,
        branch,
        settings.base_branch,
        head_sha,
        settings.repository,
        opts
      )
    end
  end

  @spec merge_after_required_check(pull_request(), Path.t(), map(), keyword()) ::
          {:ok, pull_request()} | {:error, term()}
  def merge_after_required_check(pr, workspace, settings, opts \\ [])
      when is_map(pr) and is_binary(workspace) and is_map(settings) do
    with :ok <- validate_settings(settings),
         :ok <- require_expected_origin(workspace, settings.repository, opts),
         :ok <- validate_pull_request_url(pr.url, settings.repository),
         :ok <- wait_for_required_check(pr, workspace, settings, opts),
         {:ok, current_pr} <-
           view_pull_request(workspace, Integer.to_string(pr.number), settings.repository, opts),
         :ok <- validate_pull_request_identity(current_pr, pr, settings),
         :ok <- run_pre_merge_guard(opts),
         {:ok, terminal_pr} <-
           view_pull_request(workspace, Integer.to_string(pr.number), settings.repository, opts),
         :ok <- validate_pull_request_identity(terminal_pr, current_pr, settings) do
      merge_unless_already_merged(terminal_pr, workspace, settings, opts)
    end
  end

  @spec publish_quality_gate(pull_request(), Path.t(), map()) :: :ok | {:error, term()}
  def publish_quality_gate(pr, workspace, settings),
    do: publish_quality_gate(pr, workspace, settings, [])

  @spec publish_quality_gate(pull_request(), Path.t(), map(), keyword()) :: :ok | {:error, term()}

  def publish_quality_gate(%{state: :open} = pr, workspace, settings, opts) do
    endpoint = "repos/#{settings.repository}/statuses/#{pr.head_sha}"

    args = [
      "api",
      "--method",
      "POST",
      endpoint,
      "-f",
      "state=success",
      "-f",
      "context=#{@required_check}",
      "-f",
      "description=Trusted Symphony review, QA, and proof passed"
    ]

    with :ok <- validate_settings(settings),
         :ok <- validate_pull_request_url(pr.url, settings.repository),
         true <- Regex.match?(@sha, pr.head_sha),
         :ok <- require_expected_origin(workspace, settings.repository, opts),
         {:ok, _output} <- run_command("gh", args, workspace, opts),
         {:ok, readback_pr} <-
           view_pull_request(workspace, Integer.to_string(pr.number), settings.repository, opts),
         :ok <- validate_pull_request_identity(readback_pr, pr, settings) do
      :ok
    else
      false -> {:error, :invalid_pull_request_head}
      {:error, reason} -> {:error, {:quality_gate_publish_failed, reason}}
    end
  end

  def publish_quality_gate(%{state: :merged}, _workspace, _settings, _opts), do: :ok
  def publish_quality_gate(_pr, _workspace, _settings, _opts), do: {:error, :pull_request_not_open}

  defp merge_unless_already_merged(%{state: :merged} = pr, _workspace, _settings, _opts),
    do: {:ok, pr}

  defp merge_unless_already_merged(pr, workspace, settings, opts) do
    with :ok <- require_expected_origin(workspace, settings.repository, opts) do
      merge_pull_request(pr, workspace, settings, opts)
    end
  end

  defp run_pre_merge_guard(opts) do
    case Keyword.get(opts, :pre_merge_guard, fn -> :ok end).() do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_pre_merge_guard_result, other}}
    end
  end

  defp validate_pull_request_identity(current, expected, settings) do
    validations = [
      {current.number == expected.number, :pull_request_number_mismatch},
      {current.url == expected.url, :pull_request_url_changed},
      {current.head_ref == expected.head_ref, :pull_request_head_ref_changed},
      {current.head_sha == expected.head_sha, :pull_request_head_mismatch},
      {base_branches_match?(current, expected, settings), :pull_request_base_mismatch},
      {current.base_sha == expected.base_sha, :pull_request_base_changed},
      {current.state != :closed, :pull_request_closed_without_merge}
    ]

    case Enum.find(validations, fn {valid?, _reason} -> !valid? end) do
      nil -> :ok
      {_valid?, reason} -> {:error, reason}
    end
  end

  defp base_branches_match?(current, expected, settings) do
    current.base_ref == settings.base_branch and expected.base_ref == settings.base_branch
  end

  @spec implementation_branch(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def implementation_branch(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)
    branch = "factory/" <> String.downcase(identifier)

    if Regex.match?(@safe_issue_identifier, identifier) and valid_git_ref?(branch) do
      {:ok, branch}
    else
      {:error, :invalid_factory_branch}
    end
  end

  def implementation_branch(_identifier), do: {:error, :invalid_factory_branch}

  @spec validate_pull_request_url(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_pull_request_url(url, repository)
      when is_binary(url) and is_binary(repository) do
    expected_path_prefix = "/" <> String.downcase(repository) <> "/pull/"

    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: port,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and is_binary(path) and port in [nil, 443] ->
        normalized_path = String.downcase(path)

        with true <- String.downcase(host) == "github.com",
             true <- String.starts_with?(normalized_path, expected_path_prefix),
             number <- String.replace_prefix(normalized_path, expected_path_prefix, ""),
             {parsed, ""} when parsed > 0 <- Integer.parse(number) do
          :ok
        else
          _reason -> {:error, :pull_request_repository_mismatch}
        end

      _uri ->
        {:error, :pull_request_repository_mismatch}
    end
  end

  def validate_pull_request_url(_url, _repository), do: {:error, :pull_request_repository_mismatch}

  @spec validate_actions_run_url(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_actions_run_url(url, repository)
      when is_binary(url) and is_binary(repository) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: "github.com",
        userinfo: nil,
        port: port,
        query: nil,
        fragment: nil,
        path: path
      }
      when port in [nil, 443] ->
        if Regex.match?(~r|\A/#{Regex.escape(repository)}/actions/runs/[1-9][0-9]*\z|, path || ""),
          do: :ok,
          else: {:error, :invalid_actions_run_url}

      _url ->
        {:error, :invalid_actions_run_url}
    end
  end

  def validate_actions_run_url(_url, _repository), do: {:error, :invalid_actions_run_url}

  defp validate_settings(%{
         repository: repository,
         base_branch: base_branch,
         required_check: required_check
       }) do
    with :ok <- validate_repository(repository),
         :ok <- validate_base_branch(base_branch),
         true <- required_check == @required_check do
      :ok
    else
      false -> {:error, {:unsupported_required_check, required_check}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_settings(_settings), do: {:error, :invalid_github_settings}

  defp validate_repository(repository) when is_binary(repository) do
    if Regex.match?(@repository, repository), do: :ok, else: {:error, :invalid_github_repository}
  end

  defp validate_repository(_repository), do: {:error, :invalid_github_repository}

  defp validate_base_branch(base_branch) when is_binary(base_branch) do
    normalized = base_branch |> String.trim() |> String.downcase()

    cond do
      !valid_git_ref?(base_branch) -> {:error, :unsafe_base_branch}
      normalized in ["production", "release"] -> {:error, :unsafe_base_branch}
      String.starts_with?(normalized, "production/") -> {:error, :unsafe_base_branch}
      String.starts_with?(normalized, "release/") -> {:error, :unsafe_base_branch}
      true -> :ok
    end
  end

  defp validate_base_branch(_base_branch), do: {:error, :unsafe_base_branch}

  defp valid_git_ref?(ref) do
    Regex.match?(@safe_ref, ref) and !String.contains?(ref, ["..", "//", "@{"]) and
      !String.ends_with?(ref, ["/", ".", ".lock"])
  end

  defp require_expected_origin(workspace, repository, opts) do
    with {:ok, remote_url} <- run_command("git", ["remote", "get-url", "origin"], workspace, opts),
         {:ok, actual} <- repository_from_remote(remote_url) do
      if String.downcase(actual) == String.downcase(repository),
        do: :ok,
        else: {:error, :origin_repository_mismatch}
    else
      {:error, :invalid_origin_repository} -> {:error, :origin_repository_mismatch}
      {:error, reason} -> {:error, {:git_origin_failed, reason}}
    end
  end

  defp repository_from_remote(remote_url) do
    trimmed = String.trim(remote_url)

    if Regex.match?(~r/\Agit@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/i, trimmed) do
      repo =
        trimmed
        |> String.replace_prefix("git@github.com:", "")
        |> String.replace_suffix(".git", "")

      {:ok, repo}
    else
      repository_from_uri(URI.parse(trimmed))
    end
  end

  defp repository_from_uri(%URI{scheme: scheme, host: host, path: path})
       when scheme in ["https", "ssh"] and is_binary(host) and is_binary(path) do
    repo = path |> String.trim_leading("/") |> String.replace_suffix(".git", "")

    if String.downcase(host) == "github.com" and Regex.match?(@repository, repo) do
      {:ok, repo}
    else
      {:error, :invalid_origin_repository}
    end
  end

  defp repository_from_uri(_uri), do: {:error, :invalid_origin_repository}

  defp require_clean_workspace(workspace, opts) do
    args = [
      "status",
      "--porcelain=v1",
      "--untracked-files=all",
      "--",
      "."
    ]

    case run_command("git", args, workspace, opts) do
      {:ok, ""} -> :ok
      {:ok, _output} -> {:error, :workspace_has_uncommitted_changes}
      {:error, reason} -> {:error, {:git_status_failed, reason}}
    end
  end

  defp read_head_sha(workspace, opts) do
    with {:ok, output} <- run_command("git", ["rev-parse", "HEAD"], workspace, opts),
         head_sha <- String.trim(output),
         true <- Regex.match?(@sha, head_sha) do
      {:ok, String.downcase(head_sha)}
    else
      false -> {:error, :invalid_git_head}
      {:error, reason} -> {:error, {:git_head_failed, reason}}
    end
  end

  defp push_branch(workspace, branch, head_sha, opts) do
    refspec = "#{head_sha}:refs/heads/#{branch}"

    case run_command("git", ["push", "--set-upstream", "origin", refspec], workspace, opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:git_push_failed, reason}}
    end
  end

  defp find_pull_request(workspace, branch, base_branch, head_sha, repository, opts) do
    args = [
      "pr",
      "list",
      "--head",
      branch,
      "--state",
      "all",
      "--json",
      @pr_json_fields,
      "--limit",
      "20",
      "--repo",
      repository
    ]

    with {:ok, output} <- run_command("gh", args, workspace, opts),
         {:ok, rows} <- decode_json_list(output),
         {:ok, pull_requests} <- parse_pull_requests(rows, repository) do
      choose_pull_request(pull_requests, branch, base_branch, head_sha)
    else
      {:error, reason} -> {:error, {:pull_request_lookup_failed, reason}}
    end
  end

  defp choose_pull_request(pull_requests, branch, base_branch, head_sha) do
    candidates = Enum.filter(pull_requests, &(&1.head_ref == branch))
    open_pull_requests = Enum.filter(candidates, &(&1.state == :open))

    case open_pull_requests do
      [pr] -> validate_reusable_pull_request(pr, base_branch, head_sha)
      [] -> choose_closed_pull_request(candidates, base_branch, head_sha)
      _many -> {:error, :ambiguous_open_pull_requests}
    end
  end

  defp choose_closed_pull_request(candidates, base_branch, head_sha) do
    matching = Enum.filter(candidates, &(&1.base_ref == base_branch and &1.head_sha == head_sha))

    case matching do
      [] -> {:ok, nil}
      [%{state: :merged} = pr] -> {:ok, pr}
      [_closed_pr] -> {:error, :pull_request_closed_without_merge}
      _many -> {:error, :ambiguous_pull_requests}
    end
  end

  defp validate_reusable_pull_request(pr, base_branch, head_sha) do
    cond do
      pr.base_ref != base_branch -> {:error, :pull_request_base_mismatch}
      pr.head_sha != head_sha -> {:error, :pull_request_head_mismatch}
      true -> {:ok, pr}
    end
  end

  defp reuse_or_create_pull_request(
         nil,
         issue,
         workspace,
         branch,
         base_branch,
         head_sha,
         repository,
         opts
       ) do
    title = pull_request_title(issue)
    body = pull_request_body(issue)

    args = [
      "pr",
      "create",
      "--head",
      branch,
      "--base",
      base_branch,
      "--title",
      title,
      "--body",
      body,
      "--repo",
      repository
    ]

    with {:ok, output} <- run_command("gh", args, workspace, opts),
         {:ok, url} <- pull_request_url(output, repository),
         {:ok, pr} <- view_pull_request(workspace, url, repository, opts),
         :ok <- validate_created_pull_request(pr, branch, base_branch, head_sha) do
      {:ok, pr}
    else
      {:error, reason} -> {:error, {:pull_request_create_failed, reason}}
    end
  end

  defp reuse_or_create_pull_request(
         pr,
         _issue,
         _workspace,
         _branch,
         _base_branch,
         _head_sha,
         _repository,
         _opts
       ),
       do: {:ok, pr}

  defp validate_created_pull_request(pr, branch, base_branch, head_sha) do
    cond do
      pr.state != :open -> {:error, :created_pull_request_not_open}
      pr.head_ref != branch -> {:error, :pull_request_head_mismatch}
      pr.base_ref != base_branch -> {:error, :pull_request_base_mismatch}
      pr.head_sha != head_sha -> {:error, :pull_request_head_mismatch}
      true -> :ok
    end
  end

  defp wait_for_required_check(pr, workspace, settings, opts) do
    now = Keyword.get(opts, :monotonic_time_fun, &default_monotonic_time/0)
    deadline = now.() + settings.check_timeout_ms
    poll_required_check(pr, workspace, settings, opts, deadline, now)
  end

  defp poll_required_check(pr, workspace, settings, opts, deadline, now) do
    if now.() >= deadline do
      {:error, {:required_check_timed_out, settings.required_check}}
    else
      poll_required_check_before_deadline(pr, workspace, settings, opts, deadline, now)
    end
  end

  defp poll_required_check_before_deadline(pr, workspace, settings, opts, deadline, now) do
    case required_check_status(pr, workspace, settings.required_check, settings.repository, opts) do
      :passed ->
        :ok

      :pending ->
        sleep = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
        sleep.(settings.check_poll_interval_ms)
        poll_required_check(pr, workspace, settings, opts, deadline, now)

      {:failed, states} ->
        {:error, {:required_check_failed, settings.required_check, states}}

      :missing ->
        {:error, {:required_check_missing, settings.required_check}}

      {:error, reason} ->
        {:error, {:required_check_lookup_failed, reason}}
    end
  end

  defp required_check_status(pr, workspace, required_check, repository, opts) do
    args = [
      "pr",
      "checks",
      Integer.to_string(pr.number),
      "--json",
      "name,state,link",
      "--repo",
      repository
    ]

    with {:ok, {output, status}} <- execute_command("gh", args, workspace, opts),
         {:ok, checks} <- decode_check_output(output, status) do
      classify_required_check(checks, required_check)
    end
  end

  defp decode_check_output(output, status) do
    case decode_json_list(output) do
      {:ok, checks} -> {:ok, checks}
      {:error, _reason} when status != 0 -> {:error, {:exit_status, status, command_excerpt(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_required_check(checks, required_check) do
    states =
      checks
      |> Enum.filter(&(&1["name"] == required_check))
      |> Enum.map(&(&1["state"] |> to_string() |> String.upcase()))

    cond do
      states == [] -> :missing
      Enum.all?(states, &(&1 == "SUCCESS")) -> :passed
      Enum.any?(states, &(&1 not in @pending_check_states and &1 != "SUCCESS")) -> {:failed, states}
      true -> :pending
    end
  end

  defp merge_pull_request(%{state: :open} = pr, workspace, settings, opts) do
    args = [
      "pr",
      "merge",
      Integer.to_string(pr.number),
      "--squash",
      "--match-head-commit",
      pr.head_sha,
      "--repo",
      settings.repository
    ]

    with {:ok, _output} <- run_command("gh", args, workspace, opts),
         {:ok, merged_pr} <-
           view_pull_request(workspace, Integer.to_string(pr.number), settings.repository, opts),
         :ok <- validate_merged_pull_request(merged_pr, pr, settings.base_branch) do
      {:ok, merged_pr}
    else
      {:error, reason} -> {:error, {:pull_request_merge_failed, reason}}
    end
  end

  defp merge_pull_request(_pr, _workspace, _settings, _opts),
    do: {:error, :pull_request_not_open}

  defp validate_merged_pull_request(merged_pr, original_pr, base_branch) do
    cond do
      merged_pr.state != :merged -> {:error, :pull_request_not_merged}
      merged_pr.number != original_pr.number -> {:error, :pull_request_number_mismatch}
      merged_pr.head_sha != original_pr.head_sha -> {:error, :pull_request_head_mismatch}
      merged_pr.base_ref != base_branch -> {:error, :pull_request_base_mismatch}
      merged_pr.base_sha != original_pr.base_sha -> {:error, :pull_request_base_changed}
      true -> :ok
    end
  end

  defp view_pull_request(workspace, reference, repository, opts) do
    args = ["pr", "view", reference, "--json", @pr_json_fields, "--repo", repository]

    with {:ok, output} <- run_command("gh", args, workspace, opts),
         {:ok, row} <- decode_json_map(output) do
      parse_pull_request(row, repository)
    end
  end

  defp parse_pull_requests(rows, repository) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case parse_pull_request(row, repository) do
        {:ok, pr} -> {:cont, {:ok, [pr | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_pull_request(
         %{
           "number" => number,
           "url" => url,
           "state" => state,
           "headRefName" => head_ref,
           "baseRefName" => base_ref,
           "headRefOid" => head_sha,
           "baseRefOid" => base_sha
         },
         repository
       )
       when is_integer(number) and number > 0 and is_binary(url) and is_binary(state) and
              is_binary(head_ref) and is_binary(base_ref) and is_binary(head_sha) and is_binary(base_sha) do
    with :ok <- validate_pull_request_url(url, repository),
         {:ok, parsed_state} <- parse_pull_request_state(state),
         true <- Regex.match?(@sha, head_sha),
         true <- Regex.match?(@sha, base_sha) do
      {:ok,
       %{
         number: number,
         url: url,
         state: parsed_state,
         head_ref: head_ref,
         base_ref: base_ref,
         head_sha: String.downcase(head_sha),
         base_sha: String.downcase(base_sha)
       }}
    else
      false -> {:error, :invalid_pull_request_head}
      {:error, _reason} = error -> error
    end
  end

  defp parse_pull_request(_row, _repository), do: {:error, :invalid_pull_request}

  defp parse_pull_request_state(state) do
    case String.upcase(state) do
      "OPEN" -> {:ok, :open}
      "MERGED" -> {:ok, :merged}
      "CLOSED" -> {:ok, :closed}
      _state -> {:error, :invalid_pull_request_state}
    end
  end

  defp pull_request_title(%Issue{identifier: identifier, title: title}) do
    clean_title = title |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    if clean_title == "", do: identifier, else: "#{identifier}: #{clean_title}"
  end

  defp pull_request_body(%Issue{} = issue) do
    base =
      "Automated factory change for #{issue.identifier}. Planning, Build, Review, and QA completed before this pull request was finalized."

    case issue.url do
      url when is_binary(url) ->
        if match?(:ok, require_https_url(url)), do: base <> "\n\nLinear issue: #{url}", else: base

      _url ->
        base
    end
  end

  defp pull_request_url(output, repository) do
    case Regex.run(~r{https://[^\s]+/pull/[0-9]+}, output) do
      [url] ->
        if validate_pull_request_url(url, repository) == :ok,
          do: {:ok, url},
          else: {:error, :pull_request_repository_mismatch}

      _match ->
        {:error, :pull_request_url_missing}
    end
  end

  defp require_https_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _uri -> {:error, :pull_request_url_must_be_https}
    end
  end

  defp decode_json_list(output) do
    case Jason.decode(output) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      {:ok, _value} -> {:error, :expected_json_list}
      {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
    end
  end

  defp decode_json_map(output) do
    case Jason.decode(output) do
      {:ok, row} when is_map(row) -> {:ok, row}
      {:ok, _value} -> {:error, :expected_json_object}
      {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
    end
  end

  defp run_command(command, args, workspace, opts) do
    case execute_command(command, args, workspace, opts) do
      {:ok, {output, 0}} -> {:ok, String.trim_trailing(output)}
      {:ok, {output, status}} -> {:error, {:exit_status, status, command_excerpt(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_command(command, args, workspace, opts) do
    result =
      case Keyword.get(opts, :github_executor) do
        executor when is_function(executor, 3) ->
          executor.(command, args, cd: workspace, stderr_to_stdout: true)

        nil ->
          default_execute(
            command,
            args,
            workspace,
            Keyword.get(opts, :github_command_timeout_ms, @default_command_timeout_ms),
            Keyword.get(opts, :github_max_output_bytes, @max_command_output_bytes)
          )
      end

    case result do
      {output, status} when is_binary(output) and is_integer(status) -> {:ok, {output, status}}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_executor_response, other}}
    end
  rescue
    error -> {:error, {:command_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:command_exception, kind, reason}}
  end

  defp default_execute(command, args, workspace, timeout_ms, max_output_bytes)
       when command in ["git", "gh"] and is_list(args) and is_binary(workspace) and
              is_integer(timeout_ms) and timeout_ms > 0 and is_integer(max_output_bytes) and
              max_output_bytes > 0 do
    case System.find_executable(command) do
      executable when is_binary(executable) ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:cd, String.to_charlist(workspace)},
              {:args, Enum.map(args, &String.to_charlist/1)},
              {:env, command_environment()}
            ]
          )

        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect_command(port, "", deadline, timeout_ms, max_output_bytes)

      nil ->
        {:error, {:command_not_found, command}}
    end
  rescue
    error -> {:error, {:command_start_failed, Exception.message(error)}}
  end

  defp default_execute(command, _args, _workspace, _timeout_ms, _max_output_bytes),
    do: {:error, {:command_not_allowed, command}}

  defp collect_command(port, output, deadline, timeout_ms, max_output_bytes) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms == 0 do
      close_command_port(port, {:command_timeout, timeout_ms})
    else
      receive do
        {^port, {:data, bytes}} ->
          next = output <> bytes

          if byte_size(next) <= max_output_bytes do
            collect_command(port, next, deadline, timeout_ms, max_output_bytes)
          else
            close_command_port(port, :command_output_too_large)
          end

        {^port, {:exit_status, status}} ->
          {output, status}
      after
        remaining_ms -> close_command_port(port, {:command_timeout, timeout_ms})
      end
    end
  end

  defp close_command_port(port, reason) do
    :ok = BoundedPort.terminate(port)
    {:error, reason}
  end

  defp command_environment do
    cleared = System.get_env() |> Map.keys() |> Enum.map(&{String.to_charlist(&1), false})

    inherited =
      [
        "PATH",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "HOME",
        "XDG_CONFIG_HOME",
        "GH_CONFIG_DIR",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "GITHUB_ENTERPRISE_TOKEN",
        "SSH_AUTH_SOCK"
      ]
      |> Enum.flat_map(fn name ->
        case System.get_env(name) do
          value when is_binary(value) -> [{String.to_charlist(name), String.to_charlist(value)}]
          _missing -> []
        end
      end)

    cleared ++
      inherited ++
      [
        {~c"GIT_TERMINAL_PROMPT", ~c"0"},
        {~c"GH_PROMPT_DISABLED", ~c"1"}
      ]
  end

  defp default_monotonic_time, do: System.monotonic_time(:millisecond)

  defp command_excerpt(output) do
    output
    |> String.trim()
    |> String.slice(0, 2_000)
  end
end
