defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.ProofTool

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, binding, opts \\ []) do
    if tool in binding.linear_agent_tool_names do
      ProofTool.execute(tool, arguments, binding.linear_agent_settings, opts)
    else
      Tracker.execute_bound_agent_tool(
        binding,
        tool,
        arguments,
        Keyword.put(opts, :linear_agent_settings, binding.linear_agent_settings)
      )
    end
  end

  @spec bind() :: map()
  def bind do
    tracker_binding = Tracker.bind_agent_tools()
    linear_agent_settings = Config.settings!().linear_agent
    linear_agent_tool_specs = ProofTool.tool_specs(linear_agent_settings)

    Map.merge(tracker_binding, %{
      linear_agent_settings: linear_agent_settings,
      linear_agent_tool_names: Enum.map(linear_agent_tool_specs, & &1["name"]),
      tool_specs: tracker_binding.tool_specs ++ linear_agent_tool_specs,
      secret_environment_names:
        Enum.uniq(
          tracker_binding.secret_environment_names ++
            linear_agent_settings.secret_environment_names ++
            ["SYMPHONY_WORKER_SSH_HOSTS", "SYMPHONY_WORKER_INCLUDE_LOCAL"]
        )
    })
  end
end
