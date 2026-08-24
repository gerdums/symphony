defmodule SymphonyElixir.Linear.AgentClient do
  @moduledoc """
  Linear OAuth app client for native agent sessions, activities, and proof uploads.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.AgentCredentialStore

  @create_session_mutation """
  mutation SymphonyCreateAgentSession($input: AgentSessionCreateOnIssue!) {
    agentSessionCreateOnIssue(input: $input) {
      success
      agentSession { id url }
    }
  }
  """
  @find_session_query """
  query SymphonyFindAgentSession($issueId: String!, $first: Int!) {
    issue(id: $issueId) {
      agentSessions(first: $first) {
        nodes {
          id
          url
          status
          appUser { id }
        }
      }
    }
  }
  """
  @list_sessions_query """
  query SymphonyListAgentSessions($first: Int!, $after: String) {
    agentSessions(first: $first, after: $after, includeArchived: true) {
      nodes {
        id
        status
        appUser { id }
        issue {
          id
          project { id }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """
  @project_by_slug_query """
  query SymphonyFindAgentProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 2) {
      nodes { id }
    }
  }
  """
  @create_activity_mutation """
  mutation SymphonyCreateAgentActivity($input: AgentActivityCreateInput!) {
    agentActivityCreate(input: $input) {
      success
      agentActivity { id }
    }
  }
  """
  @update_session_mutation """
  mutation SymphonyUpdateAgentSession($id: String!, $input: AgentSessionUpdateInput!) {
    agentSessionUpdate(id: $id, input: $input) {
      success
      agentSession { id url }
    }
  }
  """
  @assign_issue_mutation """
  mutation SymphonyAssignIssue($issueId: String!, $delegateId: String!) {
    issueUpdate(id: $issueId, input: {delegateId: $delegateId}) {
      success
      issue { id delegate { id } }
    }
  }
  """
  @clear_issue_delegate_mutation """
  mutation SymphonyClearIssueDelegate($issueId: String!) {
    issueUpdate(id: $issueId, input: {delegateId: null}) {
      success
      issue { id delegate { id } }
    }
  }
  """
  @file_upload_mutation """
  mutation SymphonyPrepareProofUpload($filename: String!, $contentType: String!, $size: Int!) {
    fileUpload(filename: $filename, contentType: $contentType, size: $size, makePublic: false) {
      success
      uploadFile { uploadUrl assetUrl headers { key value } }
    }
  }
  """

  @session_page_size 50

  @spec create_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_session(issue_id, opts \\ []) when is_binary(issue_id) do
    input = %{"issueId" => issue_id}

    with {:ok, body} <- graphql(@create_session_mutation, %{"input" => input}, opts) do
      get_graphql_data(body, ["agentSessionCreateOnIssue", "agentSession"])
    end
  end

  @spec find_open_session(String.t(), String.t(), keyword()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def find_open_session(issue_id, app_user_id, opts \\ [])
      when is_binary(issue_id) and is_binary(app_user_id) do
    with {:ok, body} <-
           graphql(@find_session_query, %{"issueId" => issue_id, "first" => 20}, opts),
         sessions when is_list(sessions) <-
           get_in(body, ["data", "issue", "agentSessions", "nodes"]) do
      case Enum.find(sessions, &open_session_for_app?(&1, app_user_id)) do
        %{} = session -> {:ok, session}
        nil -> :not_found
      end
    else
      nil -> :not_found
      {:error, _reason} = error -> error
      other -> {:error, {:linear_agent_unknown_payload, other}}
    end
  end

  @spec list_open_sessions(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_open_sessions(app_user_id, project_slug, opts \\ [])
      when is_binary(app_user_id) and is_binary(project_slug) do
    with {:ok, project_id} <- resolve_project_id(project_slug, opts) do
      list_open_sessions_page(app_user_id, project_id, nil, [], opts)
    end
  end

  @spec create_activity(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_activity(agent_session_id, content, opts \\ [])
      when is_binary(agent_session_id) and is_map(content) do
    input = %{
      "agentSessionId" => agent_session_id,
      "content" => content,
      "ephemeral" => Keyword.get(opts, :ephemeral, false)
    }

    with {:ok, body} <- graphql(@create_activity_mutation, %{"input" => input}, opts) do
      get_graphql_data(body, ["agentActivityCreate", "agentActivity"])
    end
  end

  @spec update_session(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_session(agent_session_id, input, opts \\ [])
      when is_binary(agent_session_id) and is_map(input) do
    with {:ok, body} <-
           graphql(
             @update_session_mutation,
             %{"id" => agent_session_id, "input" => input},
             opts
           ) do
      get_graphql_data(body, ["agentSessionUpdate", "agentSession"])
    end
  end

  @spec assign_issue(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def assign_issue(issue_id, delegate_id, opts \\ [])
      when is_binary(issue_id) and is_binary(delegate_id) do
    variables = %{"issueId" => issue_id, "delegateId" => delegate_id}

    with {:ok, body} <- graphql(@assign_issue_mutation, variables, opts) do
      get_graphql_data(body, ["issueUpdate", "issue"])
    end
  end

  @spec clear_issue_delegate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def clear_issue_delegate(issue_id, opts \\ []) when is_binary(issue_id) do
    with {:ok, body} <- graphql(@clear_issue_delegate_mutation, %{"issueId" => issue_id}, opts) do
      get_graphql_data(body, ["issueUpdate", "issue"])
    end
  end

  @spec upload_file(String.t(), String.t(), binary(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def upload_file(filename, content_type, bytes, opts \\ [])
      when is_binary(filename) and is_binary(content_type) and is_binary(bytes) do
    variables = %{
      "filename" => filename,
      "contentType" => content_type,
      "size" => byte_size(bytes)
    }

    with {:ok, body} <- graphql(@file_upload_mutation, variables, opts),
         {:ok, upload} <- get_graphql_data(body, ["fileUpload", "uploadFile"]),
         {:ok, upload_url, asset_url, headers} <- normalize_upload(upload),
         {:ok, %{status: status}} when status in 200..299 <-
           upload_request(opts).(upload_url, headers, bytes) do
      {:ok, asset_url}
    else
      {:ok, %{status: status}} -> {:error, {:linear_upload_status, status}}
      {:error, _reason} = error -> error
      other -> {:error, {:linear_upload_response, other}}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables, opts \\ []) when is_binary(query) and is_map(variables) do
    settings = agent_settings(opts)
    payload = %{"query" => query, "variables" => variables}

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        Req.post(settings.endpoint,
          headers: headers,
          json: request_payload,
          connect_options: [timeout: 30_000]
        )
      end)

    request_graphql(payload, settings, request_fun, opts, true)
  end

  defp agent_settings(opts) do
    Keyword.get_lazy(opts, :agent_settings, fn -> Config.settings!().linear_agent end)
  end

  defp request_graphql(payload, settings, request_fun, opts, retry_auth?) do
    with {:ok, headers} <- request_headers(settings, opts),
         {:ok, response} <- request_fun.(payload, headers) do
      handle_graphql_response(response, payload, settings, request_fun, opts, retry_auth?)
    end
  end

  defp handle_graphql_response(
         %{status: 401},
         payload,
         settings,
         request_fun,
         opts,
         true
       ) do
    credential_store = Keyword.get(opts, :credential_store, AgentCredentialStore)
    :ok = credential_store.invalidate()
    request_graphql(payload, settings, request_fun, opts, false)
  end

  defp handle_graphql_response(%{status: 200, body: body}, _payload, _settings, _request_fun, _opts, _retry_auth?) do
    with :ok <- reject_graphql_errors(body), do: {:ok, body}
  end

  defp handle_graphql_response(%{status: status}, _payload, _settings, _request_fun, _opts, _retry_auth?),
    do: {:error, {:linear_agent_api_status, status}}

  defp handle_graphql_response(other, _payload, _settings, _request_fun, _opts, _retry_auth?),
    do: {:error, {:linear_agent_api_response, other}}

  defp request_headers(settings, opts) do
    credential_store = Keyword.get(opts, :credential_store, AgentCredentialStore)

    with {:ok, token} <- credential_store.token(settings) do
      {:ok,
       [
         {"Authorization", "Bearer " <> token},
         {"Content-Type", "application/json"}
       ]}
    end
  end

  defp reject_graphql_errors(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: {:error, {:linear_agent_graphql_errors, errors}}

  defp reject_graphql_errors(_body), do: :ok

  defp get_graphql_data(body, path) do
    case get_in(body, ["data" | path]) do
      %{} = value -> {:ok, value}
      _ -> {:error, {:linear_agent_unknown_payload, path}}
    end
  end

  defp resolve_project_id(project_slug, opts) do
    with {:ok, body} <- graphql(@project_by_slug_query, %{"projectSlug" => project_slug}, opts) do
      case get_in(body, ["data", "projects", "nodes"]) do
        [%{"id" => project_id}] when is_binary(project_id) -> {:ok, project_id}
        [] -> {:error, :linear_agent_project_not_found}
        nodes when is_list(nodes) -> {:error, {:linear_agent_ambiguous_project, length(nodes)}}
        other -> {:error, {:linear_agent_unknown_payload, other}}
      end
    end
  end

  defp list_open_sessions_page(app_user_id, project_id, after_cursor, acc, opts) do
    variables = %{"first" => @session_page_size, "after" => after_cursor}

    with {:ok, body} <- graphql(@list_sessions_query, variables, opts),
         %{"nodes" => nodes, "pageInfo" => page_info} when is_list(nodes) <-
           get_in(body, ["data", "agentSessions"]) do
      matching_sessions =
        Enum.filter(nodes, fn session ->
          open_session_for_app?(session, app_user_id) and
            get_in(session, ["issue", "project", "id"]) == project_id and
            is_binary(get_in(session, ["issue", "id"]))
        end)

      updated_acc = acc ++ matching_sessions

      case page_info do
        %{"hasNextPage" => true, "endCursor" => end_cursor} when is_binary(end_cursor) ->
          list_open_sessions_page(app_user_id, project_id, end_cursor, updated_acc, opts)

        _ ->
          {:ok, updated_acc}
      end
    else
      {:error, _reason} = error -> error
      other -> {:error, {:linear_agent_unknown_payload, other}}
    end
  end

  defp open_session_for_app?(
         %{"appUser" => %{"id" => app_user_id}, "status" => status},
         app_user_id
       ) do
    status != "complete"
  end

  defp open_session_for_app?(_session, _app_user_id), do: false

  defp normalize_upload(%{
         "uploadUrl" => upload_url,
         "assetUrl" => asset_url,
         "headers" => headers
       })
       when is_binary(upload_url) and is_binary(asset_url) and is_list(headers) do
    normalized_headers =
      Enum.flat_map(headers, fn
        %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
          [{key, value}]

        _ ->
          []
      end)

    {:ok, upload_url, asset_url, normalized_headers}
  end

  defp normalize_upload(_upload), do: {:error, :linear_agent_invalid_upload_payload}

  defp upload_request(opts) do
    Keyword.get(opts, :upload_request_fun, fn upload_url, headers, bytes ->
      Req.put(upload_url, headers: headers, body: bytes, connect_options: [timeout: 30_000])
    end)
  end
end
