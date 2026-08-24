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

  test "agent client clears the OAuth app delegate without changing the human assignee" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      send(test_pid, {:assignment_clear_request, payload})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issueUpdate" => %{
               "success" => true,
               "issue" => %{"id" => "issue-1", "delegate" => nil}
             }
           }
         }
       }}
    end

    assert {:ok, %{"delegate" => nil}} =
             AgentClient.clear_issue_delegate("issue-1", request_fun: request_fun)

    assert_received {:assignment_clear_request, payload}
    assert payload["variables"] == %{"issueId" => "issue-1"}
    refute payload["query"] =~ "assignee"
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

  test "agent client paginates open sessions for the configured app and project" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      if payload["query"] =~ "SymphonyFindAgentProject" do
        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"projects" => %{"nodes" => [%{"id" => "project-id"}]}}}
         }}
      else
        send(test_pid, {:session_page, payload["variables"]["after"]})

        nodes =
          case payload["variables"]["after"] do
            nil ->
              [
                %{
                  "id" => "session-page-1",
                  "status" => "active",
                  "appUser" => %{"id" => "app-user"},
                  "issue" => %{"id" => "issue-1", "project" => %{"id" => "project-id"}}
                },
                %{
                  "id" => "other-project",
                  "status" => "active",
                  "appUser" => %{"id" => "app-user"},
                  "issue" => %{"id" => "issue-other", "project" => %{"id" => "other"}}
                }
              ]

            "next-page" ->
              [
                %{
                  "id" => "session-page-2",
                  "status" => "active",
                  "appUser" => %{"id" => "app-user"},
                  "issue" => %{"id" => "issue-2", "project" => %{"id" => "project-id"}}
                },
                %{
                  "id" => "completed-session",
                  "status" => "complete",
                  "appUser" => %{"id" => "app-user"},
                  "issue" => %{"id" => "issue-complete", "project" => %{"id" => "project-id"}}
                }
              ]
          end

        page_info =
          if is_nil(payload["variables"]["after"]) do
            %{"hasNextPage" => true, "endCursor" => "next-page"}
          else
            %{"hasNextPage" => false, "endCursor" => nil}
          end

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "agentSessions" => %{"nodes" => nodes, "pageInfo" => page_info}
             }
           }
         }}
      end
    end

    assert {:ok, sessions} =
             AgentClient.list_open_sessions("app-user", "project", request_fun: request_fun)

    assert Enum.map(sessions, & &1["id"]) == ["session-page-1", "session-page-2"]
    assert_receive {:session_page, nil}
    assert_receive {:session_page, "next-page"}
  end

  test "agent client includes archived sessions so stale delegations can be reconciled" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      if payload["query"] =~ "SymphonyFindAgentProject" do
        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"projects" => %{"nodes" => [%{"id" => "project-id"}]}}}
         }}
      else
        send(test_pid, {:archived_session_query, payload["query"]})

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "agentSessions" => %{
                 "nodes" => [],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end
    end

    assert {:ok, []} =
             AgentClient.list_open_sessions("app-user", "project", request_fun: request_fun)

    assert_receive {:archived_session_query, query}
    assert query =~ "includeArchived: true"
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
          payload: %{
            "method" => "turn/plan/updated",
            "params" => %{
              "plan" => [
                %{"step" => "Implement", "status" => "inProgress"},
                %{"step" => "Validate", "status" => "pending"}
              ]
            }
          }
        },
        bridge_name
      )

    assert AgentBridge.session_for_issue("issue-1", bridge_name) == "session-1"

    assert_receive {:session_update,
                    %{
                      "id" => "session-1",
                      "input" => %{
                        "plan" => [
                          %{"content" => "Implement", "status" => "inProgress"},
                          %{"content" => "Validate", "status" => "pending"}
                        ]
                      }
                    }},
                   1_000

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
                         "type" => "response",
                         "body" => "The updated screen\n\n![The updated screen](https://uploads.linear.app/private-proof)"
                       }
                     }}

    assert_received {:activity, %{"content" => %{"type" => "response", "body" => "Done"}}}
  end

  test "bridge streams real app-server notifications into the native Linear session" do
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
                   "agentActivity" => %{"id" => "activity-stream"}
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
                   "agentSession" => %{"id" => "session-stream"}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_stream_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "created",
                 "webhookId" => "stream-webhook",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "session-stream", "issueId" => "issue-stream"}
               },
               bridge_name
             )

    assert :ok =
             AgentBridge.report_codex_update(
               "issue-stream",
               %{
                 event: :notification,
                 payload: %{
                   "method" => "item/started",
                   "params" => %{
                     "item" => %{"id" => "command-1", "type" => "commandExecution"}
                   }
                 }
               },
               bridge_name
             )

    assert_receive {:activity,
                    %{
                      "content" => %{
                        "type" => "action",
                        "action" => "Running command",
                        "parameter" => "Executing a workspace command"
                      },
                      "ephemeral" => false
                    }},
                   1_000

    assert :ok =
             AgentBridge.report_codex_update(
               "issue-stream",
               %{
                 event: :notification,
                 payload: %{
                   "method" => "item/completed",
                   "params" => %{
                     "item" => %{
                       "id" => "reasoning-1",
                       "type" => "reasoning",
                       "summary" => ["Checking the current implementation.", "Bearer private-value"]
                     }
                   }
                 }
               },
               bridge_name
             )

    assert_receive {:activity,
                    %{
                      "content" => %{
                        "type" => "thought",
                        "body" => "Checking the current implementation.\n\nBearer [REDACTED]"
                      },
                      "ephemeral" => false
                    }},
                   1_000

    assert :ok =
             AgentBridge.report_codex_update(
               "issue-stream",
               %{
                 event: :notification,
                 payload: %{
                   "method" => "item/completed",
                   "params" => %{
                     "item" => %{
                       "id" => "message-1",
                       "type" => "agentMessage",
                       "text" => "I updated the implementation and am validating it now."
                     }
                   }
                 }
               },
               bridge_name
             )

    assert_receive {:activity,
                    %{
                      "content" => %{
                        "type" => "response",
                        "body" => "I updated the implementation and am validating it now."
                      },
                      "ephemeral" => false
                    }},
                   1_000
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
    assert_receive {:session_update, %{"id" => "session-1", "input" => %{"plan" => [plan]}}}, 1_000
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

    assert_receive {:session_update,
                    %{
                      "id" => "session-waiting",
                      "input" => %{"plan" => [%{"content" => waiting_text}]}
                    }},
                   1_000

    assert waiting_text =~ "Waiting for an available worker slot"

    waiting_activities =
      receive_activities([])
      |> Enum.filter(&(get_in(&1, ["content", "body"]) =~ "waiting for an available worker slot"))

    assert length(waiting_activities) == 1

    assert :ok = AgentBridge.start_work(issue, bridge_name)

    assert_receive {:session_update,
                    %{
                      "id" => "session-waiting",
                      "input" => %{
                        "plan" => [
                          %{"content" => "Preparing the ticket workspace", "status" => "inProgress"}
                        ]
                      }
                    }},
                   1_000
  end

  test "bridge does not create a native session for an unadmitted queued ticket" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyFindAgentSession" ->
          send(test_pid, :existing_session_lookup)

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{"agentSessions" => %{"nodes" => []}}
               }
             }
           }}

        payload["query"] =~ "SymphonyCreateAgentSession" ->
          flunk("queued tickets without a native session must not create one")

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_existing_wait_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    issue = %Issue{id: "issue-not-admitted"}
    assert :ok = AgentBridge.waiting_for_existing_slot(issue, bridge_name)
    assert_receive :existing_session_lookup, 1_000
    assert AgentBridge.session_for_issue(issue.id, bridge_name) == nil

    assert :ok = AgentBridge.waiting_for_existing_slot(issue, bridge_name)
    refute_receive :existing_session_lookup, 100
  end

  test "bridge reconnects an existing native session after restart and marks it waiting" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyFindAgentSession" ->
          send(test_pid, :existing_session_lookup)

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "agentSessions" => %{
                     "nodes" => [
                       %{
                         "id" => "session-reconnected",
                         "status" => "active",
                         "appUser" => %{"id" => "app-user"}
                       }
                     ]
                   }
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
                   "agentSession" => %{"id" => "session-reconnected"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyCreateAgentActivity" ->
          send(test_pid, {:activity, payload["variables"]["input"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentActivityCreate" => %{
                   "success" => true,
                   "agentActivity" => %{"id" => "activity-reconnected"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyCreateAgentSession" ->
          flunk("recovery must reuse the existing native session")

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_reconnect_wait_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    issue = %Issue{id: "issue-reconnected"}
    assert :ok = AgentBridge.waiting_for_existing_slot(issue, bridge_name)
    assert_receive :existing_session_lookup, 1_000

    assert_receive {:session_update,
                    %{
                      "id" => "session-reconnected",
                      "input" => %{"plan" => [%{"content" => waiting_text}]}
                    }},
                   1_000

    assert waiting_text =~ "Waiting for an available worker slot"
    assert AgentBridge.session_for_issue(issue.id, bridge_name) == "session-reconnected"
  end

  test "bridge closes orphaned open sessions and reconnects eligible sessions after restart" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyFindAgentProject" ->
          {:ok,
           %{
             status: 200,
             body: %{"data" => %{"projects" => %{"nodes" => [%{"id" => "project-id"}]}}}
           }}

        payload["query"] =~ "SymphonyListAgentSessions" ->
          send(test_pid, :open_session_reconciliation)

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentSessions" => %{
                   "nodes" => [
                     %{
                       "id" => "session-eligible",
                       "status" => "active",
                       "appUser" => %{"id" => "app-user"},
                       "issue" => %{
                         "id" => "issue-eligible",
                         "project" => %{"id" => "project-id"}
                       }
                     },
                     %{
                       "id" => "session-orphaned",
                       "status" => "active",
                       "appUser" => %{"id" => "app-user"},
                       "issue" => %{
                         "id" => "issue-orphaned",
                         "project" => %{"id" => "project-id"}
                       }
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyCreateAgentActivity" ->
          send(test_pid, {:activity, payload["variables"]["input"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentActivityCreate" => %{
                   "success" => true,
                   "agentActivity" => %{"id" => "activity-orphaned"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyClearIssueDelegate" ->
          send(test_pid, {:delegate_cleared, payload["variables"]["issueId"]})

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issueUpdate" => %{
                   "success" => true,
                   "issue" => %{"id" => "issue-orphaned", "delegate" => nil}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_reconcile_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    assert :ok =
             AgentBridge.reconcile_open_sessions(
               [%Issue{id: "issue-eligible"}],
               bridge_name
             )

    assert_receive :open_session_reconciliation, 1_000

    assert_receive {:activity,
                    %{
                      "agentSessionId" => "session-orphaned",
                      "content" => %{"type" => "response", "body" => close_message},
                      "ephemeral" => false
                    }},
                   1_000

    assert close_message =~ "No worker is currently running"
    assert_receive {:delegate_cleared, "issue-orphaned"}, 1_000
    assert AgentBridge.session_for_issue("issue-eligible", bridge_name) == "session-eligible"

    assert :ok = AgentBridge.reconcile_open_sessions([], bridge_name)
    refute_receive :open_session_reconciliation, 100
  end

  test "bridge marks recoverable worker failures in the plan without an error activity" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      if payload["query"] =~ "SymphonyUpdateAgentSession" do
        send(test_pid, {:session_update, payload["variables"]})

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "agentSessionUpdate" => %{
                 "success" => true,
                 "agentSession" => %{"id" => "session-recovering"}
               }
             }
           }
         }}
      else
        flunk("recoverable worker failures must not create an error activity")
      end
    end

    bridge_name = String.to_atom("linear_agent_recovering_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    assert :ok =
             AgentBridge.accept_webhook(
               %{
                 "action" => "created",
                 "webhookId" => "recovering-webhook",
                 "oauthClientId" => "oauth-client",
                 "appUserId" => "app-user",
                 "agentSession" => %{"id" => "session-recovering", "issueId" => "issue-recovering"}
               },
               bridge_name
             )

    assert :ok = AgentBridge.recovering("issue-recovering", bridge_name)

    assert_receive {:session_update,
                    %{
                      "id" => "session-recovering",
                      "input" => %{
                        "plan" => [
                          %{
                            "content" => "Recovering the worker after a transient failure",
                            "status" => "inProgress"
                          }
                        ]
                      }
                    }},
                   1_000

    assert :ok =
             AgentBridge.report_codex_update(
               "issue-recovering",
               %{event: :turn_ended_with_error},
               bridge_name
             )

    assert_receive {:session_update,
                    %{
                      "id" => "session-recovering",
                      "input" => %{
                        "plan" => [
                          %{
                            "content" => "Recovering the worker after a transient failure",
                            "status" => "inProgress"
                          }
                        ]
                      }
                    }},
                   1_000
  end

  test "waiting session provisioning does not block bridge state reads" do
    test_pid = self()

    request_fun = fn payload, _headers ->
      cond do
        payload["query"] =~ "SymphonyFindAgentSession" ->
          send(test_pid, {:session_lookup_started, self()})

          receive do
            :continue_session_lookup -> :ok
          end

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "issue" => %{
                   "agentSessions" => %{
                     "nodes" => [
                       %{
                         "id" => "session-async",
                         "status" => "active",
                         "appUser" => %{"id" => "app-user"}
                       }
                     ]
                   }
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
                   "agentSession" => %{"id" => "session-async"}
                 }
               }
             }
           }}

        payload["query"] =~ "SymphonyCreateAgentActivity" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "agentActivityCreate" => %{
                   "success" => true,
                   "agentActivity" => %{"id" => "activity-async"}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected GraphQL operation")
      end
    end

    bridge_name = String.to_atom("linear_agent_async_waiting_bridge_#{System.unique_integer([:positive])}")

    start_supervised!({AgentBridge, name: bridge_name, orchestrator: nil, client_opts: [request_fun: request_fun]})

    issue = %Issue{id: "issue-async"}
    assert :ok = AgentBridge.waiting_for_slot(issue, bridge_name)
    assert_receive {:session_lookup_started, lookup_pid}, 1_000

    assert AgentBridge.session_for_issue(issue.id, bridge_name) == nil
    assert :ok = AgentBridge.waiting_for_slot(issue, bridge_name)
    refute_receive {:session_lookup_started, _pid}, 50

    send(lookup_pid, :continue_session_lookup)
    assert_receive {:session_update, %{"id" => "session-async"}}, 1_000
    assert AgentBridge.session_for_issue(issue.id, bridge_name) == "session-async"
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
