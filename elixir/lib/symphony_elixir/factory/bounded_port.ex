defmodule SymphonyElixir.Factory.BoundedPort do
  @moduledoc false

  @kill_paths ["/bin/kill", "/usr/bin/kill"]
  @kill_timeout_ms 1_000

  @spec terminate(port()) :: :ok
  def terminate(port) when is_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 0 -> pid
        _missing -> nil
      end

    if os_pid, do: kill_os_process(os_pid)
    close_port(port)
    :ok
  end

  defp kill_os_process(os_pid) do
    case Enum.find(@kill_paths, &File.regular?/1) do
      nil -> :ok
      executable -> run_kill(executable, os_pid)
    end
  end

  defp run_kill(executable, os_pid) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, [~c"-KILL", Integer.to_charlist(os_pid)]},
          {:env, private_environment()}
        ]
      )

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @kill_timeout_ms -> close_port(port)
    end
  rescue
    _error -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp private_environment do
    System.get_env()
    |> Map.keys()
    |> Enum.map(&{String.to_charlist(&1), false})
  end
end
