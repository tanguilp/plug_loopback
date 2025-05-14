defmodule PlugLoopback.Adapter do
  @moduledoc false

  @behaviour Plug.Conn.Adapter

  @impl true
  def send_resp(%{method: "HEAD"} = payload, _status, _headers, _body) do
    do_send(payload, "")
  end

  def send_resp(payload, _status, _headers, body) do
    do_send(payload, IO.iodata_to_binary(body))
  end

  @impl true
  def send_file(%{method: "HEAD"} = payload, _status, _headers, _path, _offset, _length) do
    do_send(payload, "")
  end

  def send_file(payload, _status, _headers, path, offset, length) do
    %File.Stat{type: :regular, size: size} = File.stat!(path)

    length =
      cond do
        length == :all -> size
        is_integer(length) -> length
      end

    {:ok, data} =
      File.open!(path, [:read, :binary], fn device ->
        :file.pread(device, offset, length)
      end)

    do_send(payload, data)
  end

  @impl true
  def send_chunked(payload, _status, _headers), do: {:ok, "", payload}

  @impl true
  def chunk(%{method: "HEAD"} = payload, _body), do: {:ok, "", payload}

  def chunk(payload, body) do
    chunks = payload.chunks ++ [body]

    {:ok, Enum.join(chunks), %{payload | chunks: chunks}}
  end

  @impl true
  def read_req_body(payload, opts) do
    size = min(byte_size(payload.req_body), Keyword.get(opts, :length, 8_000_000))

    case :erlang.split_binary(payload.req_body, size) do
      {data, ""} ->
        {:ok, data, %{payload | req_body: ""}}

      {data, rest} ->
        {:more, data, %{payload | req_body: rest}}
    end
  end

  @impl true
  def inform(_payload, _status, _headers), do: {:error, :not_supported}

  @impl true
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}

  @impl true
  def get_peer_data(payload), do: payload.peer_data

  @impl true
  def get_http_protocol(payload), do: payload.http_protocol

  defp do_send(payload, body) do
    send(payload.owner, {:plug_conn, :sent})

    {:ok, body, payload}
  end
end
