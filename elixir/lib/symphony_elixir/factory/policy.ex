defmodule SymphonyElixir.Factory.Policy do
  @moduledoc """
  State-transition rules owned by the Symphony conductor.

  The factory may hand work back for review, but only a person may mark it Done.
  """

  @forbidden_state "done"

  @spec allow_transition(String.t()) :: :ok | {:error, :done_is_human_only}
  def allow_transition(state_name) when is_binary(state_name) do
    if normalize(state_name) == @forbidden_state do
      {:error, :done_is_human_only}
    else
      :ok
    end
  end

  @spec review_state(map()) :: {:ok, String.t()} | {:error, :done_is_human_only}
  def review_state(factory_settings) do
    with :ok <- allow_transition(factory_settings.review_state) do
      {:ok, factory_settings.review_state}
    end
  end

  @spec feedback_state(map()) :: {:ok, String.t()} | {:error, :done_is_human_only}
  def feedback_state(factory_settings) do
    with :ok <- allow_transition(factory_settings.feedback_state) do
      {:ok, factory_settings.feedback_state}
    end
  end

  defp normalize(state_name), do: state_name |> String.trim() |> String.downcase()
end
