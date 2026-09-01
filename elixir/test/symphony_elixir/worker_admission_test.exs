defmodule SymphonyElixir.WorkerAdmissionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.WorkerAdmission

  setup do
    previous = System.get_env("SYMPHONY_FACTORY_STATE_PATH")
    previous_enabled = System.get_env("SYMPHONY_FACTORY_ADMISSION_ENABLED")
    path = Path.join(System.tmp_dir!(), "symphony-factory-state-#{System.unique_integer([:positive])}.json")
    System.put_env("SYMPHONY_FACTORY_STATE_PATH", path)
    System.put_env("SYMPHONY_FACTORY_ADMISSION_ENABLED", "true")

    on_exit(fn ->
      File.rm(path)

      if previous do
        System.put_env("SYMPHONY_FACTORY_STATE_PATH", previous)
      else
        System.delete_env("SYMPHONY_FACTORY_STATE_PATH")
      end

      if previous_enabled do
        System.put_env("SYMPHONY_FACTORY_ADMISSION_ENABLED", previous_enabled)
      else
        System.delete_env("SYMPHONY_FACTORY_ADMISSION_ENABLED")
      end
    end)

    %{path: path}
  end

  test "admission governance is opt-in" do
    System.delete_env("SYMPHONY_FACTORY_ADMISSION_ENABLED")
    assert WorkerAdmission.active?("unreachable-test-worker")
  end

  test "missing lifecycle state preserves standalone local scheduling" do
    assert WorkerAdmission.active?(nil)
  end

  test "active local worker accepts new work", %{path: path} do
    File.write!(path, Jason.encode!(%{state: "active"}))
    assert WorkerAdmission.active?(nil)
  end

  test "draining local worker rejects new work", %{path: path} do
    File.write!(path, Jason.encode!(%{state: "draining"}))
    refute WorkerAdmission.active?(nil)
  end

  test "invalid local state fails closed", %{path: path} do
    File.write!(path, "not-json")
    refute WorkerAdmission.active?(nil)
  end
end
