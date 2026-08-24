defmodule SymphonyElixir.Claude.CLI do
  @moduledoc """
  Agent client for Claude Code's non-interactive JSONL interface.

  Each turn launches a fresh `claude -p` process in the issue workspace. The
  provider records Claude's native session ID and passes it to `--resume` on
  later turns; it does not emulate the Codex app-server protocol.
  """

  @behaviour SymphonyElixir.AgentClient

  require Logger

  alias SymphonyElixir.{AgentClient, Config, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @cancel_exit_statuses [130, 137, 143]

  @type session :: %{
          state: pid(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- AgentClient.validate_workspace_cwd(workspace, worker_host),
         {:ok, state} <-
           Agent.start_link(fn ->
             %{
               session_id: nil,
               active_owner: nil,
               active_port: nil,
               stop_requested: false,
               turn_number: 0
             }
           end) do
      {:ok,
       %{
         state: state,
         workspace: expanded_workspace,
         worker_host: worker_host
       }}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{state: state} = session, prompt, issue, opts \\ []) when is_binary(prompt) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    with {:ok, resume_session_id, turn_number} <- begin_turn(state),
         {:ok, port} <- start_port(session, prompt, resume_session_id),
         :ok <- register_active_port(state, port) do
      metadata = port_metadata(port, session.worker_host)

      stream_state = %{
        pending_line: "",
        session_id: resume_session_id,
        resumed: is_binary(resume_session_id),
        session_started?: false,
        terminal: nil,
        terminal_raw: nil,
        turn_number: turn_number
      }

      stream_state = maybe_emit_session_started(stream_state, on_message, metadata)

      outcome =
        try do
          await_turn(port, state, stream_state, on_message, metadata)
        after
          stop_port(port)
        end

      captured_session_id = outcome_session_id(outcome) || resume_session_id
      stop_requested? = finish_turn(state, captured_session_id)

      if stop_requested?, do: stop_state(state)

      finish_run_turn(outcome, issue, on_message, metadata)
    else
      {:error, :session_stopped} = error ->
        error

      {:error, :session_busy} = error ->
        error

      {:error, :turn_cancelled} ->
        reason = {:turn_cancelled, :session_stopped}
        stop_requested? = finish_turn(state, nil)
        if stop_requested?, do: stop_state(state)
        emit_message(on_message, :turn_cancelled, %{reason: reason}, %{agent_provider: :claude})
        {:error, reason}

      {:error, reason} ->
        finish_turn(state, nil)
        Logger.error("Claude session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{agent_provider: :claude})
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{state: state}) when is_pid(state) do
    if Process.alive?(state) do
      case request_stop(state) do
        {:active, owner, port} ->
          send(owner, {:claude_session_cancelled, state, port})
          stop_port(port)

        :idle ->
          stop_state(state)
      end
    end

    :ok
  end

  defp begin_turn(state) do
    owner = self()

    agent_call(state, fn current ->
      cond do
        current.stop_requested ->
          {{:error, :session_stopped}, current}

        is_pid(current.active_owner) ->
          {{:error, :session_busy}, current}

        true ->
          turn_number = current.turn_number + 1

          {{:ok, current.session_id, turn_number},
           %{
             current
             | active_owner: owner,
               active_port: nil,
               turn_number: turn_number
           }}
      end
    end)
  end

  defp register_active_port(state, port) do
    result =
      agent_call(state, fn current ->
        if current.stop_requested do
          {{:error, :turn_cancelled}, current}
        else
          {:ok, %{current | active_port: port}}
        end
      end)

    if result != :ok, do: stop_port(port)
    result
  end

  defp finish_turn(state, captured_session_id) do
    case agent_call(state, fn current ->
           next_session_id = captured_session_id || current.session_id

           {current.stop_requested,
            %{
              current
              | session_id: next_session_id,
                active_owner: nil,
                active_port: nil
            }}
         end) do
      stop_requested when is_boolean(stop_requested) -> stop_requested
      {:error, :session_stopped} -> true
    end
  end

  defp request_stop(state) do
    agent_call(state, fn current ->
      result =
        case {current.active_owner, current.active_port} do
          {owner, port} when is_pid(owner) and is_port(port) -> {:active, owner, port}
          {owner, nil} when is_pid(owner) -> {:active, owner, nil}
          _ -> :idle
        end

      {result, %{current | stop_requested: true}}
    end)
  end

  defp agent_call(state, callback) do
    Agent.get_and_update(state, callback)
  catch
    :exit, _reason -> {:error, :session_stopped}
  end

  defp stop_state(state) do
    if Process.alive?(state) do
      Agent.stop(state, :normal)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp start_port(%{workspace: workspace, worker_host: nil}, prompt, resume_session_id) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(local_launch_command(prompt, resume_session_id))],
              cd: String.to_charlist(workspace),
              env: tracker_secret_port_env(),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp start_port(
         %{workspace: workspace, worker_host: worker_host},
         prompt,
         resume_session_id
       )
       when is_binary(worker_host) do
    workspace
    |> remote_launch_command(prompt, resume_session_id)
    |> then(&SSH.start_port(worker_host, &1, line: @port_line_bytes))
  end

  defp local_launch_command(prompt, resume_session_id) do
    [
      tracker_secret_unset_command(),
      claude_launch_command(prompt, resume_session_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, prompt, resume_session_id) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(),
      claude_launch_command(prompt, resume_session_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp claude_launch_command(prompt, resume_session_id) do
    args =
      ["-p", "--output-format", "stream-json", "--verbose"] ++
        resume_args(resume_session_id) ++ [prompt]

    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    "exec #{Config.settings!().claude.command} #{escaped_args}"
  end

  defp resume_args(session_id) when is_binary(session_id), do: ["--resume", session_id]
  defp resume_args(_session_id), do: []

  defp tracker_secret_port_env do
    Config.settings!().tracker.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command do
    case Config.settings!().tracker.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp await_turn(port, state, stream_state, on_message, metadata) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        next_stream_state =
          stream_state
          |> Map.update!(:pending_line, &(&1 <> to_string(chunk)))
          |> handle_line(on_message, metadata)

        await_turn(port, state, next_stream_state, on_message, metadata)

      {^port, {:data, {:noeol, chunk}}} ->
        next_stream_state =
          Map.update!(stream_state, :pending_line, &(&1 <> to_string(chunk)))

        await_turn(port, state, next_stream_state, on_message, metadata)

      {^port, {:exit_status, status}} ->
        stream_state
        |> handle_pending_line(on_message, metadata)
        |> outcome_for_exit(status)

      {:claude_session_cancelled, ^state, ^port} ->
        {:error, {:turn_cancelled, :session_stopped}, stream_state.session_id}
    after
      Config.settings!().claude.turn_timeout_ms ->
        {:error, :turn_timeout, stream_state.session_id}
    end
  end

  defp handle_pending_line(%{pending_line: ""} = stream_state, _on_message, _metadata),
    do: stream_state

  defp handle_pending_line(stream_state, on_message, metadata) do
    handle_line(stream_state, on_message, metadata)
  end

  defp handle_line(stream_state, on_message, metadata) do
    raw = stream_state.pending_line
    stream_state = %{stream_state | pending_line: ""}

    case Jason.decode(raw) do
      {:ok, %{} = payload} ->
        stream_state = capture_session_id(stream_state, payload)
        stream_state = maybe_emit_session_started(stream_state, on_message, metadata)

        case terminal_result(payload) do
          nil ->
            emit_message(
              on_message,
              :notification,
              %{payload: payload, raw: raw},
              metadata_from_payload(metadata, payload)
            )

            stream_state

          terminal ->
            %{stream_state | terminal: terminal, terminal_raw: raw}
        end

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: raw},
          metadata
        )

        stream_state

      {:error, _reason} ->
        log_non_json_stream_line(raw)

        if protocol_message_candidate?(raw) do
          emit_message(on_message, :malformed, %{payload: raw, raw: raw}, metadata)
        end

        stream_state
    end
  end

  defp capture_session_id(stream_state, %{"session_id" => session_id})
       when is_binary(session_id) and session_id != "" do
    %{stream_state | session_id: session_id}
  end

  defp capture_session_id(stream_state, _payload), do: stream_state

  defp maybe_emit_session_started(
         %{session_started?: false, session_id: session_id} = stream_state,
         on_message,
         metadata
       )
       when is_binary(session_id) do
    emit_message(
      on_message,
      :session_started,
      %{
        session_id: session_id,
        resumed: stream_state.resumed,
        turn_number: stream_state.turn_number
      },
      metadata
    )

    %{stream_state | session_started?: true}
  end

  defp maybe_emit_session_started(stream_state, _on_message, _metadata), do: stream_state

  defp terminal_result(%{"type" => "result"} = payload) do
    cond do
      permission_denied?(payload) -> {:approval_required, payload}
      cancellation_result?(payload) -> {:turn_cancelled, payload}
      successful_result?(payload) -> {:turn_completed, payload}
      true -> {:turn_failed, payload}
    end
  end

  defp terminal_result(_payload), do: nil

  defp permission_denied?(payload) do
    case Map.get(payload, "permission_denials") do
      denials when is_list(denials) -> denials != []
      _ -> false
    end
  end

  defp cancellation_result?(payload) do
    subtype = Map.get(payload, "subtype", "") |> to_string() |> String.downcase()
    result = Map.get(payload, "result", "") |> to_string() |> String.downcase()
    error_result? = Map.get(payload, "is_error") == true or subtype not in ["", "success"]

    error_result? and
      (String.contains?(subtype, ["cancelled", "canceled"]) or
         String.contains?(result, ["cancelled", "canceled"]))
  end

  defp successful_result?(payload) do
    Map.get(payload, "subtype") == "success" or Map.get(payload, "is_error") == false
  end

  defp outcome_for_exit(%{terminal: {:approval_required, payload}} = state, _status) do
    {:error, {:approval_required, payload}, state.session_id}
  end

  defp outcome_for_exit(%{terminal: {:turn_cancelled, payload}} = state, _status) do
    {:error, {:turn_cancelled, payload}, state.session_id}
  end

  defp outcome_for_exit(%{terminal: {:turn_failed, payload}} = state, status) do
    {:error, {:turn_failed, Map.put(payload, "exit_status", status)}, state.session_id}
  end

  defp outcome_for_exit(%{terminal: {:turn_completed, _payload}, session_id: nil}, 0) do
    {:startup_error, :missing_session_id, nil}
  end

  defp outcome_for_exit(%{terminal: {:turn_completed, payload}} = state, 0) do
    {:ok, payload, state.terminal_raw, state.session_id}
  end

  defp outcome_for_exit(%{terminal: {:turn_completed, payload}} = state, status) do
    {:error, {:turn_failed, %{"result" => payload, "exit_status" => status}}, state.session_id}
  end

  defp outcome_for_exit(state, status) when status in @cancel_exit_statuses do
    {:error, {:turn_cancelled, {:port_exit, status}}, state.session_id}
  end

  defp outcome_for_exit(%{session_id: nil}, status) do
    {:startup_error, {:port_exit, status}, nil}
  end

  defp outcome_for_exit(state, status) do
    reason =
      if status == 0 do
        :missing_result
      else
        {:port_exit, status}
      end

    {:error, {:turn_failed, reason}, state.session_id}
  end

  defp finish_run_turn({:ok, payload, raw, session_id}, issue, on_message, metadata) do
    Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(
      on_message,
      :turn_completed,
      %{payload: payload, raw: raw, details: payload},
      metadata_from_payload(metadata, payload)
    )

    {:ok, %{result: payload, session_id: session_id}}
  end

  defp finish_run_turn({:startup_error, reason, _session_id}, issue, on_message, metadata) do
    Logger.error("Claude session failed for #{issue_context(issue)}: #{inspect(reason)}")
    emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
    {:error, reason}
  end

  defp finish_run_turn({:error, reason, session_id}, issue, on_message, metadata) do
    event = error_event(reason)
    payload = error_payload(reason)

    Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

    emit_message(
      on_message,
      event,
      %{session_id: session_id, reason: reason, payload: payload, details: payload},
      metadata_from_payload(metadata, payload)
    )

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: session_id, reason: reason},
      metadata
    )

    {:error, reason}
  end

  defp error_event({:approval_required, _payload}), do: :approval_required
  defp error_event({:turn_cancelled, _payload}), do: :turn_cancelled
  defp error_event(_reason), do: :turn_failed

  defp error_payload({_kind, payload}) when is_map(payload), do: payload
  defp error_payload(reason), do: %{"reason" => inspect(reason)}

  defp outcome_session_id({:ok, _payload, _raw, session_id}), do: session_id
  defp outcome_session_id({_kind, _reason, session_id}), do: session_id

  defp port_metadata(port, worker_host) do
    metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{
            agent_process_pid: to_string(os_pid),
            agent_provider: :claude,
            claude_process_pid: to_string(os_pid)
          }

        _ ->
          %{agent_provider: :claude}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(metadata, :worker_host, host)
      _ -> metadata
    end
  end

  defp metadata_from_payload(metadata, payload) when is_map(payload) do
    metadata
    |> maybe_put_metadata(:usage, Map.get(payload, "usage"))
    |> maybe_put_metadata(:session_id, Map.get(payload, "session_id"))
  end

  defp metadata_from_payload(metadata, _payload), do: metadata

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp log_non_json_stream_line(data) do
    text = data |> to_string() |> String.trim() |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data |> to_string() |> String.trim_leading() |> String.starts_with?("{")
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp stop_port(_port), do: :ok

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp default_on_message(_message), do: :ok
end
