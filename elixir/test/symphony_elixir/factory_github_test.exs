defmodule SymphonyElixir.FactoryGitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{GitHub, Runner}

  @head_sha String.duplicate("a", 40)
  @base_sha String.duplicate("b", 40)
  @pr_url "https://github.com/example/mobile/pull/42"
  @factory_run_id "10000000-0000-4000-8000-000000000001"

  setup do
    state_root =
      Path.join(
        Config.local_workspace_root(),
        "factory-github-state-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      factory_enabled: true,
      factory_state_root: state_root,
      linear_agent_enabled: true,
      linear_agent_access_token: "oauth-token",
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    :ok
  end

  test "pushes deterministic branch, creates a PR, checks the exact gate, and squash-merges" do
    workspace = "/tmp/symphony-github-app-1"
    issue = issue()

    executor =
      executor([
        {"git@github.com:example/mobile.git\n", 0},
        {"", 0},
        {@head_sha <> "\n", 0},
        {"git@github.com:example/mobile.git\n", 0},
        {"pushed\n", 0},
        {"git@github.com:example/mobile.git\n", 0},
        {"[]", 0},
        {@pr_url <> "\n", 0},
        {pr_json("OPEN"), 0},
        {"git@github.com:example/mobile.git\n", 0},
        {Jason.encode!([%{"name" => "factory/quality-gate", "state" => "SUCCESS", "link" => ""}]), 0},
        {pr_json("OPEN"), 0},
        {pr_json("OPEN"), 0},
        {"git@github.com:example/mobile.git\n", 0},
        {"merged\n", 0},
        {pr_json("MERGED"), 0}
      ])

    settings = github_settings()

    assert {:ok, pr} = GitHub.prepare(issue, workspace, settings, github_executor: executor)
    assert pr.state == :open

    assert {:ok, merged_pr} =
             GitHub.merge_after_required_check(pr, workspace, settings, github_executor: executor)

    assert merged_pr.state == :merged

    body =
      "Automated factory change for APP-1. Planning, Build, Review, and QA completed before this pull request was finalized.\n\nLinear issue: https://linear.app/example/issue/APP-1"

    assert command_calls() == [
             {"git", ["remote", "get-url", "origin"], workspace},
             {"git",
              [
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                "."
              ], workspace},
             {"git", ["rev-parse", "HEAD"], workspace},
             {"git", ["remote", "get-url", "origin"], workspace},
             {"git", ["push", "--set-upstream", "origin", "#{@head_sha}:refs/heads/factory/app-1"], workspace},
             {"git", ["remote", "get-url", "origin"], workspace},
             {"gh",
              [
                "pr",
                "list",
                "--head",
                "factory/app-1",
                "--state",
                "all",
                "--json",
                "number,url,state,headRefName,baseRefName,headRefOid,baseRefOid",
                "--limit",
                "20",
                "--repo",
                "example/mobile"
              ], workspace},
             {"gh",
              [
                "pr",
                "create",
                "--head",
                "factory/app-1",
                "--base",
                "main",
                "--title",
                "APP-1: Player queue",
                "--body",
                body,
                "--repo",
                "example/mobile"
              ], workspace},
             {"gh",
              [
                "pr",
                "view",
                @pr_url,
                "--json",
                "number,url,state,headRefName,baseRefName,headRefOid,baseRefOid",
                "--repo",
                "example/mobile"
              ], workspace},
             {"git", ["remote", "get-url", "origin"], workspace},
             {"gh",
              [
                "pr",
                "checks",
                "42",
                "--json",
                "name,state,link",
                "--repo",
                "example/mobile"
              ], workspace},
             {"gh", ["pr", "view", "42", "--json", "number,url,state,headRefName,baseRefName,headRefOid,baseRefOid", "--repo", "example/mobile"], workspace},
             {"gh", ["pr", "view", "42", "--json", "number,url,state,headRefName,baseRefName,headRefOid,baseRefOid", "--repo", "example/mobile"], workspace},
             {"git", ["remote", "get-url", "origin"], workspace},
             {"gh",
              [
                "pr",
                "merge",
                "42",
                "--squash",
                "--match-head-commit",
                @head_sha,
                "--repo",
                "example/mobile"
              ], workspace},
             {"gh",
              [
                "pr",
                "view",
                "42",
                "--json",
                "number,url,state,headRefName,baseRefName,headRefOid,baseRefOid",
                "--repo",
                "example/mobile"
              ], workspace}
           ]
  end

  test "reuses the open PR for the same branch, base, and head" do
    workspace = "/tmp/symphony-github-reuse"

    executor =
      executor([
        {"https://github.com/example/mobile.git", 0},
        {"", 0},
        {@head_sha, 0},
        {"https://github.com/example/mobile.git", 0},
        {"pushed", 0},
        {"https://github.com/example/mobile.git", 0},
        {Jason.encode!([pr_map("OPEN")]), 0}
      ])

    assert {:ok, %{number: 42, state: :open}} =
             GitHub.prepare(issue(), workspace, github_settings(), github_executor: executor)

    assert Enum.map(command_calls(), fn {command, args, _workspace} -> {command, Enum.take(args, 2)} end) == [
             {"git", ["remote", "get-url"]},
             {"git", ["status", "--porcelain=v1"]},
             {"git", ["rev-parse", "HEAD"]},
             {"git", ["remote", "get-url"]},
             {"git", ["push", "--set-upstream"]},
             {"git", ["remote", "get-url"]},
             {"gh", ["pr", "list"]}
           ]
  end

  test "fails closed when the required gate fails or is missing" do
    pr = parsed_pr()
    workspace = "/tmp/symphony-github-gate"
    settings = github_settings()

    failed_executor =
      executor([
        {"git@github.com:example/mobile.git", 0},
        {Jason.encode!([%{"name" => "factory/quality-gate", "state" => "FAILURE", "link" => ""}]), 1}
      ])

    assert {:error, {:required_check_failed, "factory/quality-gate", ["FAILURE"]}} =
             GitHub.merge_after_required_check(pr, workspace, settings, github_executor: failed_executor)

    flush_command_calls()

    missing_executor =
      executor([
        {"git@github.com:example/mobile.git", 0},
        {Jason.encode!([%{"name" => "another-check", "state" => "SUCCESS", "link" => ""}]), 0}
      ])

    assert {:error, {:required_check_missing, "factory/quality-gate"}} =
             GitHub.merge_after_required_check(pr, workspace, settings, github_executor: missing_executor)

    refute Enum.any?(command_calls(), fn {_command, args, _workspace} -> "merge" in args end)
  end

  test "times out pending required checks without merging" do
    pending =
      Jason.encode!([%{"name" => "factory/quality-gate", "state" => "IN_PROGRESS", "link" => ""}])

    executor = executor([{"git@github.com:example/mobile.git", 0}, {pending, 8}, {pending, 8}])
    clock = start_supervised!({Agent, fn -> [0, 0, 10] end}, id: make_ref())

    monotonic_time_fun = fn ->
      Agent.get_and_update(clock, fn [value | rest] -> {value, rest} end)
    end

    settings = %{github_settings() | check_timeout_ms: 5, check_poll_interval_ms: 1}

    assert {:error, {:required_check_timed_out, "factory/quality-gate"}} =
             GitHub.merge_after_required_check(parsed_pr(), "/tmp/symphony-github-timeout", settings,
               github_executor: executor,
               monotonic_time_fun: monotonic_time_fun,
               sleep_fun: fn 1 -> :ok end
             )

    refute Enum.any?(command_calls(), fn {_command, args, _workspace} -> "merge" in args end)
  end

  test "default git and gh runner enforces command, output, and wall-clock bounds" do
    workspace = Config.local_workspace_root()

    assert {:error, :command_output_too_large} =
             GitHub.run_default_command_for_test("git", ["--version"], workspace, 2_000, 4)

    assert {:error, {:command_timeout, 50}} =
             GitHub.run_default_command_for_test(
               "git",
               ["-c", "alias.pause=!sleep 1", "pause"],
               workspace,
               50,
               1_024
             )

    assert {:error, {:command_not_allowed, "sh"}} =
             GitHub.run_default_command_for_test("sh", ["-c", "true"], workspace, 100, 100)
  end

  test "reports a merge command failure after a passed gate" do
    checks = Jason.encode!([%{"name" => "factory/quality-gate", "state" => "SUCCESS", "link" => ""}])

    executor =
      executor([
        {"git@github.com:example/mobile.git", 0},
        {checks, 0},
        {pr_json("OPEN"), 0},
        {pr_json("OPEN"), 0},
        {"git@github.com:example/mobile.git", 0},
        {"merge rejected", 1}
      ])

    assert {:error, {:pull_request_merge_failed, {:exit_status, 1, "merge rejected"}}} =
             GitHub.merge_after_required_check(
               parsed_pr(),
               "/tmp/symphony-github-merge-failure",
               github_settings(),
               github_executor: executor
             )

    assert Enum.any?(command_calls(), fn {_command, args, _workspace} ->
             args == [
               "pr",
               "merge",
               "42",
               "--squash",
               "--match-head-commit",
               @head_sha,
               "--repo",
               "example/mobile"
             ]
           end)
  end

  test "a replayed merged PR still requires the gate but is not merged twice" do
    checks = Jason.encode!([%{"name" => "factory/quality-gate", "state" => "SUCCESS", "link" => ""}])

    executor =
      executor([
        {"git@github.com:example/mobile.git", 0},
        {checks, 0},
        {pr_json("MERGED"), 0},
        {pr_json("MERGED"), 0}
      ])

    merged_pr = %{parsed_pr() | state: :merged}

    assert {:ok, ^merged_pr} =
             GitHub.merge_after_required_check(
               merged_pr,
               "/tmp/symphony-github-already-merged",
               github_settings(),
               github_executor: executor
             )

    refute Enum.any?(command_calls(), fn {_command, args, _workspace} -> "merge" in args end)
  end

  test "rejects production and release bases before running commands" do
    executor = executor([])

    for base_branch <- ["production", "production/hotfix", "release", "release/1.0"] do
      settings = %{github_settings() | base_branch: base_branch}

      assert {:error, :unsafe_base_branch} =
               GitHub.prepare(issue(), "/tmp/symphony-github-unsafe", settings, github_executor: executor)
    end

    assert command_calls() == []
  end

  test "refuses to push when product or proof files remain uncommitted" do
    executor =
      executor([
        {"git@github.com:example/mobile.git\n", 0},
        {"?? qa/proof-manifest.json\n", 0}
      ])

    assert {:error, :workspace_has_uncommitted_changes} =
             GitHub.prepare(issue(), "/tmp/symphony-github-dirty", github_settings(), github_executor: executor)

    assert [
             {"git", ["remote", "get-url", "origin"], "/tmp/symphony-github-dirty"},
             {"git", ["status" | _arguments], "/tmp/symphony-github-dirty"}
           ] = command_calls()
  end

  test "rejects a mismatched origin before push and a foreign pull request before checks" do
    wrong_origin = executor([{"git@github.com:other/mobile.git", 0}])

    assert {:error, :origin_repository_mismatch} =
             GitHub.prepare(issue(), "/tmp/symphony-github-wrong-origin", github_settings(), github_executor: wrong_origin)

    assert [{"git", ["remote", "get-url", "origin"], _workspace}] = command_calls()

    foreign_pr = %{parsed_pr() | url: "https://github.com/other/mobile/pull/42"}
    executor = executor([{"git@github.com:example/mobile.git", 0}])

    assert {:error, :pull_request_repository_mismatch} =
             GitHub.merge_after_required_check(
               foreign_pr,
               "/tmp/symphony-github-foreign-pr",
               github_settings(),
               github_executor: executor
             )

    refute Enum.any?(command_calls(), fn {_command, args, _workspace} -> "checks" in args end)
  end

  test "runner emits open and merged protocol events through the QA session" do
    workspace =
      Path.join(Config.local_workspace_root(), "factory-github-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-factory-events")

    File.write!(
      executable,
      """
      #!/bin/sh
      if test "$1" = post-merge; then
        printf '{"required":true,"status":"passed","commitSha":"#{@head_sha}","runUrl":"https://github.com/example/mobile/actions/runs/12345"}\n'
        exit 0
      fi
      phase="$SYMPHONY_FACTORY_PHASE"
      case "$phase" in planning) n=1;; build) n=2;; review) n=3;; qa) n=4;; esac
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-%012d","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-1","type":"phase.started","phase":"%s","payload":{"attempt":1,"packet":"packet","branch":"factory/app-1","workspace":"sandcastle://factory/app-1"}}\n' "$((n + 200))" "$phase"
      if test "$phase" = planning; then
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000104","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:30Z","project":"project","issue":"APP-1","type":"plan.updated","phase":"planning","payload":{"summary":"Runtime change","acceptanceCriteria":["Flow works"],"workScope":"runtime-static","postMergeInternalBuild":true,"proofTargets":[{"platform":"ios","flow":"factory-proof","requiredMedia":["image"]}]}}\n'
      fi
      if test "$phase" = review; then
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000101","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:01:00Z","project":"project","issue":"APP-1","type":"check.completed","phase":"review","payload":{"name":"review","status":"passed","required":true,"acceptance":true,"commitSha":"#{@head_sha}"}}\n'
      fi
      if test "$phase" = qa; then
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000102","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:01:00Z","project":"project","issue":"APP-1","type":"artifact.created","phase":"qa","payload":{"artifact":{"id":"20000000-0000-4000-8000-000000000001","kind":"image","storage":"remote_url","uri":"https://uploads.linear.app/proof.png","mimeType":"image/png","byteSize":1,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","capturedAt":"2026-08-31T20:01:00Z","commitSha":"#{@head_sha}","runId":"10000000-0000-4000-8000-000000000001","attempt":1,"bundleOrPackageId":"com.example.factory.test","deviceIdentity":"ios-simulator:test-device","issue":"APP-1","flow":"factory-proof","platform":"ios","relation":"after","description":"QA proof","width":1,"height":1}}}\n'
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000103","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:01:00Z","project":"project","issue":"APP-1","type":"check.completed","phase":"qa","payload":{"name":"qa","status":"passed","required":true,"acceptance":true,"commitSha":"#{@head_sha}"}}\n'
      fi
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-%012d","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:01:00Z","project":"project","issue":"APP-1","type":"phase.completed","phase":"%s","payload":{"summary":"phase complete","branch":"factory/app-1","commitShas":["#{@head_sha}"]}}\n' "$n" "$phase"
      """
    )

    File.chmod!(executable, 0o755)
    test_pid = self()

    bridge = fn
      :ensure_phase_session, [_issue, phase] ->
        {:ok, "session-#{phase}"}

      :register_phase_session, [_issue_id, _phase, _session_id] ->
        :ok

      :report_factory_event, [_issue, session_id, event] ->
        send(test_pid, {:factory_event, session_id, event})
        :ok

      :restore_factory_lifecycle, [_issue, _facts] ->
        :ok

      :complete_factory_lifecycle, [_issue] ->
        :ok
    end

    executor =
      executor([
        {"git@github.com:example/mobile.git", 0},
        {"", 0},
        {@head_sha, 0},
        {"git@github.com:example/mobile.git", 0},
        {"pushed", 0},
        {"git@github.com:example/mobile.git", 0},
        {Jason.encode!([pr_map("OPEN")]), 0},
        {"git@github.com:example/mobile.git", 0},
        {"quality published", 0},
        {pr_json("OPEN"), 0},
        {"git@github.com:example/mobile.git", 0},
        {Jason.encode!([%{"name" => "factory/quality-gate", "state" => "SUCCESS", "link" => ""}]), 0},
        {pr_json("OPEN"), 0},
        {pr_json("OPEN"), 0},
        {"git@github.com:example/mobile.git", 0},
        {"merged", 0},
        {pr_json("MERGED"), 0}
      ])

    factory_settings = Config.settings!().factory

    settings = %{
      factory_settings
      | command: executable,
        args: ["{{ phase }}"],
        phase_timeout_ms: 5_000,
        state_root: workspace <> "-state-#{System.unique_integer([:positive])}",
        github: %{factory_settings.github | enabled: true},
        post_merge: %{factory_settings.post_merge | enabled: true, args: ["post-merge"]}
    }

    assert :ok =
             Runner.run(issue(), workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id,
               github_executor: executor,
               linear_issue_state_reader: fn _issue_id -> {:ok, "In Progress"} end,
               artifact_receipt_verifier: fn event ->
                 artifact = get_in(event, ["payload", "artifact"])

                 {:ok,
                  %{
                    "runId" => event["runId"],
                    "issue" => event["issue"],
                    "commitSha" => artifact["commitSha"],
                    "artifactSha256" => artifact["sha256"],
                    "uri" => artifact["uri"]
                  }}
               end
             )

    events =
      for _index <- 1..15 do
        assert_receive {:factory_event, session_id, event}
        {session_id, event}
      end

    pr_events = Enum.filter(events, fn {_session_id, event} -> event["type"] == "pr.updated" end)

    assert [
             {"session-qa", %{"payload" => %{"state" => "open"}}},
             {"session-qa",
              %{
                "payload" => %{
                  "state" => "merged",
                  "qualityCheck" => %{
                    "name" => "factory/quality-gate",
                    "status" => "passed"
                  }
                }
              }}
           ] = pr_events

    File.write!(executable, "#!/bin/sh\nexit 91\n")

    restarted_bridge = fn
      :restore_factory_lifecycle, [_issue, facts] ->
        send(test_pid, {:restored_github_lifecycle, facts})
        :ok

      :complete_factory_lifecycle, [_issue] ->
        :ok
    end

    assert :ok =
             Runner.run(issue(), workspace,
               settings: settings,
               bridge: restarted_bridge,
               factory_run_id: @factory_run_id
             )

    assert_receive {:restored_github_lifecycle,
                    %{
                      qa_completed: true,
                      github_enabled: true,
                      merged: true,
                      quality_passed: true,
                      post_merge_completed: true,
                      integrated_head: @head_sha
                    }}
  end

  defp github_settings do
    %{Config.settings!().factory.github | enabled: true}
  end

  defp issue do
    %Issue{
      id: "issue-1",
      identifier: "APP-1",
      title: "Player queue",
      url: "https://linear.app/example/issue/APP-1"
    }
  end

  defp parsed_pr do
    %{
      number: 42,
      url: @pr_url,
      state: :open,
      head_ref: "factory/app-1",
      base_ref: "main",
      head_sha: @head_sha,
      base_sha: @base_sha
    }
  end

  defp pr_json(state), do: Jason.encode!(pr_map(state))

  defp pr_map(state) do
    %{
      "number" => 42,
      "url" => @pr_url,
      "state" => state,
      "headRefName" => "factory/app-1",
      "baseRefName" => "main",
      "headRefOid" => @head_sha,
      "baseRefOid" => @base_sha
    }
  end

  defp executor(responses) do
    queue = start_supervised!({Agent, fn -> responses end}, id: make_ref())
    test_pid = self()

    fn command, args, options ->
      send(test_pid, {:command, command, args, options})

      Agent.get_and_update(queue, fn
        [response | rest] -> {response, rest}
        [] -> flunk("unexpected command: #{command} #{inspect(args)}")
      end)
    end
  end

  defp command_calls(acc \\ []) do
    receive do
      {:command, command, args, options} ->
        assert options[:stderr_to_stdout] == true
        command_calls([{command, args, options[:cd]} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_command_calls do
    command_calls()
    :ok
  end
end
