defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc false

  alias Plug.Conn

  @spec read_body(Conn.t(), keyword()) ::
          {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, remember_body(conn, body)}
      {:more, body, conn} -> {:more, body, remember_body(conn, body)}
      {:error, _reason} = error -> error
    end
  end

  @spec body(Conn.t()) :: binary()
  def body(conn) do
    conn.private
    |> Map.get(:symphony_raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp remember_body(conn, body) do
    Conn.put_private(conn, :symphony_raw_body, [body | conn.private[:symphony_raw_body] || []])
  end
end
