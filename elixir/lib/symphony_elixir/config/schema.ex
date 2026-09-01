defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false
  @linear_endpoint "https://api.linear.app/graphql"
  @linear_active_states ["Todo", "In Progress"]
  @linear_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string)
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:provider, :map, default: %{})
      field(:secret_environment_names, {:array, :string}, default: [])
      field(:required_labels, {:array, :string}, default: [])
      field(:include_labels, {:array, :string}, default: [])
      field(:exclude_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string})
      field(:terminal_states, {:array, :string})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :provider,
          :required_labels,
          :include_labels,
          :exclude_labels,
          :active_states,
          :terminal_states
        ],
        empty_values: []
      )
      |> update_change(:required_labels, &normalize_labels/1)
      |> update_change(:include_labels, &normalize_labels/1)
      |> update_change(:exclude_labels, &normalize_labels/1)
    end

    defp normalize_labels(labels) do
      labels
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.uniq()
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:include_local, :boolean, default: false)
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :include_local, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule LinearAgentProof do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:required, :boolean, default: true)
      field(:minimum_screenshots, :integer, default: 1)
      field(:max_file_bytes, :integer, default: 10_485_760)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:required, :minimum_screenshots, :max_file_bytes], empty_values: [])
      |> validate_number(:minimum_screenshots, greater_than_or_equal_to: 0)
      |> validate_number(:max_file_bytes, greater_than: 0)
    end
  end

  defmodule LinearAgent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.LinearAgentProof

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:assign_on_start, :boolean, default: false)
      field(:display_name, :string, default: "Symphony Agent")
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:token_endpoint, :string, default: "https://api.linear.app/oauth/token")
      field(:access_token, :string)
      field(:client_secret, :string)
      field(:webhook_secret, :string)
      field(:oauth_client_id, :string)
      field(:app_user_id, :string)
      field(:scopes, {:array, :string}, default: ["read", "write", "app:assignable", "app:mentionable"])
      field(:webhook_max_age_ms, :integer, default: 60_000)
      field(:secret_environment_names, {:array, :string}, default: [])
      embeds_one(:proof, LinearAgentProof, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :assign_on_start,
          :display_name,
          :endpoint,
          :token_endpoint,
          :access_token,
          :client_secret,
          :webhook_secret,
          :oauth_client_id,
          :app_user_id,
          :scopes,
          :webhook_max_age_ms
        ],
        empty_values: []
      )
      |> cast_embed(:proof, with: &LinearAgentProof.changeset/2)
      |> validate_required([:display_name, :endpoint, :token_endpoint, :scopes])
      |> validate_length(:scopes, min: 1)
      |> validate_number(:webhook_max_age_ms, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:setup_repair_attempts, :integer, default: 1)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :setup_repair_attempts,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:setup_repair_attempts, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 30_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_change(:command, fn :command, command ->
        if command != "" and String.trim(command) == "" do
          [command: "can't be blank"]
        else
          []
        end
      end)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Factory do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    defmodule GitHub do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:repository, :string)
        field(:base_branch, :string, default: "main")
        field(:required_check, :string, default: "factory/quality-gate")
        field(:check_timeout_ms, :integer, default: 1_800_000)
        field(:check_poll_interval_ms, :integer, default: 10_000)
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(
          attrs,
          [
            :enabled,
            :repository,
            :base_branch,
            :required_check,
            :check_timeout_ms,
            :check_poll_interval_ms
          ],
          empty_values: []
        )
        |> validate_required([:base_branch, :required_check])
        |> validate_format(:repository, ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, message: "must be owner/repository")
        |> validate_format(:base_branch, ~r/\A(?!production(?:\/|\z)|release(?:\/|\z)).+\z/i, message: "must not be a production or release branch")
        |> validate_inclusion(:required_check, ["factory/quality-gate"])
        |> validate_number(:check_timeout_ms, greater_than: 0)
        |> validate_number(:check_poll_interval_ms, greater_than: 0)
      end
    end

    defmodule CommandStage do
      @moduledoc false
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field(:enabled, :boolean, default: false)
        field(:args, {:array, :string}, default: [])
        field(:timeout_ms, :integer, default: 300_000)
        field(:backlog_state, :string, default: "Backlog")
        field(:todo_state, :string, default: "Todo")
      end

      @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:enabled, :args, :timeout_ms, :backlog_state, :todo_state], empty_values: [])
        |> validate_number(:timeout_ms, greater_than: 0)
        |> validate_change(:args, fn :args, args ->
          if Enum.all?(args, &(is_binary(&1) and &1 != "")), do: [], else: [args: "must contain nonblank strings"]
        end)
      end
    end

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:project_key, :string)
      field(:command, :string, default: "factory")

      field(:args, {:array, :string},
        default: [
          "run",
          "--project",
          "{{ tracker.project_slug }}",
          "--issue",
          "{{ issue.identifier }}",
          "--repository-path",
          "{{ workspace }}",
          "--phase",
          "{{ phase }}"
        ]
      )

      field(:phases, {:array, :string}, default: ["planning", "build", "review", "qa"])
      field(:protocol_version, :integer, default: 1)
      field(:phase_timeout_ms, :integer, default: 3_600_000)
      field(:state_root, :string)
      field(:proof_url_hosts, {:array, :string}, default: ["uploads.linear.app"])
      field(:review_state, :string, default: "In Review")
      field(:feedback_state, :string, default: "In Progress")
      field(:review_from_states, {:array, :string}, default: ["In Progress"])
      embeds_one(:github, GitHub, on_replace: :update, defaults_to_struct: true)
      embeds_one(:grooming, CommandStage, on_replace: :update, defaults_to_struct: true)
      embeds_one(:post_merge, CommandStage, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :project_key,
          :command,
          :args,
          :phases,
          :protocol_version,
          :phase_timeout_ms,
          :state_root,
          :proof_url_hosts,
          :review_state,
          :feedback_state,
          :review_from_states
        ],
        empty_values: []
      )
      |> validate_required([
        :command,
        :args,
        :phases,
        :proof_url_hosts,
        :review_state,
        :feedback_state,
        :review_from_states
      ])
      |> validate_length(:args, min: 1)
      |> validate_inclusion(:phases, [["planning", "build", "review", "qa"]], message: "must be planning, build, review, and qa in that order")
      |> validate_number(:protocol_version, equal_to: 1)
      |> validate_number(:phase_timeout_ms, greater_than: 0)
      |> validate_length(:proof_url_hosts, min: 1)
      |> validate_length(:review_from_states, min: 1)
      |> validate_change(:proof_url_hosts, &validate_host_allowlist/2)
      |> validate_change(:review_state, &validate_not_done/2)
      |> validate_change(:feedback_state, &validate_not_done/2)
      |> validate_change(:review_from_states, &validate_state_allowlist/2)
      |> cast_embed(:github, with: &GitHub.changeset/2)
      |> cast_embed(:grooming, with: &CommandStage.changeset/2)
      |> cast_embed(:post_merge, with: &CommandStage.changeset/2)
      |> validate_github_requires_factory()
      |> validate_repository_binding()
      |> validate_command_stages()
      |> validate_project_key()
    end

    defp validate_github_requires_factory(changeset) do
      github = get_field(changeset, :github)

      if github.enabled and !get_field(changeset, :enabled) do
        add_error(changeset, :github, "requires factory.enabled")
      else
        changeset
      end
    end

    defp validate_repository_binding(changeset) do
      github = get_field(changeset, :github)

      if github.enabled do
        case github do
          %{repository: repository} when is_binary(repository) and repository != "" -> changeset
          _github -> add_error(changeset, :github, "repository is required when factory.github.enabled")
        end
      else
        changeset
      end
    end

    defp validate_command_stages(changeset) do
      Enum.reduce([:grooming, :post_merge], changeset, fn field, current ->
        stage = get_field(current, field)

        if stage.enabled and stage.args == [] do
          add_error(current, field, "enabled command stage requires args")
        else
          current
        end
      end)
    end

    defp validate_project_key(changeset) do
      if get_field(changeset, :enabled) do
        case get_field(changeset, :project_key) do
          value when is_binary(value) and value != "" -> changeset
          _missing -> add_error(changeset, :project_key, "is required when factory.enabled")
        end
      else
        changeset
      end
    end

    defp validate_host_allowlist(:proof_url_hosts, hosts) do
      if Enum.all?(hosts, &(is_binary(&1) and Regex.match?(~r/\A(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/, &1))) do
        []
      else
        [proof_url_hosts: "must contain DNS host names only"]
      end
    end

    defp validate_not_done(field, state) do
      if String.downcase(String.trim(state)) == "done", do: [{field, "must not be Done"}], else: []
    end

    defp validate_state_allowlist(:review_from_states, states) do
      if Enum.all?(states, &(is_binary(&1) and String.trim(&1) != "" and String.downcase(String.trim(&1)) != "done")) do
        []
      else
        [review_from_states: "must contain nonblank, non-Done states"]
      end
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:linear_agent, LinearAgent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:factory, Factory, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          state_name |> to_string() |> String.trim() == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:linear_agent, with: &LinearAgent.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:factory, with: &Factory.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> validate_factory_requires_linear_agent()
  end

  defp validate_factory_requires_linear_agent(changeset) do
    factory = get_field(changeset, :factory)
    linear_agent = get_field(changeset, :linear_agent)

    if factory.enabled and !linear_agent.enabled do
      add_error(changeset, :factory, "factory.enabled requires linear_agent.enabled")
    else
      changeset
    end
  end

  defp finalize_settings(settings) do
    provider = normalize_optional_map(settings.tracker.provider) || %{}

    {api_key, assignee, provider, secret_environment_names} =
      case settings.tracker.kind do
        "linear" ->
          linear_provider =
            provider
            |> Map.put_new("endpoint", settings.tracker.endpoint || @linear_endpoint)
            |> Map.put_new("api_key", settings.tracker.api_key)
            |> Map.put_new("project_slug", settings.tracker.project_slug)
            |> Map.put_new("assignee", settings.tracker.assignee)

          resolved_api_key =
            resolve_secret_setting(linear_provider["api_key"], System.get_env("LINEAR_API_KEY"))

          resolved_assignee =
            resolve_secret_setting(linear_provider["assignee"], System.get_env("LINEAR_ASSIGNEE"))

          {
            resolved_api_key,
            resolved_assignee,
            linear_provider,
            ["LINEAR_API_KEY" | env_reference_names([linear_provider["api_key"]])]
          }

        _ ->
          {settings.tracker.api_key, settings.tracker.assignee, provider, []}
      end

    {active_states, terminal_states} =
      case settings.tracker.kind do
        kind when kind in ["linear", "memory"] ->
          {
            settings.tracker.active_states || @linear_active_states,
            settings.tracker.terminal_states || @linear_terminal_states
          }

        _ ->
          {settings.tracker.active_states, settings.tracker.terminal_states}
      end

    tracker = %{
      settings.tracker
      | endpoint: Map.get(provider, "endpoint", settings.tracker.endpoint),
        api_key: api_key,
        project_slug: Map.get(provider, "project_slug", settings.tracker.project_slug),
        assignee: assignee,
        provider: provider,
        secret_environment_names: Enum.uniq(secret_environment_names),
        active_states: active_states,
        terminal_states: terminal_states
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    worker = finalize_worker(settings.worker)

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    linear_agent = finalize_linear_agent(settings.linear_agent)

    factory = %{
      settings.factory
      | command:
          resolve_secret_setting(
            settings.factory.command,
            System.get_env("SYMPHONY_FACTORY_COMMAND")
          )
    }

    %{
      settings
      | tracker: tracker,
        workspace: workspace,
        worker: worker,
        codex: codex,
        linear_agent: linear_agent,
        factory: factory
    }
  end

  defp finalize_linear_agent(linear_agent) do
    display_name = resolve_secret_setting(linear_agent.display_name, System.get_env("LINEAR_AGENT_DISPLAY_NAME"))
    access_token = resolve_secret_setting(linear_agent.access_token, System.get_env("LINEAR_AGENT_ACCESS_TOKEN"))
    client_secret = resolve_secret_setting(linear_agent.client_secret, System.get_env("LINEAR_AGENT_CLIENT_SECRET"))
    webhook_secret = resolve_secret_setting(linear_agent.webhook_secret, System.get_env("LINEAR_AGENT_WEBHOOK_SECRET"))
    oauth_client_id = resolve_secret_setting(linear_agent.oauth_client_id, System.get_env("LINEAR_AGENT_OAUTH_CLIENT_ID"))
    app_user_id = resolve_secret_setting(linear_agent.app_user_id, System.get_env("LINEAR_AGENT_APP_USER_ID"))

    configured_values = [
      linear_agent.display_name,
      linear_agent.access_token,
      linear_agent.client_secret,
      linear_agent.webhook_secret,
      linear_agent.oauth_client_id,
      linear_agent.app_user_id
    ]

    %{
      linear_agent
      | enabled:
          resolve_boolean_setting(
            System.get_env("SYMPHONY_LINEAR_AGENT_ENABLED"),
            linear_agent.enabled
          ),
        assign_on_start:
          resolve_boolean_setting(
            System.get_env("SYMPHONY_LINEAR_AGENT_ASSIGN_ON_START"),
            linear_agent.assign_on_start
          ),
        display_name: display_name,
        access_token: access_token,
        client_secret: client_secret,
        webhook_secret: webhook_secret,
        oauth_client_id: oauth_client_id,
        app_user_id: app_user_id,
        secret_environment_names:
          Enum.uniq([
            "LINEAR_AGENT_ACCESS_TOKEN",
            "LINEAR_AGENT_CLIENT_SECRET",
            "LINEAR_AGENT_DISPLAY_NAME",
            "LINEAR_AGENT_WEBHOOK_SECRET",
            "LINEAR_AGENT_OAUTH_CLIENT_ID",
            "LINEAR_AGENT_APP_USER_ID"
            | env_reference_names(configured_values)
          ])
    }
  end

  defp finalize_worker(worker) do
    ssh_hosts =
      case normalize_secret_value(System.get_env("SYMPHONY_WORKER_SSH_HOSTS")) do
        nil ->
          worker.ssh_hosts

        value ->
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
      end

    include_local =
      resolve_boolean_setting(
        System.get_env("SYMPHONY_WORKER_INCLUDE_LOCAL"),
        worker.include_local
      )

    %{worker | ssh_hosts: ssh_hosts, include_local: include_local}
  end

  defp resolve_boolean_setting(value, fallback) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in ["1", "true", "yes", "on"] -> true
      value when value in ["0", "false", "no", "off"] -> false
      _ -> fallback
    end
  end

  defp resolve_boolean_setting(_value, fallback), do: fallback

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_secret_setting(value, _fallback), do: value

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp env_reference_names(values) when is_list(values) do
    Enum.flat_map(values, fn value ->
      case env_reference_name(value) do
        {:ok, env_name} -> [env_name]
        :error -> []
      end
    end)
  end

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
