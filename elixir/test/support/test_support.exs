defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_include_labels: [],
          tracker_exclude_labels: [],
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_include_local: false,
          worker_max_concurrent_agents_per_host: nil,
          linear_agent_enabled: false,
          linear_agent_assign_on_start: false,
          linear_agent_display_name: "Symphony Agent",
          linear_agent_endpoint: "https://api.linear.app/graphql",
          linear_agent_token_endpoint: "https://api.linear.app/oauth/token",
          linear_agent_access_token: nil,
          linear_agent_client_secret: nil,
          linear_agent_webhook_secret: nil,
          linear_agent_oauth_client_id: nil,
          linear_agent_app_user_id: nil,
          linear_agent_scopes: ["read", "write", "app:assignable", "app:mentionable"],
          linear_agent_webhook_max_age_ms: 60_000,
          linear_agent_proof_required: true,
          linear_agent_minimum_screenshots: 1,
          linear_agent_max_file_bytes: 10_485_760,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          setup_repair_attempts: 1,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          factory_enabled: false,
          factory_project_key: "project",
          factory_command: "factory",
          factory_args: [
            "run",
            "--project",
            "{{ tracker.project_slug }}",
            "--issue",
            "{{ issue.identifier }}",
            "--repository-path",
            "{{ workspace }}",
            "--phase",
            "{{ phase }}"
          ],
          factory_phases: ["planning", "build", "review", "qa"],
          factory_protocol_version: 1,
          factory_phase_timeout_ms: 3_600_000,
          factory_state_root: nil,
          factory_proof_url_hosts: ["uploads.linear.app"],
          factory_review_state: "In Review",
          factory_feedback_state: "In Progress",
          factory_review_from_states: ["In Progress"],
          factory_github_enabled: false,
          factory_github_repository: "example/mobile",
          factory_github_base_branch: "main",
          factory_github_required_check: "factory/quality-gate",
          factory_github_check_timeout_ms: 1_800_000,
          factory_github_check_poll_interval_ms: 10_000,
          factory_grooming_enabled: false,
          factory_grooming_args: [],
          factory_grooming_timeout_ms: 300_000,
          factory_grooming_backlog_state: "Backlog",
          factory_grooming_todo_state: "Todo",
          factory_post_merge_enabled: false,
          factory_post_merge_args: [],
          factory_post_merge_timeout_ms: 7_200_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_include_labels = Keyword.get(config, :tracker_include_labels)
    tracker_exclude_labels = Keyword.get(config, :tracker_exclude_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_include_local = Keyword.get(config, :worker_include_local)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    linear_agent_enabled = Keyword.get(config, :linear_agent_enabled)
    linear_agent_assign_on_start = Keyword.get(config, :linear_agent_assign_on_start)
    linear_agent_display_name = Keyword.get(config, :linear_agent_display_name)
    linear_agent_endpoint = Keyword.get(config, :linear_agent_endpoint)
    linear_agent_token_endpoint = Keyword.get(config, :linear_agent_token_endpoint)
    linear_agent_access_token = Keyword.get(config, :linear_agent_access_token)
    linear_agent_client_secret = Keyword.get(config, :linear_agent_client_secret)
    linear_agent_webhook_secret = Keyword.get(config, :linear_agent_webhook_secret)
    linear_agent_oauth_client_id = Keyword.get(config, :linear_agent_oauth_client_id)
    linear_agent_app_user_id = Keyword.get(config, :linear_agent_app_user_id)
    linear_agent_scopes = Keyword.get(config, :linear_agent_scopes)
    linear_agent_webhook_max_age_ms = Keyword.get(config, :linear_agent_webhook_max_age_ms)
    linear_agent_proof_required = Keyword.get(config, :linear_agent_proof_required)
    linear_agent_minimum_screenshots = Keyword.get(config, :linear_agent_minimum_screenshots)
    linear_agent_max_file_bytes = Keyword.get(config, :linear_agent_max_file_bytes)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    setup_repair_attempts = Keyword.get(config, :setup_repair_attempts)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    factory_enabled = Keyword.get(config, :factory_enabled)
    factory_project_key = Keyword.get(config, :factory_project_key)
    factory_command = Keyword.get(config, :factory_command)
    factory_args = Keyword.get(config, :factory_args)
    factory_phases = Keyword.get(config, :factory_phases)
    factory_protocol_version = Keyword.get(config, :factory_protocol_version)
    factory_phase_timeout_ms = Keyword.get(config, :factory_phase_timeout_ms)
    factory_state_root = Keyword.get(config, :factory_state_root)
    factory_proof_url_hosts = Keyword.get(config, :factory_proof_url_hosts)
    factory_review_state = Keyword.get(config, :factory_review_state)
    factory_feedback_state = Keyword.get(config, :factory_feedback_state)
    factory_review_from_states = Keyword.get(config, :factory_review_from_states)
    factory_github_enabled = Keyword.get(config, :factory_github_enabled)
    factory_github_repository = Keyword.get(config, :factory_github_repository)
    factory_github_base_branch = Keyword.get(config, :factory_github_base_branch)
    factory_github_required_check = Keyword.get(config, :factory_github_required_check)
    factory_github_check_timeout_ms = Keyword.get(config, :factory_github_check_timeout_ms)
    factory_github_check_poll_interval_ms = Keyword.get(config, :factory_github_check_poll_interval_ms)
    factory_grooming_enabled = Keyword.get(config, :factory_grooming_enabled)
    factory_grooming_args = Keyword.get(config, :factory_grooming_args)
    factory_grooming_timeout_ms = Keyword.get(config, :factory_grooming_timeout_ms)
    factory_grooming_backlog_state = Keyword.get(config, :factory_grooming_backlog_state)
    factory_grooming_todo_state = Keyword.get(config, :factory_grooming_todo_state)
    factory_post_merge_enabled = Keyword.get(config, :factory_post_merge_enabled)
    factory_post_merge_args = Keyword.get(config, :factory_post_merge_args)
    factory_post_merge_timeout_ms = Keyword.get(config, :factory_post_merge_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  include_labels: #{yaml_value(tracker_include_labels)}",
        "  exclude_labels: #{yaml_value(tracker_exclude_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_include_local, worker_max_concurrent_agents_per_host),
        linear_agent_yaml(%{
          enabled: linear_agent_enabled,
          assign_on_start: linear_agent_assign_on_start,
          display_name: linear_agent_display_name,
          endpoint: linear_agent_endpoint,
          token_endpoint: linear_agent_token_endpoint,
          access_token: linear_agent_access_token,
          client_secret: linear_agent_client_secret,
          webhook_secret: linear_agent_webhook_secret,
          oauth_client_id: linear_agent_oauth_client_id,
          app_user_id: linear_agent_app_user_id,
          scopes: linear_agent_scopes,
          webhook_max_age_ms: linear_agent_webhook_max_age_ms,
          proof_required: linear_agent_proof_required,
          minimum_screenshots: linear_agent_minimum_screenshots,
          max_file_bytes: linear_agent_max_file_bytes
        }),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  setup_repair_attempts: #{yaml_value(setup_repair_attempts)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "factory:",
        "  enabled: #{yaml_value(factory_enabled)}",
        "  project_key: #{yaml_value(factory_project_key)}",
        "  command: #{yaml_value(factory_command)}",
        "  args: #{yaml_value(factory_args)}",
        "  phases: #{yaml_value(factory_phases)}",
        "  protocol_version: #{yaml_value(factory_protocol_version)}",
        "  phase_timeout_ms: #{yaml_value(factory_phase_timeout_ms)}",
        "  state_root: #{yaml_value(factory_state_root)}",
        "  proof_url_hosts: #{yaml_value(factory_proof_url_hosts)}",
        "  review_state: #{yaml_value(factory_review_state)}",
        "  feedback_state: #{yaml_value(factory_feedback_state)}",
        "  review_from_states: #{yaml_value(factory_review_from_states)}",
        "  github:",
        "    enabled: #{yaml_value(factory_github_enabled)}",
        "    repository: #{yaml_value(factory_github_repository)}",
        "    base_branch: #{yaml_value(factory_github_base_branch)}",
        "    required_check: #{yaml_value(factory_github_required_check)}",
        "    check_timeout_ms: #{yaml_value(factory_github_check_timeout_ms)}",
        "    check_poll_interval_ms: #{yaml_value(factory_github_check_poll_interval_ms)}",
        "  grooming:",
        "    enabled: #{yaml_value(factory_grooming_enabled)}",
        "    args: #{yaml_value(factory_grooming_args)}",
        "    timeout_ms: #{yaml_value(factory_grooming_timeout_ms)}",
        "    backlog_state: #{yaml_value(factory_grooming_backlog_state)}",
        "    todo_state: #{yaml_value(factory_grooming_todo_state)}",
        "  post_merge:",
        "    enabled: #{yaml_value(factory_post_merge_enabled)}",
        "    args: #{yaml_value(factory_post_merge_args)}",
        "    timeout_ms: #{yaml_value(factory_post_merge_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, include_local, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and include_local == false and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, include_local, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      include_local && "  include_local: #{yaml_value(include_local)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp linear_agent_yaml(%{
         enabled: false,
         access_token: nil,
         client_secret: nil,
         webhook_secret: nil,
         oauth_client_id: nil,
         app_user_id: nil
       }),
       do: nil

  defp linear_agent_yaml(config) do
    [
      "linear_agent:",
      "  enabled: #{yaml_value(config.enabled)}",
      "  assign_on_start: #{yaml_value(config.assign_on_start)}",
      "  display_name: #{yaml_value(config.display_name)}",
      "  endpoint: #{yaml_value(config.endpoint)}",
      "  token_endpoint: #{yaml_value(config.token_endpoint)}",
      "  access_token: #{yaml_value(config.access_token)}",
      "  client_secret: #{yaml_value(config.client_secret)}",
      "  webhook_secret: #{yaml_value(config.webhook_secret)}",
      "  oauth_client_id: #{yaml_value(config.oauth_client_id)}",
      "  app_user_id: #{yaml_value(config.app_user_id)}",
      "  scopes: #{yaml_value(config.scopes)}",
      "  webhook_max_age_ms: #{yaml_value(config.webhook_max_age_ms)}",
      "  proof:",
      "    required: #{yaml_value(config.proof_required)}",
      "    minimum_screenshots: #{yaml_value(config.minimum_screenshots)}",
      "    max_file_bytes: #{yaml_value(config.max_file_bytes)}"
    ]
    |> Enum.reject(&String.ends_with?(&1, ": null"))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
