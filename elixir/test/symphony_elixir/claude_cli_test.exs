defmodule SymphonyElixir.ClaudeCLITest do
  use SymphonyElixir.TestSupport

  test "launches stream-json print turns and resumes the captured Claude session" do
    with_fake_claude("success", fn workspace, fake_claude, trace_file ->
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_provider: "claude",
        workspace_root: Path.dirname(workspace),
        claude_command: fake_claude
      )

      assert {:ok, session} = ClaudeCLI.start_session(workspace)
      issue = issue("CLAUDE-1")
      on_message = message_callback()

      assert {:ok, %{session_id: "claude-session-123"}} =
               ClaudeCLI.run_turn(session, "first prompt", issue, on_message: on_message)

      assert {:ok, %{session_id: "claude-session-123"}} =
               ClaudeCLI.run_turn(session, "continuation prompt", issue, on_message: on_message)

      assert :ok = ClaudeCLI.stop_session(session)

      trace = File.read!(trace_file)
      calls = String.split(trace, "CALL\n", trim: true)

      assert length(calls) == 2
      assert Enum.all?(calls, &String.match?(&1, ~r{CWD:.*/workspaces/CLAUDE}))
      assert Enum.all?(calls, &String.contains?(&1, "ARG:-p"))
      assert Enum.all?(calls, &String.contains?(&1, "ARG:--output-format"))
      assert Enum.all?(calls, &String.contains?(&1, "ARG:stream-json"))
      assert Enum.all?(calls, &String.contains?(&1, "ARG:--verbose"))
      refute Enum.at(calls, 0) =~ "ARG:--resume"
      assert Enum.at(calls, 1) =~ "ARG:--resume\nARG:claude-session-123"
      assert Enum.at(calls, 0) =~ "ARG:first prompt"
      assert Enum.at(calls, 1) =~ "ARG:continuation prompt"
      assert Enum.all?(calls, &String.contains?(&1, "LINEAR_API_KEY:unset"))

      assert_receive {:claude_event,
                      %{
                        event: :session_started,
                        session_id: "claude-session-123",
                        resumed: false,
                        agent_provider: :claude
                      }}

      assert_receive {:claude_event, %{event: :turn_completed, usage: usage}}
      assert usage == %{"input_tokens" => 12, "output_tokens" => 4}

      assert_receive {:claude_event,
                      %{
                        event: :session_started,
                        session_id: "claude-session-123",
                        resumed: true
                      }}

      assert_receive {:claude_event, %{event: :turn_completed}}
    end)
  end

  test "maps Claude permission denials into approval-required events" do
    with_fake_claude("permission", fn workspace, fake_claude, _trace_file ->
      configure_claude(workspace, fake_claude)
      assert {:ok, session} = ClaudeCLI.start_session(workspace)

      assert {:error, {:approval_required, payload}} =
               ClaudeCLI.run_turn(session, "needs permission", issue("CLAUDE-2"), on_message: message_callback())

      assert [%{"tool_name" => "Bash"}] = payload["permission_denials"]
      assert_receive {:claude_event, %{event: :approval_required, payload: ^payload}}
      assert_receive {:claude_event, %{event: :turn_ended_with_error}}
      assert :ok = ClaudeCLI.stop_session(session)
    end)
  end

  test "maps non-zero Claude exits after session startup into turn failures" do
    with_fake_claude("exit", fn workspace, fake_claude, _trace_file ->
      configure_claude(workspace, fake_claude)
      assert {:ok, session} = ClaudeCLI.start_session(workspace)

      assert {:error, {:turn_failed, {:port_exit, 9}}} =
               ClaudeCLI.run_turn(session, "fail", issue("CLAUDE-3"), on_message: message_callback())

      assert_receive {:claude_event, %{event: :turn_failed, reason: {:turn_failed, {:port_exit, 9}}}}

      assert_receive {:claude_event, %{event: :turn_ended_with_error}}
      assert :ok = ClaudeCLI.stop_session(session)
    end)
  end

  test "resets the Claude timeout on events and fails after stream silence" do
    with_fake_claude("active", fn workspace, fake_claude, _trace_file ->
      configure_claude(workspace, fake_claude, claude_turn_timeout_ms: 250)
      assert {:ok, session} = ClaudeCLI.start_session(workspace)

      assert {:ok, %{session_id: "claude-session-123"}} =
               ClaudeCLI.run_turn(session, "active", issue("CLAUDE-4"))

      assert :ok = ClaudeCLI.stop_session(session)
    end)

    with_fake_claude("silent", fn workspace, fake_claude, _trace_file ->
      configure_claude(workspace, fake_claude, claude_turn_timeout_ms: 80)
      assert {:ok, session} = ClaudeCLI.start_session(workspace)

      assert {:error, :turn_timeout} =
               ClaudeCLI.run_turn(session, "silent", issue("CLAUDE-5"), on_message: message_callback())

      assert_receive {:claude_event, %{event: :turn_failed, reason: :turn_timeout}}
      assert_receive {:claude_event, %{event: :turn_ended_with_error}}
      assert :ok = ClaudeCLI.stop_session(session)
    end)
  end

  test "stop_session cancels an active Claude turn" do
    with_fake_claude("cancel", fn workspace, fake_claude, _trace_file ->
      configure_claude(workspace, fake_claude)
      assert {:ok, session} = ClaudeCLI.start_session(workspace)
      parent = self()
      on_message = fn message -> send(parent, {:claude_event, message}) end

      task =
        Task.async(fn ->
          ClaudeCLI.run_turn(session, "wait", issue("CLAUDE-6"), on_message: on_message)
        end)

      assert_receive {:claude_event, %{event: :session_started}}, 1_000
      assert :ok = ClaudeCLI.stop_session(session)
      assert {:error, {:turn_cancelled, :session_stopped}} = Task.await(task, 1_000)
      assert_receive {:claude_event, %{event: :turn_cancelled}}
      assert_receive {:claude_event, %{event: :turn_ended_with_error}}
    end)
  end

  defp configure_claude(workspace, fake_claude, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          agent_provider: "claude",
          workspace_root: Path.dirname(workspace),
          claude_command: fake_claude
        ],
        overrides
      )
    )
  end

  defp with_fake_claude(mode, callback) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-cli-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "CLAUDE")
    fake_claude = Path.join(test_root, "claude")
    trace_file = Path.join(test_root, "claude.trace")
    previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")
    previous_mode = System.get_env("SYMP_TEST_CLAUDE_MODE")
    previous_linear_key = System.get_env("LINEAR_API_KEY")

    try do
      File.mkdir_p!(workspace)
      File.write!(fake_claude, fake_claude_script())
      File.chmod!(fake_claude, 0o755)
      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)
      System.put_env("SYMP_TEST_CLAUDE_MODE", mode)
      System.put_env("LINEAR_API_KEY", "must-not-reach-claude")
      callback.(workspace, fake_claude, trace_file)
    after
      restore_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
      restore_env("SYMP_TEST_CLAUDE_MODE", previous_mode)
      restore_env("LINEAR_API_KEY", previous_linear_key)
      File.rm_rf(test_root)
    end
  end

  defp fake_claude_script do
    """
    #!/bin/sh
    trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/symphony-claude.trace}"
    mode="${SYMP_TEST_CLAUDE_MODE:-success}"

    printf 'CALL\n' >> "$trace_file"
    printf 'CWD:%s\n' "$PWD" >> "$trace_file"
    printf 'LINEAR_API_KEY:%s\n' "${LINEAR_API_KEY:-unset}" >> "$trace_file"
    for arg in "$@"; do
      printf 'ARG:%s\n' "$arg" >> "$trace_file"
    done

    printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-session-123"}'

    case "$mode" in
      success)
        printf '%s\n' '{"type":"assistant","session_id":"claude-session-123","message":{"content":[{"type":"text","text":"working"}]}}'
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"claude-session-123","result":"done","usage":{"input_tokens":12,"output_tokens":4},"permission_denials":[]}'
        ;;
      permission)
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"claude-session-123","result":"blocked","permission_denials":[{"tool_name":"Bash"}]}'
        ;;
      exit)
        exit 9
        ;;
      active)
        sleep 0.05
        printf '%s\n' '{"type":"assistant","session_id":"claude-session-123","message":{"content":[{"type":"text","text":"still working"}]}}'
        sleep 0.05
        printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"claude-session-123","result":"done","permission_denials":[]}'
        ;;
      silent)
        sleep 1
        ;;
      cancel)
        sleep 5
        ;;
    esac

    exit 0
    """
  end

  defp issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Exercise Claude provider",
      description: "Use the fake Claude executable",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  defp message_callback do
    parent = self()
    fn message -> send(parent, {:claude_event, message}) end
  end
end
