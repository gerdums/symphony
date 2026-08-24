defmodule SymphonyElixir.LinearAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.Linear.{
    AgentBridge,
    AgentClient,
    AgentCredentialStore,
    ProofTool,
    WebhookVerifier
  }

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_access_token: "oauth-token",
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    :ok
  end

  test "agent client authenticates as the OAuth app and creates a native session" do
    test_pid = self()

    request_fun = fn payload, headers ->
      send(test_pid, {:graphql_request, payload, headers})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "agentSessionCreateOnIssue" => %{
               "success" => true,
               "agentSession" => %{"id" => "session-1", "url" => "https://linear.app/session/1"}
             }
           }
         }
       }}
    end

    assert {:ok, %{"id" => "session-1"}} =
             AgentClient.create_session("issue-1", request_fun: request_fun)

    assert_received {:graphql_request, payload, headers}
    assert {"Authorization", "Bearer oauth-token"} in headers
    assert payload["variables"]["input"]["issueId"] == "issue-1"

    refute Map.has_key?(payload["variables"]["input"], "externalUrls")
  end

  test "agent client delegates an issue to the OAuth app user" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      send(test_pid, {:assignment_request, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{"id" => "issue-1", "delegate" => %{"id" => "app-user"}}
             }
           }
         }
       }}
    end

    assert {:ok, %{"delegate" => %{"id" => "app-user"}}} =
             AgentClient.assign_issue("issue-1", "app-user", request_fun: request_fun)

    assert_received {:assignment_request, payload}
    assert payload["variables"] == %{"issueId" => "issue-1", "delegateId" => "app-user"}
  end

  test "enabled config advertises proof and keeps all agent secrets out of the child environment" do
    binding = DynamicTool.bind()

    assert "linear_agent_proof" in binding.linear_agent_tool_names
    assert Enum.any?(binding.tool_specs, &(&1["name"] == "linear_agent_proof"))

    assert Enum.sort(binding.secret_environment_names) ==
             Enum.sort([
               "LINEAR_API_KEY",
               "LINEAR_AGENT_ACCESS_TOKEN",
               "LINEAR_AGENT_CLIENT_SECRET",
               "LINEAR_AGENT_DISPLAY_NAME",
               "LINEAR_AGENT_WEBHOOK_SECRET",
               "LINEAR_AGENT_OAUTH_CLIENT_ID",
               "LINEAR_AGENT_APP_USER_ID",
               "SYMPHONY_WORKER_SSH_HOSTS",
               "SYMPHONY_WORKER_INCLUDE_LOCAL"
             ])

    assert binding.linear_agent_settings.access_token == "oauth-token"
    assert binding.linear_agent_settings.proof.required
    assert binding.linear_agent_settings.proof.minimum_screenshots == 1
  end

  test "client credentials are cached, invalidated, and renewed without entering a worker" do
    test_pid = self()

    request_fun = fn endpoint, form ->
      send(test_pid, {:token_request, endpoint, form})

      {:ok,
       %{
         status: 200,
         body: %{
           "access_token" => "renewed-token",
           "expires_in" => 2_591_999,
           "scope" => "read write app:assignable app:mentionable"
         }
       }}
    end

    store_name = String.to_atom("linear_agent_credentials_#{System.unique_integer([:positive])}")
    start_supervised!({AgentCredentialStore, name: store_name, request_fun: request_fun})

    settings = %{
      access_token: nil,
      client_secret: "private-client-secret",
      oauth_client_id: "oauth-client",
      token_endpoint: "https://api.linear.app/oauth/token",
      scopes: ["read", "write", "app:assignable", "app:mentionable"]
    }

    assert {:ok, "renewed-token"} = AgentCredentialStore.token(settings, store_name)
    assert {:ok, "renewed-token"} = AgentCredentialStore.token(settings, store_name)

    assert_received {:token_request, "https://api.linear.app/oauth/token", form}
    assert form["grant_type"] == "client_credentials"
    assert form["client_id"] == "oauth-client"
    assert form["client_secret"] == "private-client-secret"
    assert form["scope"] == "read,write,app:assignable,app:mentionable"
    refute_received {:token_request, _, _}

    assert :ok = AgentCredentialStore.invalidate(store_name)
    assert {:ok, "renewed-token"} = AgentCredentialStore.token(settings, store_name)
    assert_received {:token_request, _, _}
  end

  test "enabled agent config accepts client credentials and requires one authentication method" do
    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_access_token: nil,
      linear_agent_client_secret: "private-client-secret",
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    assert :ok = Config.validate!()
    assert Config.settings!().linear_agent.client_secret == "private-client-secret"

    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_access_token: nil,
      linear_agent_client_secret: nil,
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    assert {:error, {:missing_linear_agent_setting, :access_token_or_client_secret}} =
             Config.validate!()
  end

  test "host-private environment can enable local plus remote worker routing" do
    previous_hosts = System.get_env("SYMPHONY_WORKER_SSH_HOSTS")
    previous_local = System.get_env("SYMPHONY_WORKER_INCLUDE_LOCAL")
    previous_assignment = System.get_env("SYMPHONY_LINEAR_AGENT_ASSIGN_ON_START")

    on_exit(fn ->
      restore_env("SYMPHONY_WORKER_SSH_HOSTS", previous_hosts)
      restore_env("SYMPHONY_WORKER_INCLUDE_LOCAL", previous_local)
      restore_env("SYMPHONY_LINEAR_AGENT_ASSIGN_ON_START", previous_assignment)
    end)

    System.put_env("SYMPHONY_WORKER_SSH_HOSTS", "remote-one, remote-two")
    System.put_env("SYMPHONY_WORKER_INCLUDE_LOCAL", "true")
    System.put_env("SYMPHONY_LINEAR_AGENT_ASSIGN_ON_START", "true")
    write_workflow_file!(Workflow.workflow_file_path())

    assert Config.settings!().worker.ssh_hosts == ["remote-one", "remote-two"]
    assert Config.settings!().worker.include_local
    assert Config.settings!().linear_agent.assign_on_start

    System.put_env("SYMPHONY_WORKER_INCLUDE_LOCAL", "false")
    write_workflow_file!(Workflow.workflow_file_path(), worker_include_local: true)
    refute Config.settings!().worker.include_local

    System.put_env("SYMPHONY_WORKER_INCLUDE_LOCAL", "not-a-boolean")
    System.put_env("SYMPHONY_LINEAR_AGENT_ASSIGN_ON_START", "not-a-boolean")
    write_workflow_file!(Workflow.workflow_file_path())
    refute Config.settings!().worker.include_local
    refute Config.settings!().linear_agent.assign_on_start
  end

  test "agent client recovers the app's open issue session after a restart" do
    request_fun = fn _payload, _headers ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issue" => %{
               "agentSessions" => %{
                 "nodes" => [
                   %{
                     "id" => "completed",
                     "status" => "complete",
                     "appUser" => %{"id" => "app-user"}
                   },
                   %{
                     "id" => "other-app",
                     "status" => "active",
                     "appUser" => %{"id" => "different"}
                   },
                   %{
                     "id" => "recovered",
                     "status" => "active",
                     "appUser" => %{"id" => "app-user"}
                   }
                 ]
               }
             }
           }
         }
       }}
    end

    assert {:ok, %{"id" => "recovered"}} =
             AgentClient.find_open_session("issue-1", "app-user", request_fun: request_fun)
  end

  test "agent client prepares a private upload and puts the exact bytes" do
    test_pid = self()
    bytes = <<1, 2, 3, 4>>

    request_fun = fn payload, _headers ->
      send(test_pid, {:upload_graphql, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "fileUpload" => %{
               "success" => true,
               "uploadFile" => %{
                 "uploadUrl" => "https://uploads.example.test/signed",
                 "assetUrl" => "https://uploads.linear.app/private-proof",
                 "headers" => [%{"key" => "content-type", "value" => "image/png"}]
               }
             }
           }
         }
       }}
    end

    upload_request_fun = fn url, headers, body ->
      send(test_pid, {:upload_put, url, headers, body})
      {:ok, %{status: 200}}
    end

    assert {:ok, "https://uploads.linear.app/private-proof"} =
             AgentClient.upload_file("proof.png", "image/png", bytes,
               request_fun: request_fun,
               upload_request_fun: upload_request_fun
             )

    assert_received {:upload_graphql, %{"variables" => variables}}
    assert variables == %{"contentType" => "image/png", "filename" => "proof.png", "size" => 4}

    assert_received {:upload_put, "https://uploads.example.test/signed", [{"content-type", "image/png"}], ^bytes}
  end

  test "webhook verifier checks the raw body HMAC and freshness" do
    timestamp = 1_777_777_777_000
    raw_body = Jason.encode!(%{"webhookTimestamp" => timestamp, "type" => "AgentSessionEvent"})
    signature = :crypto.mac(:hmac, :sha256, "webhook-secret", raw_body) |> Base.encode16(case: :lower)

    assert :ok =
             WebhookVerifier.verify(raw_body, signature, timestamp, now_ms: timestamp + 500)

    assert {:error, :invalid_linear_webhook} =
             WebhookVerifier.verify(raw_body <> " ", signature, timestamp, now_ms: timestamp + 500)

    assert {:error, :invalid_linear_webhook} =
             WebhookVerifier.verify(raw_body, signature, timestamp, now_ms: timestamp + 60_001)
  end

  test "bridge keeps prompts and proof on the same machine-independent session" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyCreateAgentActivity" ->
          send(test_pid, {:activity, payload["variables"]["input"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentActivityCreate" => %{
                   "success" => true,
                   "agentActivity" => %{"id" => "activity-1"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyUpdateAgentSession" ->
          send(test_pid, {:session_update, payload["variables"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentSessionUpdate" => %{
                   "success" => true,
                   "agentSession" => %{"id" => "session-1"}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    payload = %{
      "action" => "created",
      "webhookId" => "webhook-1",
      "oauthClientId" => "oauth-client",
      "appUserId" => "app-user",
      "promptContext" => "Please implement the acceptance criteria.",
      "agentSession" => %{"id" => "session-1", "issueId" => "issue-1"}
    }

    assert :ok = AgentBridge.accept_webhook(payload, bridge_name)
    assert AgentBridge.session_for_issue("issue-1", bridge_name) == "session-1"

    assert {:ok, %{body: "Please implement the acceptance criteria.", action: "created"}} =
             AgentBridge.take_prompt("issue-1", bridge_name)

    assert :empty = AgentBridge.take_prompt("issue-1", bridge_name)
    refute AgentBridge.proof_satisfied?("issue-1", bridge_name)

    :ok =
      AgentBridge.report_codex_update(
        "issue-1",
        %{
          event: :notification,
          details: %{
            payload: %{
              "method" => "turn/plan/updated",
              "params" => %{
                "plan" => [
                  %{"step" => "Implement", "status" => "inProgress"},
                  %{"step" => "Validate", "status" => "pending"}
                ]
              }
            }
          }
        },
        bridge_name
      )

    assert AgentBridge.session_for_issue("issue-1", bridge_name) == "session-1"

    assert_received {:session_update,
                     %{
                       "id" => "session-1",
                       "input" => %{
                         "plan" => [
                           %{"content" => "Implement", "status" => "inProgress"},
                           %{"content" => "Validate", "status" => "pending"}
                         ]
                       }
                     }}

    assert {:error, :proof_required} = AgentBridge.complete("issue-1", "Done", bridge_name)

    assert :ok =
             AgentBridge.record_proof(
               "issue-1",
               "https://uploads.linear.app/private-proof",
               "The updated screen",
               bridge_name
             )

    assert AgentBridge.proof_satisfied?("issue-1", bridge_name)
    assert :ok = AgentBridge.complete("issue-1", "Done", bridge_name)

    assert_received {:activity,
                     %{
                       "agentSessionId" => "session-1",
                       "content" => %{
                         "type" => "thought",
                         "body" => "Symphony Agent received this ticket and is preparing an agent."
                       }
                     }}

    assert_received {:activity,
                     %{
                       "content" => %{
                         "type" => "action",
                         "result" => "![The updated screen](https://uploads.linear.app/private-proof)"
                       }
                     }}

    assert_received {:activity, %{"content" => %{"type" => "response", "body" => "Done"}}}
  end

  test "bridge takes assignment only when work is ready to start" do
    write_workflow_file!(Workflow.workflow_file_path(),
      linear_agent_enabled: true,
      linear_agent_assign_on_start: true,
      linear_agent_access_token: "oauth-token",
      linear_agent_webhook_secret: "webhook-secret",
      linear_agent_oauth_client_id: "oauth-client",
      linear_agent_app_user_id: "app-user"
    )

    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyCreateAgentActivity" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentActivityCreate" => %{
                   "success" => true,
                   "agentActivity" => %{"id" => "activity-1"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyAssignIssue" ->
          send(test_pid, {:assignment_request, payload["variables"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issueUpdate" => %{
                   "success" => true,
                   "issue" => %{"id" => "issue-1", "delegate" => %{"id" => "app-user"}}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyUpdateAgentSession" ->
          send(test_pid, {:session_update, payload["variables"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentSessionUpdate" => %{
                   "success" => true,
                   "agentSession" => %{"id" => "session-1"}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_assignment_bridge_#{System.unique_integer([:positive])}")
    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "created",
                 "webhookId" => "assignment-webhook",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "session-1", "issueId" => "issue-1"}
               },
               bridge_name
             )

    assert AgentBridge.session_for_issue("issue-1", bridge_name) == "session-1"
    assert :ok = AgentBridge.start_work(%Issue{id: "issue-1"}, bridge_name)

    assert_received {:assignment_request, %{"issueId" => "issue-1", "delegateId" => "app-user"}}
    assert_received {:session_update, %{"id" => "session-1", "input" => %{"plan" => [plan]}}}
    assert plan["content"] == "Preparing the ticket workspace"
  end

  test "bridge keeps one native session visibly waiting until a worker slot opens" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyCreateAgentActivity" ->
          send(test_pid, {:activity, payload["variables"]["input"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentActivityCreate" => %{
                   "success" => true,
                   "agentActivity" => %{"id" => "activity-1"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyUpdateAgentSession" ->
          send(test_pid, {:session_update, payload["variables"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentSessionUpdate" => %{
                   "success" => true,
                   "agentSession" => %{"id" => "session-waiting"}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_waiting_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "created",
                 "webhookId" => "waiting-webhook",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "session-waiting", "issueId" => "issue-waiting"}
               },
               bridge_name
             )

    issue = %Issue{id: "issue-waiting"}
    assert :ok = AgentBridge.waiting_for_slot(issue, bridge_name)
    assert :ok = AgentBridge.waiting_for_slot(issue, bridge_name)
    assert AgentBridge.session_for_issue(issue.id, bridge_name) == "session-waiting"

    assert_received {:session_update,
                     %{
                       "id" => "session-waiting",
                       "input" => %{"plan" => [%{"content" => waiting_text}]}
                     }}

    assert waiting_text =~ "Waiting for an available worker slot"

    waiting_activities =
      receive_activities([])
      |> Enum.filter(&(get_in(&1, ["content", "body"]) =~ "waiting for an available worker slot"))

    assert length(waiting_activities) == 1

    assert :ok = AgentBridge.start_work(issue, bridge_name)

    assert_received {:session_update,
                     %{
                       "id" => "session-waiting",
                       "input" => %{
                         "plan" => [
                           %{"content" => "Preparing the ticket workspace", "status" => "inProgress"}
                         ]
                       }
                     }}
  end

  test "bridge publishes only one stop notification while a failed ticket retries" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      if payload["query"] =~ "SymphonyCreateAgentActivity" do
        send(test_pid, {:activity, payload["variables"]["input"]})

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "agentActivityCreate" => %{
                 "success" => true,
                 "agentActivity" => %{"id" => "activity-1"}
               }
             }
           }
         }}
      else
        flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_failure_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "created",
                 "webhookId" => "failure-webhook",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "session-failure", "issueId" => "issue-failure"}
               },
               bridge_name
             )

    assert :ok = AgentBridge.fail("issue-failure", "The worker stopped.", bridge_name)
    assert :ok = AgentBridge.fail("issue-failure", "The worker stopped again.", bridge_name)

    assert :ok =
             AgentBridge.report_codex_update(
               "issue-failure",
               %{event: :turn_ended_with_error},
               bridge_name
             )

    assert AgentBridge.session_for_issue("issue-failure", bridge_name) == "session-failure"

    errors =
      receive_activities([])
      |> Enum.filter(&(get_in(&1, ["content", "type"]) == "error"))

    assert [%{"content" => %{"body" => "The worker stopped."}}] = errors
  end

  test "proof tool only uploads an image contained in the current workspace" do
    workspace = Path.join(Config.local_workspace_root(), "proof-issue")
    File.mkdir_p!(workspace)
    screenshot = Path.join(workspace, "validation.png")
    File.write!(screenshot, <<137, 80, 78, 71>>)
    test_pid = self()

    upload = fn filename, content_type, bytes, _opts ->
      send(test_pid, {:proof_upload, filename, content_type, bytes})
      {:ok, "https://uploads.linear.app/proof"}
    end

    record = fn issue_id, asset_url, caption ->
      send(test_pid, {:proof_recorded, issue_id, asset_url, caption})
      :ok
    end

    settings = Config.settings!().linear_agent

    response =
      ProofTool.execute(
        "linear_agent_proof",
        %{"path" => screenshot, "caption" => "Validated behavior"},
        settings,
        workspace: workspace,
        worker_host: nil,
        issue_id: "issue-1",
        linear_agent_client: upload,
        linear_agent_bridge: record
      )

    assert response["success"] == true
    assert_received {:proof_upload, "validation.png", "image/png", <<137, 80, 78, 71>>}

    assert_received {:proof_recorded, "issue-1", "https://uploads.linear.app/proof", "Validated behavior"}

    outside = Path.join(Path.dirname(workspace), "outside.png")
    File.write!(outside, "not allowed")

    rejected =
      ProofTool.execute(
        "linear_agent_proof",
        %{"path" => outside, "caption" => "Should fail"},
        settings,
        workspace: workspace,
        worker_host: nil,
        issue_id: "issue-1",
        linear_agent_client: upload,
        linear_agent_bridge: record
      )

    assert rejected["success"] == false
    assert Jason.decode!(rejected["output"])["error"]["message"] =~ "inside the current workspace"
  end

  defp receive_activities(acc) do
    receive do
      {:activity, activity} -> receive_activities([activity | acc])
    after
      25 -> Enum.reverse(acc)
    end
  end
end
