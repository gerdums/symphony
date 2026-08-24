defmodule SymphonyElixir.Linear.ProofTool do
  @moduledoc """
  Dynamic tool that uploads screenshot proof into the active Linear agent session.
  """

  alias SymphonyElixir.Linear.{AgentBridge, AgentClient}
  alias SymphonyElixir.{PathSafety, SSH}

  @tool_name "linear_agent_proof"
  @allowed_content_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp"
  }
  @error_messages %{
    missing_proof_path: "`linear_agent_proof.path` is required.",
    missing_proof_caption: "`linear_agent_proof.caption` is required.",
    invalid_proof_arguments: "`linear_agent_proof` expects an object with `path` and `caption`.",
    proof_path_outside_workspace: "Screenshot proof must be inside the current workspace.",
    proof_file_not_found: "Screenshot proof file was not found.",
    proof_file_not_regular: "Screenshot proof path must point to a regular file.",
    proof_file_too_large: "Screenshot proof exceeds the configured file-size limit.",
    unsupported_proof_file_type: "Screenshot proof must be PNG, JPEG, or WebP.",
    missing_linear_agent_session: "No native Linear agent session is attached to this issue."
  }

  @spec tool_specs(map()) :: [map()]
  def tool_specs(%{enabled: true}) do
    [
      %{
        "name" => @tool_name,
        "description" => "Upload a screenshot from the current workspace as required proof in the native Linear agent session.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["path", "caption"],
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Absolute or workspace-relative path to a PNG, JPEG, or WebP screenshot."
            },
            "caption" => %{
              "type" => "string",
              "description" => "Concise explanation of what the screenshot proves."
            }
          }
        }
      }
    ]
  end

  def tool_specs(_settings), do: []

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(@tool_name, arguments, agent_settings, opts) do
    with {:ok, path, caption} <- normalize_arguments(arguments),
         {:ok, filename, content_type, bytes} <- read_screenshot(path, agent_settings, opts),
         {:ok, asset_url} <- upload_file(filename, content_type, bytes, agent_settings, opts),
         :ok <- record_proof(asset_url, caption, opts) do
      response(true, %{
        "proof" => %{
          "caption" => caption,
          "uploaded" => true
        }
      })
    else
      {:error, reason} -> response(false, error_payload(reason))
      :disabled -> response(false, error_payload(:missing_linear_agent_session))
    end
  end

  def execute(tool, _arguments, _agent_settings, _opts) do
    response(false, %{
      "error" => %{
        "message" => "Unsupported Linear agent tool: #{inspect(tool)}.",
        "supportedTools" => [@tool_name]
      }
    })
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    path = Map.get(arguments, "path") || Map.get(arguments, :path)
    caption = Map.get(arguments, "caption") || Map.get(arguments, :caption)

    with {:ok, path} <- present_string(path, :missing_proof_path),
         {:ok, caption} <- present_string(caption, :missing_proof_caption) do
      {:ok, path, caption}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_proof_arguments}

  defp present_string(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp present_string(_value, error), do: {:error, error}

  defp read_screenshot(path, agent_settings, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    worker_host = Keyword.get(opts, :worker_host)
    max_file_bytes = agent_settings.proof.max_file_bytes

    reader = Keyword.get(opts, :proof_file_reader, &default_read_file/4)
    reader.(workspace, worker_host, path, max_file_bytes)
  end

  defp default_read_file(workspace, nil, path, max_file_bytes) do
    with {:ok, workspace} <- PathSafety.canonicalize(workspace),
         candidate <- Path.expand(path, workspace),
         {:ok, resolved} <- PathSafety.canonicalize(candidate),
         :ok <- ensure_within_workspace(resolved, workspace),
         {:ok, stat} <- File.stat(resolved),
         :ok <- validate_stat(stat, max_file_bytes),
         {:ok, content_type} <- content_type(resolved),
         {:ok, bytes} <- File.read(resolved) do
      {:ok, Path.basename(resolved), content_type, bytes}
    else
      {:error, {:path_canonicalize_failed, _path, _reason}} -> {:error, :proof_file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_read_file(workspace, worker_host, path, max_file_bytes)
       when is_binary(worker_host) do
    candidate = Path.expand(path, workspace)

    with {:ok, content_type} <- content_type(candidate),
         {:ok, {encoded, 0}} <- SSH.run(worker_host, remote_read_command(workspace, candidate, max_file_bytes)),
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace) do
      {:ok, Path.basename(candidate), content_type, bytes}
    else
      {:ok, {_output, 42}} -> {:error, :proof_path_outside_workspace}
      {:ok, {_output, 43}} -> {:error, :proof_file_too_large}
      {:ok, {_output, _status}} -> {:error, :proof_file_not_found}
      {:error, _reason} = error -> error
      :error -> {:error, :invalid_remote_proof_file}
    end
  end

  defp ensure_within_workspace(path, workspace) do
    if path != workspace and String.starts_with?(path, workspace <> "/") do
      :ok
    else
      {:error, :proof_path_outside_workspace}
    end
  end

  defp validate_stat(%File.Stat{type: :regular, size: size}, max_file_bytes)
       when size <= max_file_bytes,
       do: :ok

  defp validate_stat(%File.Stat{type: :regular}, _max_file_bytes),
    do: {:error, :proof_file_too_large}

  defp validate_stat(_stat, _max_file_bytes), do: {:error, :proof_file_not_regular}

  defp content_type(path) do
    case Map.fetch(@allowed_content_types, path |> Path.extname() |> String.downcase()) do
      {:ok, content_type} -> {:ok, content_type}
      :error -> {:error, :unsupported_proof_file_type}
    end
  end

  defp remote_read_command(workspace, candidate, max_file_bytes) do
    workspace = shell_escape(workspace)
    candidate = shell_escape(candidate)

    """
    root=$(cd #{workspace} && pwd -P) || exit 41
    file=$(realpath #{candidate}) || exit 41
    case "$file" in "$root"/*) ;; *) exit 42 ;; esac
    test -f "$file" || exit 41
    size=$(wc -c < "$file") || exit 41
    test "$size" -le #{max_file_bytes} || exit 43
    base64 < "$file"
    """
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp upload_file(filename, content_type, bytes, agent_settings, opts) do
    client = Keyword.get(opts, :linear_agent_client, AgentClient)

    client_opts =
      Keyword.merge(Keyword.get(opts, :linear_agent_client_opts, []),
        agent_settings: agent_settings
      )

    if is_function(client, 4) do
      client.(filename, content_type, bytes, client_opts)
    else
      client.upload_file(filename, content_type, bytes, client_opts)
    end
  end

  defp record_proof(asset_url, caption, opts) do
    bridge = Keyword.get(opts, :linear_agent_bridge, AgentBridge)
    issue_id = Keyword.fetch!(opts, :issue_id)

    if is_function(bridge, 3) do
      bridge.(issue_id, asset_url, caption)
    else
      bridge.record_proof(issue_id, asset_url, caption)
    end
  end

  defp response(success, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp error_payload(reason) do
    message = Map.get(@error_messages, reason, "Screenshot proof upload failed.")

    %{"error" => %{"message" => message, "reason" => inspect(reason)}}
  end
end
