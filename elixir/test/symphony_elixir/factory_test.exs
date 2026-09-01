defmodule SymphonyElixir.FactoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Factory.{Policy, Protocol, Runner}
  alias SymphonyElixir.Linear.AgentBridge
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State

  @factory_run_id "10000000-0000-4000-8000-000000000001"
  @feedback_run_id "10000000-0000-4000-8000-000000000002"

  setup do
    state_root =
      Path.join(
        Config.local_workspace_root(),
        "factory-state-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
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

  test "protocol accepts versioned events and rejects drift" do
    event = factory_event("progress", "build", %{"message" => "Implemented the player state change."})

    assert {:ok, ^event} = Protocol.parse_line(Jason.encode!(event))

    assert {:error, {:unexpected_value, "protocolVersion", 1, 2}} =
             Protocol.parse_line(Jason.encode!(event), 2)

    assert {:error, {:unsupported_value, "phase", "release"}} =
             event
             |> Map.put("phase", "release")
             |> Jason.encode!()
             |> Protocol.parse_line()

    args = Config.settings!().factory.args
    repository_path_index = Enum.find_index(args, &(&1 == "--repository-path"))
    assert is_integer(repository_path_index)
    assert Enum.at(args, repository_path_index + 1) == "{{ workspace }}"

    github = Config.settings!().factory.github
    refute github.enabled
    assert github.required_check == "factory/quality-gate"

    check =
      factory_event("check.completed", "qa", %{
        "name" => "Maestro",
        "status" => "passed",
        "required" => true,
        "acceptance" => true,
        "external" => false
      })

    assert {:ok, ^check} = Protocol.parse_line(Jason.encode!(check))

    assert {:error, {:unknown_fields, "payload", ["unexpected"]}} =
             check
             |> put_in(["payload", "unexpected"], true)
             |> Jason.encode!()
             |> Protocol.parse_line()

    plan =
      factory_event("plan.updated", "planning", %{
        "summary" => "Interactive mobile change",
        "acceptanceCriteria" => ["Playback works"],
        "workScope" => "runtime-interactive",
        "postMergeInternalBuild" => true,
        "proofTargets" => [
          %{
            "platform" => "ios",
            "flow" => "playback-flow",
            "requiredMedia" => ["image", "video"]
          }
        ]
      })

    assert {:ok, ^plan} = Protocol.parse_line(Jason.encode!(plan))

    artifact_event =
      factory_event("artifact.created", "qa", %{
        "artifact" => artifact("image", "remote_url", "https://uploads.linear.app/proof.png", "Proof")
      })

    assert {:ok, ^artifact_event} = Protocol.parse_line(Jason.encode!(artifact_event))

    assert {:error, {:missing_fields, "payload.artifact", ["deviceIdentity"]}} =
             artifact_event
             |> pop_in(["payload", "artifact", "deviceIdentity"])
             |> elem(1)
             |> Jason.encode!()
             |> Protocol.parse_line()
  end

  test "schema rejects a factory without native Linear agent sessions" do
    assert {:error, {:invalid_workflow_config, message}} =
             Config.Schema.parse(%{
               "factory" => %{"enabled" => true, "project_key" => "project"},
               "linear_agent" => %{"enabled" => false}
             })

    assert message =~ "factory.enabled requires linear_agent.enabled"
  end

  test "trusted proof and checks are invalidated when the integrated head changes" do
    old_head = String.duplicate("a", 40)
    final_head = String.duplicate("b", 40)

    journal = %{
      "integrated_head" => final_head,
      "trusted_check_heads" => %{"review" => [old_head], "qa" => [old_head]},
      "work_scope" => "runtime-interactive",
      "proof_targets" => [],
      "proof_artifacts" => [
        %{"commitSha" => old_head, "kind" => "image"},
        %{"commitSha" => old_head, "kind" => "video"}
      ]
    }

    assert {:error, :trusted_review_missing} = Runner.trusted_quality_evidence_for_test(journal)

    journal = put_in(journal, ["trusted_check_heads"], %{"review" => [final_head], "qa" => [final_head]})
    assert {:error, :trusted_proof_missing} = Runner.trusted_quality_evidence_for_test(journal)
  end

  test "state policy makes Done human-only" do
    assert {:error, :done_is_human_only} = Policy.allow_transition("Done")
    assert {:error, :done_is_human_only} = Policy.allow_transition(" done ")
    assert :ok = Policy.allow_transition("In Review")
  end

  test "runner replays four phases without duplicating event activity" do
    workspace =
      Path.join(
        Config.local_workspace_root(),
        "factory-replay-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-factory-events")

    script =
      """
      #!/bin/sh
      phase="$SYMPHONY_FACTORY_PHASE"
      test "$2" = "$3" || exit 17
      project_count=0
      issue_count=0
      title_count=0
      run_count=0
      scope_count=0
      while [ "$#" -gt 0 ]; do
        option="$1"
        shift
        case "$option" in
          --project)
            test "$1" = project || exit 18
            project_count=$((project_count + 1))
            shift
            ;;
          --issue)
            test "$1" = APP-1 || exit 25
            issue_count=$((issue_count + 1))
            shift
            ;;
          --issue-title)
            test "$1" = "Build autonomous factory" || exit 26
            title_count=$((title_count + 1))
            shift
            ;;
          --run-id)
            test "$1" = 10000000-0000-4000-8000-000000000001 || exit 19
            run_count=$((run_count + 1))
            shift
            ;;
          --work-scope)
            test "$1" = non-runtime || exit 20
            scope_count=$((scope_count + 1))
            shift
            ;;
        esac
      done
      test "$project_count" -eq 1 || exit 21
      test "$issue_count" -eq 1 || exit 27
      test "$title_count" -eq 1 || exit 28
      test "$run_count" -eq 1 || exit 22
      if [ "$phase" = planning ]; then
        test "$scope_count" -eq 0 || exit 23
      else
        test "$scope_count" -eq 1 || exit 24
      fi
      case "$phase" in planning) n=1;; build) n=2;; review) n=3;; qa) n=4;; esac
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-%012d","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-1","type":"phase.started","phase":"%s","payload":{"attempt":1,"packet":"packet","branch":"branch","workspace":"sandcastle://branch"}}\n' "$((n * 10 + 1))" "$phase"
      if [ "$phase" = planning ]; then
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000013","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:30Z","project":"project","issue":"APP-1","type":"plan.updated","phase":"planning","payload":{"summary":"Non-runtime change","acceptanceCriteria":["Checks pass"],"workScope":"non-runtime","postMergeInternalBuild":false,"proofTargets":[]}}\n'
      fi
      if [ "$phase" = build ]; then
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000023","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:40Z","project":"project","issue":"APP-1","type":"diff.updated","phase":"build","payload":{"filesChanged":1,"insertions":3,"deletions":0,"commitShas":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}}\n'
      fi
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-%012d","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:01:00Z","project":"project","issue":"APP-1","type":"phase.completed","phase":"%s","payload":{"summary":"phase complete","branch":"branch","commitShas":[]}}\n' "$((n * 10 + 2))" "$phase"
      printf 'factory completed %s\n' "$phase" >&2
      """

    File.write!(executable, script)

    File.chmod!(executable, 0o755)
    test_pid = self()

    bridge = fn
      :ensure_phase_session, [%Issue{}, phase] ->
        {:ok, "session-#{phase}"}

      :register_phase_session, [_issue_id, _phase, _session_id] ->
        :ok

      :report_factory_event, [_issue, session_id, event] ->
        send(test_pid, {:factory_event, session_id, event["eventId"]})
        :ok

      :restore_factory_event, [_issue, session_id, event] ->
        send(test_pid, {:factory_event_restored, session_id, event["eventId"]})
        :ok

      :restore_factory_lifecycle, [_issue, facts] ->
        send(test_pid, {:factory_lifecycle_facts, facts})
        :ok

      :complete_factory_lifecycle, [_issue] ->
        :ok
    end

    settings = %{
      Config.settings!().factory
      | command: executable,
        args: [
          "{{ phase }}",
          "{{ workspace }}",
          workspace,
          "--project",
          "untrusted-one",
          "--project",
          "untrusted-two",
          "--issue",
          "WRONG-1",
          "--issue-title",
          "Wrong title",
          "--run-id",
          "untrusted-run",
          "--work-scope",
          "untrusted-scope"
        ],
        phase_timeout_ms: 5_000
    }

    issue = %Issue{id: "issue-1", identifier: "APP-1", title: "Build autonomous factory"}

    assert :ok =
             Runner.run(issue, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )

    first_events =
      for _index <- 1..10 do
        assert_receive {:factory_event, session_id, event_id}
        {session_id, event_id}
      end

    assert Enum.sort(first_events) ==
             Enum.sort(
               for {phase, index} <- Enum.with_index(Protocol.phases(), 1), offset <- [1, 2] do
                 {"session-#{phase}", test_event_uuid(index * 10 + offset)}
               end ++
                 [
                   {"session-planning", test_event_uuid(13)},
                   {"session-build", test_event_uuid(23)}
                 ]
             )

    assert_receive {:factory_lifecycle_facts,
                    %{
                      qa_completed: true,
                      github_enabled: false,
                      post_merge_completed: true,
                      change_bindings: [
                        %{
                          phase: "build",
                          agent_id: "phase",
                          session_id: "session-build",
                          commit_shas: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
                        }
                      ]
                    }}

    assert :ok =
             Runner.run(issue, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )

    refute_receive {:factory_event, _, _}, 100
    refute_receive {:factory_event_restored, _, _}, 100

    state_root = Config.factory_state_root(settings)
    refute File.exists?(Path.join(workspace, ".symphony"))
    assert [journal_path] = Path.wildcard(Path.join([state_root, "**", "*.json"]))
    journal = journal_path |> File.read!() |> Jason.decode!()

    assert journal["binding"] == %{
             "issue_id" => "issue-1",
             "issue_identifier" => "APP-1",
             "project" => "project"
           }

    assert journal["run_id"] == "10000000-0000-4000-8000-000000000001"
    assert length(journal["phase_events"]["planning"]) == 3

    assert journal["change_bindings"] == [
             %{
               "phase" => "build",
               "agent_id" => "phase",
               "session_id" => "session-build",
               "commit_shas" => ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
             }
           ]

    File.write!(executable, String.replace(script, ~s("packet":"packet"), ~s("packet":"changed")))

    # Completed generations never re-execute a mutable factory command.
    assert :ok =
             Runner.run(issue, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )
  end

  test "runner resumes an interrupted phase without requiring the old random event IDs" do
    workspace =
      Path.join(
        Config.local_workspace_root(),
        "factory-interrupted-#{System.unique_integer([:positive])}"
      )

    state_root = workspace <> "-state"
    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-interrupted-phase")
    counter = Path.join(workspace, "counter")

    File.write!(
      executable,
      """
      #!/bin/sh
      count=0
      test ! -f '#{counter}' || count=$(cat '#{counter}')
      count=$((count + 1))
      printf '%s' "$count" > '#{counter}'
      if test "$count" -eq 1; then
        printf '%s\n' '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000701","runId":"#{@factory_run_id}","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-1","type":"phase.started","phase":"planning","payload":{"attempt":1,"packet":"first","branch":"factory/app-1","workspace":"sandcastle://first"}}'
        exit 9
      fi
      printf '%s\n' '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000711","runId":"#{@factory_run_id}","occurredAt":"2026-08-31T20:01:00Z","project":"project","issue":"APP-1","type":"phase.started","phase":"planning","payload":{"attempt":2,"packet":"second","branch":"factory/app-1","workspace":"sandcastle://second"}}'
      printf '%s\n' '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000712","runId":"#{@factory_run_id}","occurredAt":"2026-08-31T20:01:01Z","project":"project","issue":"APP-1","type":"plan.updated","phase":"planning","payload":{"summary":"Recovered plan","acceptanceCriteria":["Recovery works"],"workScope":"non-runtime","postMergeInternalBuild":false,"proofTargets":[]}}'
      printf '%s\n' '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000713","runId":"#{@factory_run_id}","occurredAt":"2026-08-31T20:01:02Z","project":"project","issue":"APP-1","type":"phase.completed","phase":"planning","payload":{"summary":"Recovered","branch":"factory/app-1","commitShas":[]}}'
      """
    )

    File.chmod!(executable, 0o755)
    test_pid = self()

    bridge = fn
      :ensure_phase_session, [_issue, _phase] ->
        {:ok, "planning-session"}

      :register_phase_session, [_issue_id, _phase, _session_id] ->
        :ok

      :report_factory_event, [_issue, _session_id, event] ->
        send(test_pid, {:interrupted_event, event["eventId"]})
        :ok

      :restore_factory_event, [_issue, _session_id, _event] ->
        :ok

      :restore_factory_lifecycle, [_issue, _facts] ->
        :ok

      :complete_factory_lifecycle, [_issue] ->
        :ok
    end

    settings = %{
      Config.settings!().factory
      | command: executable,
        args: [],
        phases: ["planning"],
        state_root: state_root,
        phase_timeout_ms: 2_000
    }

    assert {:error, {:factory_phase_failed, "planning", {:exit_status, 9}}} =
             Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )

    assert_receive {:interrupted_event, "00000000-0000-4000-8000-000000000701"}

    assert :ok =
             Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )

    assert_receive {:interrupted_event, "00000000-0000-4000-8000-000000000711"}
    assert_receive {:interrupted_event, "00000000-0000-4000-8000-000000000712"}
    assert_receive {:interrupted_event, "00000000-0000-4000-8000-000000000713"}
  end

  test "post-merge command timeout is one wall-clock deadline across output chunks" do
    workspace =
      Path.join(
        Config.local_workspace_root(),
        "post-merge-timeout-#{System.unique_integer([:positive])}"
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

    assert {:error, {:post_merge_timeout, 80}} =
             Runner.run_bounded_command_for_test(executable, [], workspace, 80)
  end

  test "media tools use an allowlisted private bounded Port executor" do
    workspace =
      Path.join(Config.local_workspace_root(), "media-port-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "media-tool")

    File.write!(
      executable,
      """
      #!/bin/sh
      test -z "$SYMPHONY_MEDIA_SECRET" || exit 27
      case "$1" in
        ok) printf 'decoded' ;;
        stream) while true; do printf 'x'; sleep 0.02; done ;;
        large) while true; do printf '1234567890'; done ;;
      esac
      """
    )

    File.chmod!(executable, 0o755)
    System.put_env("SYMPHONY_MEDIA_SECRET", "must-not-leak")
    on_exit(fn -> System.delete_env("SYMPHONY_MEDIA_SECRET") end)
    resolver = fn _command -> executable end

    assert {:ok, {"decoded", 0}} =
             Runner.run_media_command_for_test("ffprobe", ["ok"], workspace, executable_resolver: resolver)

    assert {:error, {:media_command_timeout, 80}} =
             Runner.run_media_command_for_test("ffmpeg", ["stream"], workspace,
               executable_resolver: resolver,
               timeout_ms: 80
             )

    assert {:error, :media_command_output_too_large} =
             Runner.run_media_command_for_test("sips", ["large"], workspace,
               executable_resolver: resolver,
               max_output_bytes: 32
             )

    assert {:error, {:media_command_not_allowed, "sh"}} =
             Runner.run_media_command_for_test("sh", ["-c", "true"], workspace, executable_resolver: resolver)
  end

  test "phase streams require one terminal event and reject contradictory post-terminal events" do
    completed =
      factory_event("phase.completed", "planning", %{
        "summary" => "Planning complete.",
        "branch" => "factory/app-1",
        "commitShas" => []
      })

    failed =
      factory_event("phase.failed", "planning", %{
        "error" => "Contradictory failure.",
        "retryable" => false
      })

    assert {:error, {:factory_phase_failed, "planning", {:event_after_terminal, "phase.completed", "phase.failed"}}} =
             run_planning_events([completed, failed])

    assert {:error, {:factory_phase_failed, "planning", {:phase_terminated, "phase.failed"}}} =
             run_planning_events([failed])

    progress = factory_event("progress", "planning", %{"message" => "Still working."})

    assert {:error, {:factory_phase_failed, "planning", :phase_completion_event_missing}} =
             run_planning_events([progress])
  end

  test "runner binds project and trusted state root" do
    event =
      factory_event("phase.completed", "planning", %{
        "summary" => "Planning complete.",
        "branch" => "factory/app-1",
        "commitShas" => []
      })

    assert {:error, {:factory_phase_failed, "planning", {:wrong_project, "other", "project"}}} =
             event
             |> Map.put("project", "other")
             |> then(&run_planning_events([&1]))

    workspace =
      Path.join(Config.local_workspace_root(), "factory-state-scope-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    settings = %{Config.settings!().factory | state_root: Path.join(workspace, "state")}

    assert {:error, :factory_state_root_inside_workspace} =
             Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
               settings: settings,
               bridge: factory_bridge()
             )
  end

  test "review feedback is drained once and passed to every local factory phase" do
    bridge_name = String.to_atom("factory_feedback_bridge_#{System.unique_integer([:positive])}")

    request_fun = fn payload, _headers ->
      query = payload["query"]

      cond do
        query =~ "SymphonyCreateAgentActivity" ->
          graphql_response("agentActivityCreate", %{
            "success" => true,
            "agentActivity" => %{"id" => "activity-1"}
          })

        query =~ "SymphonyIssueState" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-1",
                   "state" => %{"name" => "In Review"},
                   "team" => %{
                     "states" => %{
                       "nodes" => [
                         %{"id" => "state-progress", "name" => "In Progress"},
                         %{"id" => "state-review", "name" => "In Review"}
                       ]
                     }
                   }
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateIssueState" ->
          graphql_response("issueUpdate", %{
            "success" => true,
            "issue" => %{"id" => "issue-1", "state" => %{"name" => "In Progress"}}
          })
      end
    end

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    :ok = AgentBridge.register_phase_session("issue-1", "qa", "qa-session", bridge_name)

    :ok =
      AgentBridge.accept_webhook(
        %{
          "action" => "prompted",
          "webhookId" => "feedback-webhook",
          "oauthClientId" => "oauth-client",
          "appUserId" => "app-user",
          "agentSession" => %{"id" => "qa-session", "issueId" => "issue-1"},
          "agentActivity" => %{
            "id" => "feedback-activity",
            "content" => %{"body" => "Adjust the empty state."}
          }
        },
        bridge_name
      )

    assert [%{id: "feedback-activity", body: "Adjust the empty state.", action: "prompted"}] =
             AgentBridge.take_prompts("issue-1", bridge_name)

    assert [] = AgentBridge.take_prompts("issue-1", bridge_name)

    feedback = [%{id: "feedback-activity", body: "Adjust the empty state.", action: "prompted"}]

    expected_feedback =
      Jason.encode!([
        %{
          "id" => "feedback-activity",
          "body" => "Adjust the empty state.",
          "action" => "prompted"
        }
      ])

    workspace = Path.join(Config.local_workspace_root(), "factory-feedback-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-feedback-events")

    File.write!(
      executable,
      """
      #!/bin/sh
      test "$SYMPHONY_FACTORY_REVIEW_FEEDBACK_JSON" = '#{expected_feedback}' || exit 19
      phase="$SYMPHONY_FACTORY_PHASE"
      case "$phase" in planning) n=1;; build) n=2;; review) n=3;; qa) n=4;; esac
      if [ "$phase" = planning ]; then
        printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000010","runId":"10000000-0000-4000-8000-000000000002","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-1","type":"plan.updated","phase":"planning","payload":{"summary":"Non-runtime feedback change","acceptanceCriteria":["Feedback addressed"],"workScope":"non-runtime","postMergeInternalBuild":false,"proofTargets":[]}}\n'
      fi
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-%012d","runId":"10000000-0000-4000-8000-000000000002","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-1","type":"phase.completed","phase":"%s","payload":{"summary":"phase complete","branch":"factory/app-1","commitShas":[]}}\n' "$n" "$phase"
      """
    )

    File.chmod!(executable, 0o755)
    settings = %{Config.settings!().factory | command: executable, args: ["{{ phase }}"]}

    assert :ok =
             Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
               settings: settings,
               bridge: factory_bridge(),
               review_feedback: feedback,
               factory_run_id: @feedback_run_id
             )
  end

  test "webhook dedupe and checked-out feedback survive an AgentBridge restart" do
    bridge_name = String.to_atom("factory_durable_bridge_#{System.unique_integer([:positive])}")
    durable_path = Path.join(Config.factory_state_root(), "feedback-restart.json")
    test_pid = self()

    request_fun = fn payload, _headers ->
      query = payload["query"]

      cond do
        query =~ "SymphonyCreateAgentActivity" ->
          graphql_response("agentActivityCreate", %{
            "success" => true,
            "agentActivity" => %{"id" => "activity-1"}
          })

        query =~ "SymphonyIssueState" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-1",
                   "state" => %{"name" => "In Review"},
                   "team" => %{
                     "states" => %{
                       "nodes" => [
                         %{"id" => "state-progress", "name" => "In Progress"},
                         %{"id" => "state-review", "name" => "In Review"}
                       ]
                     }
                   }
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateIssueState" ->
          send(test_pid, :durable_feedback_reopened)

          graphql_response("issueUpdate", %{
            "success" => true,
            "issue" => %{"id" => "issue-1", "state" => %{"name" => "In Progress"}}
          })
      end
    end

    webhook = %{
      "action" => "prompted",
      "webhookId" => "durable-webhook-1",
      "oauthClientId" => "oauth-client",
      "appUserId" => "app-user",
      "agentSession" => %{"id" => "qa-session", "issueId" => "issue-1"},
      "agentActivity" => %{
        "id" => "durable-feedback-1",
        "content" => %{"body" => "Keep this feedback across restart."}
      }
    }

    {:ok, first_bridge} =
      AgentBridge.start_link(
        name: bridge_name,
        orchestrator: nil,
        durable_feedback_path: durable_path,
        client_opts: [request_fun: request_fun]
      )

    :ok = AgentBridge.accept_webhook(webhook, bridge_name)

    durable_payload = durable_path |> File.read!() |> Jason.decode!()
    assert "durable-webhook-1" in durable_payload["seenWebhooks"]
    assert [%{"id" => "durable-feedback-1"}] = durable_payload["pendingPrompts"]["issue-1"]

    expected = [
      %{
        id: "durable-feedback-1",
        body: "Keep this feedback across restart.",
        action: "prompted"
      }
    ]

    assert expected == AgentBridge.checkout_factory_feedback("issue-1", bridge_name)
    GenServer.stop(first_bridge)

    {:ok, second_bridge} =
      AgentBridge.start_link(
        name: bridge_name,
        orchestrator: nil,
        durable_feedback_path: durable_path,
        client_opts: [request_fun: request_fun]
      )

    assert expected == AgentBridge.checkout_factory_feedback("issue-1", bridge_name)
    :ok = AgentBridge.accept_webhook(webhook, bridge_name)
    assert expected == AgentBridge.checkout_factory_feedback("issue-1", bridge_name)
    assert {:ok, false} = AgentBridge.acknowledge_factory_feedback("issue-1", expected, bridge_name)
    GenServer.stop(second_bridge)

    {:ok, third_bridge} =
      AgentBridge.start_link(
        name: bridge_name,
        orchestrator: nil,
        durable_feedback_path: durable_path,
        client_opts: [request_fun: request_fun]
      )

    assert [] == AgentBridge.checkout_factory_feedback("issue-1", bridge_name)
    :ok = AgentBridge.accept_webhook(webhook, bridge_name)
    assert [] == AgentBridge.checkout_factory_feedback("issue-1", bridge_name)
    GenServer.stop(third_bridge)

    assert_receive :durable_feedback_reopened, 1_000
  end

  test "In Review remains visible but cannot dispatch and factory ignores SSH capacity" do
    state = %State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{}
    }

    review_issue = %Issue{
      id: "issue-1",
      identifier: "APP-1",
      title: "Review",
      state: "In Review",
      dispatchable: true
    }

    progress_issue = %Issue{
      id: "issue-2",
      identifier: "APP-2",
      title: "Build",
      state: "In Progress",
      dispatchable: true
    }

    refute Orchestrator.should_dispatch_issue_for_test(review_issue, state)
    assert Orchestrator.session_visible_issue_for_test(review_issue)
    assert "In Review" in Orchestrator.poll_state_names_for_test()
    assert Orchestrator.should_dispatch_issue_for_test(progress_issue, state)
    assert Orchestrator.select_worker_host_for_test(state, "unavailable-ssh-worker") == nil

    inactive_entry = %{
      identifier: "APP-1",
      issue: review_issue,
      run_outcome: :inactive,
      worker_host: nil,
      workspace_path: nil
    }

    inactive_state = %{
      state
      | claimed: MapSet.new(["issue-1"]),
        retry_attempts: %{"issue-1" => %{attempt: 1}}
    }

    settled =
      Orchestrator.handle_normal_agent_down_for_test(
        inactive_state,
        "issue-1",
        inactive_entry,
        "qa-session"
      )

    assert MapSet.member?(settled.completed, "issue-1")
    refute MapSet.member?(settled.claimed, "issue-1")
    refute Map.has_key?(settled.retry_attempts, "issue-1")
  end

  test "runner rejects an event for a different issue" do
    workspace =
      Path.join(Config.local_workspace_root(), "factory-wrong-issue-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-wrong-issue")

    File.write!(
      executable,
      """
      #!/bin/sh
      phase="$SYMPHONY_FACTORY_PHASE"
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000001","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-999","type":"phase.started","phase":"%s","payload":{"attempt":1,"packet":"packet","branch":"branch","workspace":"sandcastle://branch"}}\n' "$phase"
      """
    )

    File.chmod!(executable, 0o755)

    bridge = fn
      :ensure_phase_session, [_issue, phase] -> {:ok, "session-#{phase}"}
      :register_phase_session, [_issue_id, _phase, _session_id] -> :ok
      :report_factory_event, _arguments -> flunk("cross-ticket event must not reach Linear")
    end

    settings = %{
      Config.settings!().factory
      | command: executable,
        args: ["{{ phase }}"],
        phase_timeout_ms: 5_000
    }

    assert {:error, {:factory_phase_failed, "planning", {:wrong_issue, "APP-999", "APP-1"}}} =
             Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )
  end

  test "runner rejects a factory-authored merged PR event" do
    workspace =
      Path.join(Config.local_workspace_root(), "factory-merged-pr-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-merged-pr")

    File.write!(
      executable,
      """
      #!/bin/sh
      phase="$SYMPHONY_FACTORY_PHASE"
      printf '{"protocolVersion":1,"eventId":"00000000-0000-4000-8000-000000000001","runId":"10000000-0000-4000-8000-000000000001","occurredAt":"2026-08-31T20:00:00Z","project":"project","issue":"APP-1","type":"pr.updated","phase":"%s","payload":{"state":"merged","number":42,"url":"https://github.com/example/mobile/pull/42","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","qualityCheck":{"name":"factory/quality-gate","status":"passed"}}}\n' "$phase"
      """
    )

    File.chmod!(executable, 0o755)

    bridge = fn
      :ensure_phase_session, [_issue, phase] -> {:ok, "session-#{phase}"}
      :register_phase_session, [_issue_id, _phase, _session_id] -> :ok
      :report_factory_event, _arguments -> flunk("factory-authored merge must not reach Linear")
    end

    settings = %{
      Config.settings!().factory
      | command: executable,
        args: ["{{ phase }}"],
        phase_timeout_ms: 5_000
    }

    assert {:error, {:factory_phase_failed, "planning", :github_finalization_is_symphony_owned}} =
             Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
               settings: settings,
               bridge: bridge,
               factory_run_id: @factory_run_id
             )
  end

  test "phase sessions render role-tagged checks, image, video, and pull request activity" do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    request_fun = fn payload, _headers ->
      query = payload["query"]

      cond do
        query =~ "SymphonyCreateAgentSession" ->
          session_number = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
          session_id = "phase-session-#{session_number}"
          send(test_pid, {:session_created, session_id})

          graphql_response("agentSessionCreateOnIssue", %{
            "success" => true,
            "agentSession" => %{"id" => session_id}
          })

        query =~ "SymphonyCreateAgentActivity" ->
          send(test_pid, {:activity, payload["variables"]["input"]})

          graphql_response("agentActivityCreate", %{
            "success" => true,
            "agentActivity" => %{"id" => "activity-1"}
          })

        query =~ "SymphonyAgentSessionExternalLinks" ->
          send(test_pid, {:external_links_lookup, payload["variables"]["id"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentSession" => %{
                   "id" => payload["variables"]["id"],
                   "externalLinks" => []
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateAgentSession" ->
          send(test_pid, {:session_update, payload["variables"]})

          graphql_response("agentSessionUpdate", %{
            "success" => true,
            "agentSession" => %{"id" => payload["variables"]["id"]}
          })

        query =~ "SymphonyIssueState" ->
          send(test_pid, {:state_lookup, payload["variables"]["issueId"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-1",
                   "state" => %{"name" => "In Review"},
                   "team" => %{
                     "states" => %{
                       "nodes" => [
                         %{"id" => "state-progress", "name" => "In Progress"},
                         %{"id" => "state-review", "name" => "In Review"},
                         %{"id" => "state-done", "name" => "Done"}
                       ]
                     }
                   }
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateIssueState" ->
          send(test_pid, {:state_update, payload["variables"]})

          graphql_response("issueUpdate", %{
            "success" => true,
            "issue" => %{"id" => "issue-1", "state" => %{"name" => "In Review"}}
          })

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("factory_bridge_#{System.unique_integer([:positive])}")
    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})
    issue = %Issue{id: "issue-1", identifier: "APP-1", state: "In Progress"}

    phase_sessions =
      for phase <- Protocol.phases(), into: %{} do
        assert {:ok, session_id} = AgentBridge.ensure_phase_session(issue, phase, bridge_name)
        {phase, session_id}
      end

    assert map_size(phase_sessions) == 4
    assert MapSet.size(MapSet.new(Map.values(phase_sessions))) == 4

    build_diff =
      factory_event("diff.updated", "build", %{
        "filesChanged" => 3,
        "insertions" => 18,
        "deletions" => 4,
        "commitShas" => [String.duplicate("a", 40)]
      })

    assert :ok =
             AgentBridge.report_factory_event(
               issue,
               phase_sessions["build"],
               build_diff,
               bridge_name
             )

    qa_agent =
      factory_event("agent.started", "qa", %{
        "provider" => "codex",
        "model" => "gpt-5.6-sol",
        "role" => "maestro",
        "readOnly" => false
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["qa"], qa_agent, bridge_name)

    qa_diff =
      factory_event("diff.updated", "qa", %{
        "filesChanged" => 1,
        "insertions" => 6,
        "deletions" => 1,
        "commitShas" => [String.duplicate("a", 40)]
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["qa"], qa_diff, bridge_name)

    image_event =
      factory_event("artifact.created", "qa", %{
        "artifact" =>
          artifact(
            "image",
            "remote_url",
            "https://uploads.linear.app/after.png",
            "After adding the queue item"
          )
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["qa"], image_event, bridge_name)

    video_event =
      factory_event("artifact.created", "qa", %{
        "artifact" =>
          artifact(
            "video",
            "linear_attachment",
            "https://uploads.linear.app/flow.mp4",
            "Maestro playback flow"
          )
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["qa"], video_event, bridge_name)

    review_agent =
      factory_event("agent.started", "review", %{
        "provider" => "claude",
        "model" => "claude-sonnet-4-6",
        "role" => "claude-reviewer",
        "readOnly" => true
      })

    assert :ok =
             AgentBridge.report_factory_event(issue, phase_sessions["review"], review_agent, bridge_name)

    pr_event =
      factory_event("pr.updated", "review", %{
        "state" => "open",
        "number" => 42,
        "url" => "https://github.com/example/mobile/pull/42",
        "headSha" => String.duplicate("a", 40),
        "qualityCheck" => %{"name" => "factory/quality-gate", "status" => "passed"}
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["review"], pr_event, bridge_name)

    check_agent =
      factory_event("agent.started", "qa", %{
        "provider" => "codex",
        "model" => "gpt-5.6-sol",
        "role" => "codex-qa",
        "readOnly" => false
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["qa"], check_agent, bridge_name)

    check_event =
      factory_event("check.completed", "qa", %{
        "name" => "Maestro smoke test",
        "status" => "passed",
        "summary" => "iOS and Android passed",
        "external" => false
      })

    assert :ok = AgentBridge.report_factory_event(issue, phase_sessions["qa"], check_event, bridge_name)

    image_body = receive_activity_body_containing("![After adding the queue item]")
    assert image_body =~ "[Qa]"

    video_body = receive_activity_body_containing("flow.mp4")
    assert video_body =~ "Video proof"

    local_artifact =
      factory_event("artifact.created", "qa", %{
        "artifact" => artifact("image", "remote_url", "/tmp/after.png", "Not visible outside the worker")
      })

    assert {:error, {:factory_artifact_requires_https_url, "artifact.uri"}} =
             AgentBridge.report_factory_event(
               issue,
               phase_sessions["qa"],
               local_artifact,
               bridge_name
             )

    for expected_session <- [phase_sessions["review"], phase_sessions["build"], phase_sessions["qa"]] do
      assert_receive {:session_update,
                      %{
                        "id" => ^expected_session,
                        "input" => %{
                          "addedExternalUrls" => [
                            %{
                              "label" => "Pull Request",
                              "url" => "https://github.com/example/mobile/pull/42"
                            }
                          ]
                        }
                      }},
                     1_000
    end

    assert_receive {:activity,
                    %{
                      "content" => %{
                        "type" => "action",
                        "action" => "Maestro smoke test: passed",
                        "parameter" => "[Qa] iOS and Android passed"
                      }
                    }},
                   1_000
  end

  test "restart before PR restores prior diff sessions for pull request linking" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      query = payload["query"]

      cond do
        query =~ "SymphonyCreateAgentActivity" ->
          graphql_response("agentActivityCreate", %{
            "success" => true,
            "agentActivity" => %{"id" => "activity-1"}
          })

        query =~ "SymphonyAgentSessionExternalLinks" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentSession" => %{
                   "id" => payload["variables"]["id"],
                   "externalLinks" => []
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateAgentSession" ->
          send(test_pid, {:restart_session_update, payload["variables"]})

          graphql_response("agentSessionUpdate", %{
            "success" => true,
            "agentSession" => %{"id" => payload["variables"]["id"]}
          })

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    issue = %Issue{id: "issue-1", identifier: "APP-1"}
    first_name = String.to_atom("factory_restart_before_pr_a_#{System.unique_integer([:positive])}")

    {:ok, first_bridge} =
      AgentBridge.start_link(name: first_name, orchestrator: nil, client_opts: [request_fun: request_fun])

    :ok = AgentBridge.register_phase_session(issue.id, "build", "build-session", first_name)

    diff =
      factory_event("diff.updated", "build", %{
        "filesChanged" => 1,
        "insertions" => 3,
        "deletions" => 0,
        "commitShas" => [String.duplicate("a", 40)]
      })

    assert :ok = AgentBridge.report_factory_event(issue, "build-session", diff, first_name)
    GenServer.stop(first_bridge)

    second_name = String.to_atom("factory_restart_before_pr_b_#{System.unique_integer([:positive])}")

    {:ok, second_bridge} =
      AgentBridge.start_link(name: second_name, orchestrator: nil, client_opts: [request_fun: request_fun])

    on_exit(fn -> if Process.alive?(second_bridge), do: GenServer.stop(second_bridge) end)
    :ok = AgentBridge.register_phase_session(issue.id, "review", "review-session", second_name)

    assert :ok =
             AgentBridge.restore_factory_lifecycle(
               issue,
               %{
                 qa_completed: false,
                 github_enabled: false,
                 merged: false,
                 quality_passed: false,
                 post_merge_completed: true,
                 integrated_head: String.duplicate("a", 40),
                 change_bindings: [
                   %{
                     phase: "build",
                     agent_id: "phase",
                     session_id: "build-session",
                     commit_shas: [String.duplicate("a", 40)]
                   }
                 ]
               },
               second_name
             )

    pr =
      factory_event("pr.updated", "review", %{
        "state" => "open",
        "number" => 194,
        "url" => "https://github.com/example/mobile/pull/194",
        "headSha" => String.duplicate("a", 40),
        "qualityCheck" => %{"name" => "factory/quality-gate", "status" => "pending"}
      })

    assert :ok = AgentBridge.report_factory_event(issue, "review-session", pr, second_name)

    for expected_session <- ["review-session", "build-session"] do
      assert_receive {:restart_session_update,
                      %{
                        "id" => ^expected_session,
                        "input" => %{
                          "addedExternalUrls" => [
                            %{
                              "label" => "Pull Request",
                              "url" => "https://github.com/example/mobile/pull/194"
                            }
                          ]
                        }
                      }},
                     1_000
    end
  end

  test "plan and diff events use the factory schema" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      if payload["query"] =~ "SymphonyUpdateAgentSession" do
        send(test_pid, {:session_update, payload["variables"]})

        graphql_response("agentSessionUpdate", %{
          "success" => true,
          "agentSession" => %{"id" => payload["variables"]["id"]}
        })
      else
        send(test_pid, {:activity, payload["variables"]["input"]})

        graphql_response("agentActivityCreate", %{
          "success" => true,
          "agentActivity" => %{"id" => "activity-1"}
        })
      end
    end

    bridge_name = String.to_atom("factory_payload_bridge_#{System.unique_integer([:positive])}")
    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})
    issue = %Issue{id: "issue-1", identifier: "APP-1"}
    :ok = AgentBridge.register_phase_session(issue.id, "planning", "planning-session", bridge_name)
    :ok = AgentBridge.register_phase_session(issue.id, "build", "build-session", bridge_name)

    plan =
      factory_event("plan.updated", "planning", %{
        "summary" => "Implement the queue state.",
        "acceptanceCriteria" => ["Queue item appears", "Playback starts"]
      })

    assert :ok = AgentBridge.report_factory_event(issue, "planning-session", plan, bridge_name)

    assert_receive {:session_update,
                    %{
                      "input" => %{
                        "plan" => [
                          %{"content" => "Implement the queue state.", "status" => "completed"},
                          %{"content" => "Queue item appears", "status" => "pending"},
                          %{"content" => "Playback starts", "status" => "pending"}
                        ]
                      }
                    }},
                   1_000

    diff =
      factory_event("diff.updated", "build", %{
        "filesChanged" => 3,
        "insertions" => 18,
        "deletions" => 4,
        "commitShas" => [String.duplicate("a", 40)]
      })

    assert :ok = AgentBridge.report_factory_event(issue, "build-session", diff, bridge_name)

    assert_receive {:activity,
                    %{
                      "content" => %{
                        "type" => "action",
                        "action" => "Build recorded code changes",
                        "parameter" => "3 files",
                        "result" => result
                      }
                    }},
                   1_000

    assert result =~ "+18 -4 lines"
    assert result =~ String.duplicate("a", 40)
  end

  test "pull request links require a head SHA reported by the same issue" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      query = payload["query"]

      if query =~ "SymphonyCreateAgentActivity" do
        send(test_pid, {:activity, payload["variables"]["input"]})

        graphql_response("agentActivityCreate", %{
          "success" => true,
          "agentActivity" => %{"id" => "activity-1"}
        })
      else
        send(test_pid, {:unexpected_request, query})
        flunk("a mismatched PR head must not reach Linear")
      end
    end

    bridge_name = String.to_atom("factory_sha_bridge_#{System.unique_integer([:positive])}")
    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})
    issue = %Issue{id: "issue-1", identifier: "APP-1"}
    :ok = AgentBridge.register_phase_session(issue.id, "build", "build-session", bridge_name)
    :ok = AgentBridge.register_phase_session(issue.id, "review", "review-session", bridge_name)

    diff =
      factory_event("diff.updated", "build", %{
        "filesChanged" => 1,
        "insertions" => 4,
        "deletions" => 0,
        "commitShas" => [String.duplicate("a", 40)]
      })

    assert :ok = AgentBridge.report_factory_event(issue, "build-session", diff, bridge_name)
    assert_receive {:activity, _input}, 1_000

    pr =
      factory_event("pr.updated", "review", %{
        "state" => "open",
        "number" => 194,
        "url" => "https://github.com/example/mobile/pull/194",
        "headSha" => String.duplicate("b", 40),
        "qualityCheck" => %{"name" => "factory/quality-gate", "status" => "pending"}
      })

    assert {:error, :factory_pr_head_not_reported} =
             AgentBridge.report_factory_event(issue, "review-session", pr, bridge_name)

    refute_receive {:unexpected_request, _query}
  end

  test "local artifacts are bound to the issue workspace and uploaded through Linear" do
    workspace = Path.join(Config.local_workspace_root(), "artifact-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    bytes = Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL+XQAAAABJRU5ErkJggg==")
    path = Path.join(workspace, "after.png")
    File.write!(path, bytes)
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    test_pid = self()

    uploader = fn filename, content_type, uploaded_bytes, _opts ->
      send(test_pid, {:upload, filename, content_type, uploaded_bytes})
      {:ok, "https://uploads.linear.app/asset/after.png"}
    end

    event =
      factory_event("artifact.created", "qa", %{
        "artifact" =>
          artifact("image", "local_file", path, "After queue interaction")
          |> Map.merge(%{"byteSize" => byte_size(bytes), "sha256" => digest})
      })

    assert {:ok, uploaded_event} =
             Runner.prepare_event_for_test(event, workspace,
               linear_agent_client: uploader,
               image_decoder_executor: fn args, _cwd ->
                 immutable_path = List.last(args)
                 send(test_pid, {:decoded_path, immutable_path})
                 refute immutable_path == path
                 assert File.read!(immutable_path) == bytes
                 {"pixelWidth: 1\npixelHeight: 1\n", 0}
               end
             )

    assert_received {:upload, "after.png", "image/png", ^bytes}
    assert_received {:decoded_path, immutable_path}
    refute File.exists?(immutable_path)
    uploaded_artifact = get_in(uploaded_event, ["payload", "artifact"])
    assert uploaded_artifact["storage"] == "linear_attachment"
    assert uploaded_artifact["uri"] == "https://uploads.linear.app/asset/after.png"

    outside_path = Path.join(Path.dirname(workspace), "outside.png")
    File.write!(outside_path, bytes)

    traversal_event =
      put_in(event, ["payload", "artifact", "uri"], Path.join(workspace, "nested/../../outside.png"))

    assert {:error, :artifact_path_outside_workspace} =
             Runner.prepare_event_for_test(traversal_event, workspace, linear_agent_client: uploader)

    assert {:error, :artifact_byte_size_mismatch} =
             event
             |> put_in(["payload", "artifact", "byteSize"], byte_size(bytes) + 1)
             |> Runner.prepare_event_for_test(workspace, linear_agent_client: uploader)

    assert {:error, :artifact_sha256_mismatch} =
             event
             |> put_in(["payload", "artifact", "sha256"], String.duplicate("0", 64))
             |> Runner.prepare_event_for_test(workspace, linear_agent_client: uploader)

    foreign_url =
      factory_event("artifact.created", "qa", %{
        "artifact" => artifact("image", "remote_url", "https://proof.invalid/after.png", "Foreign proof")
      })

    assert {:error, {:artifact_url_host_not_allowed, "proof.invalid"}} =
             Runner.prepare_event_for_test(foreign_url, workspace)
  end

  test "QA completion stops at In Review and review feedback reopens In Progress" do
    test_pid = self()
    issue_state = start_supervised!({Agent, fn -> "Todo" end}, id: make_ref())

    request_fun = fn payload, _headers ->
      query = payload["query"]

      cond do
        query =~ "SymphonyCreateAgentActivity" ->
          graphql_response("agentActivityCreate", %{
            "success" => true,
            "agentActivity" => %{"id" => "activity-1"}
          })

        query =~ "SymphonyIssueState" ->
          current_state = Agent.get(issue_state, & &1)

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "id" => "issue-1",
                   "state" => %{"name" => current_state},
                   "team" => %{
                     "states" => %{
                       "nodes" => [
                         %{"id" => "state-progress", "name" => "In Progress"},
                         %{"id" => "state-review", "name" => "In Review"},
                         %{"id" => "state-done", "name" => "Done"}
                       ]
                     }
                   }
                 }
               }
             }
           }}

        query =~ "SymphonyUpdateIssueState" ->
          send(test_pid, {:transition, payload["variables"]})
          target = if payload["variables"]["stateId"] == "state-review", do: "In Review", else: "In Progress"
          Agent.update(issue_state, fn _current -> target end)

          graphql_response("issueUpdate", %{
            "success" => true,
            "issue" => %{"id" => "issue-1", "state" => %{"name" => target}}
          })

        query =~ "SymphonyUpdateAgentSession" ->
          graphql_response("agentSessionUpdate", %{
            "success" => true,
            "agentSession" => %{"id" => "qa-session"}
          })

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("factory_state_bridge_#{System.unique_integer([:positive])}")
    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})
    issue = %Issue{id: "issue-1", identifier: "APP-1", state: "Todo"}

    :ok =
      AgentBridge.accept_webhook(
        %{
          "action" => "created",
          "webhookId" => "factory-start",
          "oauthClientId" => "oauth-client",
          "appUserId" => "app-user",
          "agentSession" => %{"id" => "qa-session", "issueId" => "issue-1"}
        },
        bridge_name
      )

    assert :ok = AgentBridge.start_work(issue, bridge_name)
    assert_receive {:transition, %{"issueId" => "issue-1", "stateId" => "state-progress"}}, 1_000
    :ok = AgentBridge.register_phase_session(issue.id, "qa", "qa-session", bridge_name)

    completed =
      factory_event("phase.completed", "qa", %{
        "summary" => "All checks passed.",
        "branch" => "factory/app-1",
        "commitShas" => [String.duplicate("a", 40)]
      })

    assert :ok = AgentBridge.report_factory_event(issue, "qa-session", completed, bridge_name)
    refute_receive {:transition, _}, 100

    merged_without_quality =
      factory_event("pr.updated", "qa", %{
        "state" => "merged",
        "number" => 42,
        "url" => nil,
        "headSha" => String.duplicate("a", 40),
        "qualityCheck" => %{"name" => "other-check", "status" => "passed"}
      })

    assert :ok =
             AgentBridge.report_factory_event(
               issue,
               "qa-session",
               merged_without_quality,
               bridge_name
             )

    refute_receive {:transition, _}, 100

    merged_with_failed_quality =
      factory_event("pr.updated", "qa", %{
        "state" => "merged",
        "number" => 42,
        "url" => nil,
        "headSha" => String.duplicate("a", 40),
        "qualityCheck" => %{"name" => "factory/quality-gate", "status" => "failed"}
      })

    assert :ok =
             AgentBridge.report_factory_event(
               issue,
               "qa-session",
               merged_with_failed_quality,
               bridge_name
             )

    refute_receive {:transition, _}, 100

    merged_with_quality =
      factory_event("pr.updated", "qa", %{
        "state" => "merged",
        "number" => 42,
        "url" => nil,
        "headSha" => String.duplicate("a", 40),
        "qualityCheck" => %{"name" => "factory/quality-gate", "status" => "passed"}
      })

    assert :ok =
             AgentBridge.report_factory_event(issue, "qa-session", merged_with_quality, bridge_name)

    assert :ok = AgentBridge.complete_factory_lifecycle(issue, bridge_name)
    assert_receive {:transition, %{"issueId" => "issue-1", "stateId" => "state-review"}}, 1_000
    refute_receive {:transition, %{"stateId" => "state-done"}}, 100

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "prompted",
                 "webhookId" => "review-feedback-1",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "qa-session", "issueId" => "issue-1"},
                 "agentActivity" => %{
                   "id" => "feedback-1",
                   "content" => %{"body" => "Please adjust the empty state."}
                 }
               },
               bridge_name
             )

    assert_receive {:transition, %{"issueId" => "issue-1", "stateId" => "state-progress"}}, 1_000
    refute_receive {:transition, %{"stateId" => "state-done"}}, 100

    feedback = AgentBridge.checkout_factory_feedback(issue.id, bridge_name)

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "prompted",
                 "webhookId" => "review-feedback-2",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "qa-session", "issueId" => "issue-1"},
                 "agentActivity" => %{
                   "id" => "feedback-2",
                   "content" => %{"body" => "Also fix the loading transition."}
                 }
               },
               bridge_name
             )

    assert :ok = AgentBridge.complete_factory_lifecycle(issue, bridge_name)
    refute_receive {:transition, %{"stateId" => "state-review"}}, 100
    assert {:ok, true} = AgentBridge.acknowledge_factory_feedback(issue.id, feedback, bridge_name)
    refute_receive {:transition, %{"stateId" => "state-review"}}, 100

    final_feedback = AgentBridge.checkout_factory_feedback(issue.id, bridge_name)
    assert [%{id: "feedback-2"}] = final_feedback
    assert :ok = AgentBridge.complete_factory_lifecycle(issue, bridge_name)
    assert_receive {:transition, %{"stateId" => "state-review"}}, 1_000
    assert {:ok, false} = AgentBridge.acknowledge_factory_feedback(issue.id, final_feedback, bridge_name)

    # A crash after the durable completion marker may replay this transition.
    # Already In Review is an idempotent success and does not issue a mutation.
    assert :ok = AgentBridge.complete_factory_lifecycle(issue, bridge_name)
    refute_receive {:transition, %{"stateId" => "state-review"}}, 100

    Agent.update(issue_state, fn _current -> "Done" end)

    assert :ok =
             AgentBridge.report_factory_event(
               issue,
               "qa-session",
               factory_event("progress", "qa", %{"message" => "Late event."}),
               bridge_name
             )

    assert {:error, {:linear_agent_transition_forbidden, "issue-1"}} =
             AgentBridge.complete_factory_lifecycle(issue, bridge_name)

    refute_receive {:transition, %{"stateId" => "state-done"}}, 100
  end

  defp run_planning_events(events) do
    workspace =
      Path.join(
        Config.local_workspace_root(),
        "factory-terminal-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    executable = Path.join(workspace, "emit-planning-events")

    body =
      events
      |> Enum.map_join("", fn event -> "printf '%s\\n' '#{Jason.encode!(event)}'\n" end)

    File.write!(executable, "#!/bin/sh\n" <> body)
    File.chmod!(executable, 0o755)

    settings = %{
      Config.settings!().factory
      | command: executable,
        args: ["{{ phase }}"],
        state_root: workspace <> "-trusted-state"
    }

    Runner.run(%Issue{id: "issue-1", identifier: "APP-1"}, workspace,
      settings: settings,
      bridge: factory_bridge(),
      factory_run_id: @factory_run_id
    )
  end

  defp factory_bridge do
    fn
      :ensure_phase_session, [_issue, phase] -> {:ok, "session-#{phase}"}
      :register_phase_session, [_issue_id, _phase, _session_id] -> :ok
      :report_factory_event, [_issue, _session_id, _event] -> :ok
      :restore_factory_event, [_issue, _session_id, _event] -> :ok
      :restore_factory_lifecycle, [_issue, _facts] -> :ok
      :complete_factory_lifecycle, [_issue] -> :ok
    end
  end

  defp factory_event(type, phase, payload) do
    suffix = System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(12, "0")

    %{
      "protocolVersion" => 1,
      "eventId" => "00000000-0000-4000-8000-#{suffix}",
      "runId" => "10000000-0000-4000-8000-000000000001",
      "occurredAt" => "2026-08-31T20:00:00Z",
      "project" => "project",
      "issue" => "APP-1",
      "type" => type,
      "phase" => phase,
      "payload" => payload
    }
  end

  defp test_event_uuid(number) do
    "00000000-0000-4000-8000-" <> (number |> Integer.to_string() |> String.pad_leading(12, "0"))
  end

  defp artifact(kind, storage, uri, description) do
    base = %{
      "id" => "20000000-0000-4000-8000-000000000001",
      "kind" => kind,
      "storage" => storage,
      "uri" => uri,
      "mimeType" => if(kind == "image", do: "image/png", else: "video/mp4"),
      "byteSize" => 128,
      "sha256" => String.duplicate("b", 64),
      "capturedAt" => "2026-08-31T20:00:00Z",
      "commitSha" => String.duplicate("a", 40),
      "runId" => "10000000-0000-4000-8000-000000000001",
      "attempt" => 1,
      "bundleOrPackageId" => "com.example.factory.test",
      "deviceIdentity" => "ios-simulator:test-device",
      "issue" => "APP-1",
      "flow" => "feature-flow",
      "platform" => "ios",
      "relation" => "after",
      "description" => description
    }

    if kind == "image" do
      Map.merge(base, %{"width" => 1, "height" => 1})
    else
      Map.put(base, "durationMs", 2_000)
    end
  end

  defp graphql_response(field, value) do
    {:ok, %{status: 200, body: %{"data" => %{field => value}}}}
  end

  defp receive_activity_body_containing(text, attempts \\ 12)

  defp receive_activity_body_containing(text, attempts) when attempts > 0 do
    receive do
      {:activity, %{"content" => %{"body" => body}}} ->
        if body =~ text do
          body
        else
          receive_activity_body_containing(text, attempts - 1)
        end
    after
      1_000 -> flunk("did not receive activity body containing #{inspect(text)}")
    end
  end

  defp receive_activity_body_containing(text, 0) do
    flunk("did not receive activity body containing #{inspect(text)}")
  end
end
