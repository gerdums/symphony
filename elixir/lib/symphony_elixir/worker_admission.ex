defmodule SymphonyElixir.WorkerAdmission do
  @moduledoc """
  Reads the software-factory lifecycle contract before Symphony assigns new work.

  A missing state file preserves standalone Symphony behavior. Once a state file
  exists, only `active` admits new work. Existing agents are never interrupted.
  """

  alias SymphonyElixir.SSH

  @default_state_path "~/.local/state/software-factory/host-state.json"
  @missing_state ~s({"state":"active","reason":"state file absent"})

  @spec active?(String.t() | nil) :: boolean()
  def active?(host) do
    if enabled?(), do: governed_active?(host), else: true
  end

  defp governed_active?(nil) do
    state_path()
    |> Path.expand()
    |> File.read()
    |> decode_result()
  end

  defp governed_active?(host) when is_binary(host) do
    command =
      "if [ -f #{shell_escape(state_path())} ]; then cat #{shell_escape(state_path())}; " <>
        "else printf '%s' '#{@missing_state}'; fi"

    case SSH.run(host, command, stderr_to_stdout: true) do
      {:ok, {payload, 0}} -> decode(payload)
      _ -> false
    end
  end

  defp enabled? do
    System.get_env("SYMPHONY_FACTORY_ADMISSION_ENABLED") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp state_path do
    case System.get_env("SYMPHONY_FACTORY_STATE_PATH") do
      value when is_binary(value) and value != "" -> value
      _ -> @default_state_path
    end
  end

  defp decode_result({:ok, payload}), do: decode(payload)
  defp decode_result({:error, :enoent}), do: true
  defp decode_result({:error, _reason}), do: false

  defp decode(payload) do
    case Jason.decode(payload) do
      {:ok, %{"state" => "active"}} -> true
      _ -> false
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
