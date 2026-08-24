defmodule SymphonyElixir.AgentClient do
  @moduledoc """
  Provider-neutral lifecycle for coding-agent sessions.

  Providers own their session representation and translate their native output
  into the orchestrator event maps accepted by `run_turn/4` callbacks.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @type session :: term()
  @type issue :: map()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), issue(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec provider_module() :: module()
  def provider_module do
    provider_module(Config.settings!().agent.provider)
  end

  @spec provider_module(String.t()) :: module()
  def provider_module("codex"), do: SymphonyElixir.Codex.AppServer
  def provider_module("claude"), do: SymphonyElixir.Claude.CLI

  @doc false
  @spec validate_workspace_cwd(Path.t(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, term()}
  def validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  def validate_workspace_cwd(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end
end
