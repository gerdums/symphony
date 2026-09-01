defmodule SymphonyElixir.FactoryGroomingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.Grooming
  alias SymphonyElixir.Tracker.Issue

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      factory_enabled: true,
      factory_command: "/usr/bin/true",
      factory_grooming_enabled: true,
      factory_grooming_args: [
        "groom",
        "--dry-run",
        "--project",
        "untrusted-project",
        "--project",
        "{{ factory.project_key }}",
        "--input",
        "{{ input }}"
      ],
      linear_agent_enabled: true,
      linear_agent_access_token: "oauth-token",
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    :ok
  end

  test "discovers Backlog, sends immutable prepared JSON, and applies only validated decisions" do
    test_pid = self()

    issue = %Issue{
      id: "issue-1",
      identifier: "APP-2022",
      title: "Add the player empty state",
      description: "- [ ] Shows useful guidance\n- [ ] Has a Maestro test",
      labels: ["mobile"],
      blocked_by: [%{identifier: "APP-2000", state: "In Progress"}],
      state: "Backlog"
    }

    fetcher = fn states ->
      send(test_pid, {:states, states})
      {:ok, [issue]}
    end

    executor = fn "/usr/bin/true", args, cwd, 300_000 ->
      assert Enum.count(args, &(&1 == "--project")) == 1
      project_index = Enum.find_index(args, &(&1 == "--project"))
      assert Enum.at(args, project_index + 1) == "project"

      input_path = Enum.at(args, Enum.find_index(args, &(&1 == "--input")) + 1)
      assert Path.dirname(input_path) == cwd
      assert {:ok, %File.Stat{mode: mode}} = File.stat(input_path)
      assert Bitwise.band(mode, 0o077) == 0

      assert [
               %{
                 "key" => "APP-2022",
                 "labels" => ["mobile"],
                 "description" => "- [ ] Shows useful guidance\n- [ ] Has a Maestro test",
                 "status" => "Backlog",
                 "acceptanceCriteria" => ["Shows useful guidance", "Has a Maestro test"],
                 "relations" => [%{"type" => "blockedBy", "issueKey" => "APP-2000"}]
               }
             ] = Jason.decode!(File.read!(input_path)) |> Enum.map(&Map.drop(&1, ["title"]))

      {:ok,
       Jason.encode!(%{
         "dryRun" => true,
         "agentLed" => true,
         "project" => "project",
         "decisions" => [
           %{
             "key" => "APP-2022",
             "from" => "Backlog",
             "to" => "Todo",
             "summary" => "Add a useful, tested player empty state",
             "acceptanceCriteria" => ["Shows useful guidance", "Has a Maestro test"],
             "reason" => "Ticket has testable acceptance criteria"
           }
         ]
       })}
    end

    bridge = fn ^issue, decision ->
      send(test_pid, {:decision, decision})
      :ok
    end

    assert :ok =
             Grooming.run(
               issue_fetcher: fetcher,
               executor: executor,
               bridge: bridge
             )

    assert_received {:states, ["Backlog"]}
    assert_received {:decision, %{"key" => "APP-2022", "to" => "Todo"}}
  end

  test "rejects a grooming result that tries to set Done" do
    issue = %Issue{id: "issue-1", identifier: "APP-2022", title: "Ticket", labels: [], state: "Backlog"}

    output =
      Jason.encode!(%{
        "dryRun" => true,
        "agentLed" => true,
        "project" => "project",
        "decisions" => [
          %{"key" => "APP-2022", "from" => "Backlog", "to" => "Done", "reason" => "unsafe"}
        ]
      })

    assert {:error, :invalid_factory_grooming_decision} =
             Grooming.run(
               issue_fetcher: fn _states -> {:ok, [issue]} end,
               executor: fn _executable, _args, _cwd, _timeout -> {:ok, output} end,
               bridge: fn _issue, _decision -> flunk("unsafe decision reached the bridge") end
             )
  end

  test "durably suppresses repeated Backlog decisions until the ticket materially changes" do
    test_pid = self()

    issue = %Issue{
      id: "issue-1",
      identifier: "APP-2022",
      title: "Investigate playback",
      description: "Initial report",
      labels: ["mobile"],
      state: "Backlog"
    }

    output =
      Jason.encode!(%{
        "dryRun" => true,
        "agentLed" => true,
        "project" => "project",
        "decisions" => [
          %{
            "key" => "APP-2022",
            "from" => "Backlog",
            "to" => "Backlog",
            "reason" => "Needs reproduction details"
          }
        ]
      })

    fingerprint_path =
      Path.join(
        Config.local_workspace_root(),
        "grooming-fingerprints-#{System.unique_integer([:positive])}.json"
      )

    run = fn current_issue ->
      Grooming.run(
        issue_fetcher: fn _states -> {:ok, [current_issue]} end,
        executor: fn _executable, _args, _cwd, _timeout -> {:ok, output} end,
        bridge: fn _issue, _decision ->
          send(test_pid, :grooming_activity)
          :ok
        end,
        fingerprint_path: fingerprint_path
      )
    end

    assert :ok = run.(issue)
    assert_receive :grooming_activity

    assert %{"version" => 1, "fingerprints" => %{"APP-2022" => digest}} =
             fingerprint_path |> File.read!() |> Jason.decode!()

    assert byte_size(digest) == 64

    assert :ok = run.(issue)
    refute_receive :grooming_activity

    assert :ok = run.(%{issue | description: "Now includes exact reproduction steps"})
    assert_receive :grooming_activity
  end

  test "grooming timeout is one wall-clock deadline across output chunks" do
    workspace =
      Path.join(
        Config.local_workspace_root(),
        "groom-timeout-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "stream-forever")

    File.write!(
      executable,
      """
      #!/bin/sh
      while true; do
        printf 'x'
        sleep 0.02
      done
      """
    )

    File.chmod!(executable, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      factory_enabled: true,
      factory_command: executable,
      factory_grooming_enabled: true,
      factory_grooming_args: ["groom", "--dry-run", "--input", "{{ input }}"],
      factory_grooming_timeout_ms: 80,
      linear_agent_enabled: true,
      linear_agent_access_token: "oauth-token",
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    issue = %Issue{id: "issue-1", identifier: "APP-2022", title: "Ticket", labels: [], state: "Backlog"}

    assert {:error, {:factory_grooming_timeout, 80}} =
             Grooming.run(issue_fetcher: fn _states -> {:ok, [issue]} end)
  end
end
