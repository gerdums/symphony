defmodule SymphonyElixir.Factory.Protocol do
  @moduledoc """
  Validates the versioned JSONL stream emitted by the external software factory.

  Every line is one event. Event IDs are stable across retries so the runner can
  replay a partially completed phase without duplicating Linear activity.
  """

  @version 1
  @phases ["planning", "build", "review", "qa"]
  @event_types [
    "phase.started",
    "agent.started",
    "plan.updated",
    "progress",
    "diff.updated",
    "check.completed",
    "artifact.created",
    "pr.updated",
    "phase.completed",
    "phase.failed",
    "blocked"
  ]
  @top_level_keys ~w(protocolVersion eventId runId occurredAt project issue type phase payload agentId)
  @required_top_level_keys ~w(protocolVersion eventId runId occurredAt project issue type phase payload)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  @git_sha ~r/\A[0-9a-f]{40}\z/i
  @sha256 ~r/\A[0-9a-f]{64}\z/i
  @issue_identifier ~r/\A[A-Z][A-Z0-9]*-[0-9]+\z/
  @flow ~r/\A[a-z0-9][a-z0-9-]*\z/

  @type event :: %{required(String.t()) => term()}

  @spec parse_line(iodata(), pos_integer()) :: {:ok, event()} | {:error, term()}
  def parse_line(line, expected_version \\ @version) do
    with {:ok, event} <- Jason.decode(IO.iodata_to_binary(line)),
         :ok <- validate_event(event, expected_version) do
      {:ok, event}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, Exception.message(error)}}
      {:error, _reason} = error -> error
    end
  end

  @spec canonical_digest(event()) :: String.t()
  def canonical_digest(event) when is_map(event) do
    event
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec terminal_event?(event()) :: boolean()
  def terminal_event?(%{"type" => type}) when type in ["phase.completed", "phase.failed", "blocked"],
    do: true

  def terminal_event?(_event), do: false

  @spec phases() :: [String.t()]
  def phases, do: @phases

  defp validate_event(event, expected_version) when is_map(event) do
    with :ok <- require_allowed_keys(event, @top_level_keys, @required_top_level_keys, "event"),
         :ok <- require_equal(event, "protocolVersion", expected_version),
         :ok <- require_format(event, "eventId", @uuid),
         :ok <- require_format(event, "runId", @uuid),
         :ok <- require_string(event, "project"),
         :ok <- require_format(event, "issue", @issue_identifier),
         :ok <- require_member(event, "type", @event_types),
         :ok <- require_member(event, "phase", @phases),
         :ok <- optional_string(event, "agentId"),
         :ok <- require_timestamp(event),
         {:ok, payload} <- require_map(event, "payload") do
      validate_payload(event["type"], payload, event)
    end
  end

  defp validate_event(_event, _expected_version), do: {:error, :event_must_be_an_object}

  defp validate_payload("phase.started", payload, _event) do
    with :ok <- require_exact_keys(payload, ~w(attempt packet branch workspace), "payload"),
         :ok <- require_positive_integer(payload, "attempt"),
         :ok <- require_string(payload, "packet"),
         :ok <- require_string(payload, "branch") do
      require_string(payload, "workspace")
    end
  end

  defp validate_payload("agent.started", payload, _event) do
    with :ok <- require_exact_keys(payload, ~w(provider model role readOnly), "payload"),
         :ok <- require_member(payload, "provider", ["codex", "claude"]),
         :ok <- require_string(payload, "model"),
         :ok <- require_string(payload, "role") do
      require_boolean(payload, "readOnly")
    end
  end

  defp validate_payload("plan.updated", payload, _event) do
    with :ok <-
           require_allowed_keys(
             payload,
             ~w(summary acceptanceCriteria workScope postMergeInternalBuild proofTargets),
             ~w(summary acceptanceCriteria workScope postMergeInternalBuild proofTargets),
             "payload"
           ),
         :ok <- require_string(payload, "summary"),
         :ok <- require_string_list(payload, "acceptanceCriteria"),
         :ok <- require_member(payload, "workScope", ["non-runtime", "runtime-static", "runtime-interactive"]),
         :ok <- require_boolean(payload, "postMergeInternalBuild") do
      validate_proof_targets(payload["proofTargets"])
    end
  end

  defp validate_payload("progress", payload, _event) do
    with :ok <- require_allowed_keys(payload, ~w(message percent), ~w(message), "payload"),
         :ok <- require_string(payload, "message") do
      optional_number_range(payload, "percent", 0, 100)
    end
  end

  defp validate_payload("diff.updated", payload, _event) do
    with :ok <-
           require_exact_keys(
             payload,
             ~w(filesChanged insertions deletions commitShas),
             "payload"
           ),
         :ok <- require_nonnegative_integer(payload, "filesChanged"),
         :ok <- require_nonnegative_integer(payload, "insertions"),
         :ok <- require_nonnegative_integer(payload, "deletions") do
      require_format_list(payload, "commitShas", @git_sha)
    end
  end

  defp validate_payload("check.completed", payload, _event) do
    with :ok <-
           require_allowed_keys(
             payload,
             ~w(name status command summary required acceptance external commitSha url),
             ~w(name status),
             "payload"
           ),
         :ok <- require_string(payload, "name"),
         :ok <- require_member(payload, "status", ["passed", "failed", "skipped"]),
         :ok <- optional_string(payload, "command"),
         :ok <- optional_string(payload, "summary"),
         :ok <- optional_boolean(payload, "required"),
         :ok <- optional_boolean(payload, "acceptance"),
         :ok <- optional_boolean(payload, "external"),
         :ok <- optional_format(payload, "commitSha", @git_sha) do
      optional_url(payload, "url")
    end
  end

  defp validate_payload("artifact.created", payload, event) do
    with :ok <- require_exact_keys(payload, ["artifact"], "payload"),
         {:ok, artifact} <- require_map(payload, "artifact") do
      validate_artifact(artifact, event)
    end
  end

  defp validate_payload("pr.updated", payload, _event) do
    with :ok <-
           require_allowed_keys(
             payload,
             ~w(state number url headSha qualityCheck),
             ~w(state),
             "payload"
           ),
         :ok <- require_member(payload, "state", ["draft", "open", "merged", "closed"]),
         :ok <- optional_positive_integer(payload, "number"),
         :ok <- optional_url(payload, "url"),
         :ok <- optional_format(payload, "headSha", @git_sha) do
      optional_quality_check(payload)
    end
  end

  defp validate_payload("phase.completed", payload, _event) do
    with :ok <- require_exact_keys(payload, ~w(summary branch commitShas), "payload"),
         :ok <- require_string(payload, "summary"),
         :ok <- require_string(payload, "branch") do
      require_format_list(payload, "commitShas", @git_sha)
    end
  end

  defp validate_payload("phase.failed", payload, _event) do
    with :ok <- require_exact_keys(payload, ~w(error retryable), "payload"),
         :ok <- require_string(payload, "error") do
      require_boolean(payload, "retryable")
    end
  end

  defp validate_payload("blocked", payload, _event) do
    with :ok <- require_allowed_keys(payload, ~w(reason action), ~w(reason), "payload"),
         :ok <- require_string(payload, "reason") do
      optional_string(payload, "action")
    end
  end

  defp validate_proof_targets(nil), do: :ok

  defp validate_proof_targets(targets) when is_list(targets) do
    with :ok <- validate_each_proof_target(targets),
         bindings <- Enum.map(targets, &{&1["platform"], &1["flow"]}),
         true <- Enum.uniq(bindings) == bindings do
      :ok
    else
      false -> {:error, {:invalid_field, "payload.proofTargets", :duplicate_binding}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_proof_targets(value),
    do: {:error, {:invalid_field, "payload.proofTargets", value}}

  defp validate_each_proof_target(targets) do
    Enum.reduce_while(targets, :ok, fn target, :ok ->
      result =
        with true <- is_map(target),
             :ok <-
               require_allowed_keys(
                 target,
                 ~w(platform flow requiredMedia requiredRelations),
                 ~w(platform flow requiredMedia),
                 "payload.proofTargets[]"
               ),
             :ok <- require_member(target, "platform", ["ios", "android", "web", "backend", "other"]),
             :ok <- require_format(target, "flow", @flow),
             :ok <- require_nonempty_enum_list(target, "requiredMedia", ["image", "video"]),
             :ok <- optional_visual_relations(target) do
          :ok
        else
          false -> {:error, {:invalid_field, "payload.proofTargets[]", target}}
          {:error, _reason} = error -> error
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp require_enum_list(map, key, allowed) do
    case Map.fetch(map, key) do
      {:ok, values} when is_list(values) ->
        if Enum.uniq(values) == values and Enum.all?(values, &(&1 in allowed)),
          do: :ok,
          else: {:error, {:invalid_field, key, values}}

      {:ok, value} ->
        {:error, {:invalid_field, key, value}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp require_nonempty_enum_list(map, key, allowed) do
    with :ok <- require_enum_list(map, key, allowed),
         values when is_list(values) and values != [] <- map[key] do
      :ok
    else
      _invalid -> {:error, {:invalid_field, key, map[key]}}
    end
  end

  defp optional_visual_relations(target) do
    case Map.fetch(target, "requiredRelations") do
      :error ->
        :ok

      {:ok, relations} when is_list(relations) ->
        if Enum.sort(relations) == ["after", "before"] and "image" in target["requiredMedia"],
          do: :ok,
          else: {:error, {:invalid_field, "requiredRelations", relations}}

      {:ok, relations} ->
        {:error, {:invalid_field, "requiredRelations", relations}}
    end
  end

  defp validate_artifact(artifact, event) do
    common =
      ~w(id kind storage uri mimeType byteSize sha256 capturedAt commitSha runId attempt bundleOrPackageId deviceIdentity issue flow platform relation description)

    allowed = if artifact["kind"] == "image", do: common ++ ~w(width height), else: common ++ ~w(durationMs width height)
    required = if artifact["kind"] == "image", do: common ++ ~w(width height), else: common ++ ~w(durationMs)

    with :ok <- require_allowed_keys(artifact, allowed, required, "payload.artifact"),
         :ok <- require_format(artifact, "id", @uuid),
         :ok <- require_member(artifact, "kind", ["image", "video"]),
         :ok <- require_member(artifact, "storage", ["local_file", "linear_attachment", "remote_url"]),
         :ok <- require_string(artifact, "uri"),
         :ok <- validate_artifact_uri(artifact["storage"], artifact["uri"]),
         :ok <- require_string(artifact, "mimeType"),
         :ok <- validate_artifact_mime(artifact["kind"], artifact["mimeType"]),
         :ok <- require_positive_integer(artifact, "byteSize"),
         :ok <- require_format(artifact, "sha256", @sha256),
         :ok <- require_iso8601(artifact, "capturedAt"),
         :ok <- require_format(artifact, "commitSha", @git_sha),
         :ok <- require_equal(artifact, "runId", event["runId"]),
         :ok <- require_positive_integer(artifact, "attempt"),
         :ok <- require_string(artifact, "bundleOrPackageId"),
         :ok <- require_string(artifact, "deviceIdentity"),
         :ok <- require_equal(artifact, "issue", event["issue"]),
         :ok <- require_format(artifact, "flow", @flow),
         :ok <- require_member(artifact, "platform", ["ios", "android", "web", "backend", "other"]),
         :ok <- require_member(artifact, "relation", ["before", "after", "during", "result"]),
         :ok <- require_string(artifact, "description"),
         :ok <- optional_positive_integer(artifact, "width"),
         :ok <- optional_positive_integer(artifact, "height") do
      optional_positive_integer(artifact, "durationMs")
    end
  end

  defp validate_artifact_uri("local_file", uri) do
    if Path.type(uri) == :absolute, do: :ok, else: {:error, {:invalid_field, "payload.artifact.uri", uri}}
  end

  defp validate_artifact_uri(storage, uri) when storage in ["linear_attachment", "remote_url"] do
    require_https_url(uri, "payload.artifact.uri")
  end

  defp validate_artifact_mime("image", "image/" <> _rest), do: :ok
  defp validate_artifact_mime("video", "video/" <> _rest), do: :ok
  defp validate_artifact_mime(_kind, mime), do: {:error, {:invalid_field, "payload.artifact.mimeType", mime}}

  defp optional_quality_check(payload) do
    case Map.fetch(payload, "qualityCheck") do
      :error ->
        :ok

      {:ok, quality} when is_map(quality) ->
        with :ok <- require_exact_keys(quality, ~w(name status), "payload.qualityCheck"),
             :ok <- require_equal(quality, "name", "factory/quality-gate") do
          require_member(quality, "status", ["passed", "failed", "pending"])
        end

      {:ok, value} ->
        {:error, {:invalid_field, "payload.qualityCheck", value}}
    end
  end

  defp require_exact_keys(map, keys, path), do: require_allowed_keys(map, keys, keys, path)

  defp require_allowed_keys(map, allowed, required, path) do
    actual_set = Map.keys(map) |> MapSet.new()
    allowed_set = MapSet.new(allowed)
    required_set = MapSet.new(required)

    cond do
      !MapSet.subset?(actual_set, allowed_set) ->
        {:error, {:unknown_fields, path, MapSet.difference(actual_set, allowed_set) |> Enum.sort()}}

      !MapSet.subset?(required_set, actual_set) ->
        {:error, {:missing_fields, path, MapSet.difference(required_set, actual_set) |> Enum.sort()}}

      true ->
        :ok
    end
  end

  defp require_equal(event, key, expected) do
    case Map.fetch(event, key) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:unexpected_value, key, actual, expected}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp require_string(event, key) do
    case Map.fetch(event, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:blank_field, key}}, else: :ok

      {:ok, value} ->
        {:error, {:invalid_field, key, value}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string(event, key), do: if(Map.has_key?(event, key), do: require_string(event, key), else: :ok)

  defp require_boolean(event, key) do
    case Map.fetch(event, key) do
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_boolean(event, key), do: if(Map.has_key?(event, key), do: require_boolean(event, key), else: :ok)

  defp require_positive_integer(event, key) do
    case Map.fetch(event, key) do
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_positive_integer(event, key),
    do: if(Map.has_key?(event, key), do: require_positive_integer(event, key), else: :ok)

  defp require_nonnegative_integer(event, key) do
    case Map.fetch(event, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_number_range(event, key, minimum, maximum) do
    case Map.fetch(event, key) do
      :error -> :ok
      {:ok, value} when is_number(value) and value >= minimum and value <= maximum -> :ok
      {:ok, value} -> {:error, {:invalid_field, key, value}}
    end
  end

  defp require_format(event, key, regex) do
    with :ok <- require_string(event, key),
         value <- Map.fetch!(event, key),
         true <- Regex.match?(regex, value) do
      :ok
    else
      false -> {:error, {:invalid_field, key, Map.get(event, key)}}
      {:error, _reason} = error -> error
    end
  end

  defp optional_format(event, key, regex),
    do: if(Map.has_key?(event, key), do: require_format(event, key, regex), else: :ok)

  defp require_format_list(event, key, regex) do
    case Map.fetch(event, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and Regex.match?(regex, &1))) do
          :ok
        else
          {:error, {:invalid_field, key, values}}
        end

      {:ok, value} ->
        {:error, {:invalid_field, key, value}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp require_string_list(event, key) do
    case Map.fetch(event, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          :ok
        else
          {:error, {:invalid_field, key, values}}
        end

      {:ok, value} ->
        {:error, {:invalid_field, key, value}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp require_member(event, key, allowed) do
    with :ok <- require_string(event, key),
         value <- Map.fetch!(event, key),
         true <- value in allowed do
      :ok
    else
      false -> {:error, {:unsupported_value, key, Map.get(event, key)}}
      {:error, _reason} = error -> error
    end
  end

  defp require_timestamp(event), do: require_iso8601(event, "occurredAt")

  defp require_iso8601(event, key) do
    with :ok <- require_string(event, key),
         {:ok, _timestamp, _offset} <- DateTime.from_iso8601(Map.fetch!(event, key)) do
      :ok
    else
      {:error, _reason} -> {:error, {:invalid_field, key, Map.get(event, key)}}
    end
  end

  defp optional_url(event, key) do
    case Map.fetch(event, key) do
      :error -> :ok
      {:ok, value} -> require_https_url(value, key)
    end
  end

  defp require_https_url(value, key) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _uri -> {:error, {:invalid_field, key, value}}
    end
  end

  defp require_https_url(value, key), do: {:error, {:invalid_field, key, value}}

  defp require_map(event, key) do
    case Map.fetch(event, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp canonical_term(value) when is_map(value) do
    {:object,
     value
     |> Enum.map(fn {key, nested} -> {key, canonical_term(nested)} end)
     |> Enum.sort_by(&elem(&1, 0))}
  end

  defp canonical_term(value) when is_list(value), do: {:array, Enum.map(value, &canonical_term/1)}
  defp canonical_term(value), do: {:scalar, value}
end
