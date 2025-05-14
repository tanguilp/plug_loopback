defmodule PlugLoopback do
  @moduledoc """
  A set of utils to programmatically call your own endpoints

  It happens that sometimes you need to programmatically call your own endpoint (for instance Phoenix
  endpoint). One could use an HTTP client locally calling your own deployed instance, but it's
  cumbersome, hard to test and comes with an overhead.

  This library intends to provide with a set of function to directly call your endpoint. It is very
  similar to `Phoenix.Conntest`.

  You can form a new request from a Phoenix endpoint:

  ```elixir
  MyAppWeb
  |> PlugLoopback.from_phoenix_endpoint()
  |> PlugLoopback.get("/some/path", [{"some", "header"}])
  |> Plug.Conn.put_req_header("another", "header")
  |> PlugLoopback.run()
  ```

  or replay any `Plug.Conn{}`:

  ```elixir
  conn
  |> PlugLoopback.replay()
  |> PlugLoopback.run() # Here is a very good opportunity to create an infinite loop!
  ```

  > #### Warning {: .warning}
  >
  > For some very good reason, you must run these commands in their own process. **Do not** run
  > it in a process that already processed a `%Plug.Conn{}`.

  """

  @enforce_keys [:owner]
  defstruct [
    :method,
    :req_body,
    :owner,
    :next_plug,
    chunks: [],
    http_protocol: :"HTTP/1.1",
    peer_data: %{
      address: {127, 0, 0, 1},
      port: 28_06_42_12,
      ssl_cert: nil
    }
  ]

  @doc """
  Creates a new fresh conn ready to request from another conn

  State is reinitialized so that the returned conn is cleaned to be requested again.

  If a Phoenix endpoint was used, then it is recognized and the result conn can be run
  with `run/1`. Otherwise you need to call the next plug yourself, like:

  ```elixir
  conn
  |> PlugLoopback.replay()
  |> MyOtherPlugModule.call(opts)
  ```

  Peer data is copied from the original conn.
  """
  @spec replay(Plug.Conn.t()) :: Plug.Conn.t()
  def replay(%Plug.Conn{} = conn) do
    {current_adapter, current_adapter_state} = conn.adapter

    adapter_state = %__MODULE__{
      method: conn.method,
      req_body: req_body(conn),
      owner: self(),
      http_protocol: current_adapter.get_http_protocol(current_adapter_state),
      peer_data: current_adapter.get_peer_data(current_adapter_state),
      next_plug: next_plug(conn)
    }

    %Plug.Conn{
      adapter: {__MODULE__.Adapter, adapter_state},
      host: conn.host,
      method: conn.method,
      owner: self(),
      path_info: conn.path_info,
      port: conn.port,
      query_string: conn.query_string,
      remote_ip: conn.remote_ip,
      req_headers: conn.req_headers,
      request_path: conn.request_path,
      scheme: conn.scheme
    }
  end

  @doc """
  Creates a new fresh conn from a Phoenix endpoint

  Peer data IP address is set to `127.0.0.1`.

  After calling this function, you need to form a request with `get/4`, `post/4`, `put/4`, `patch/4`
  `head/4`, `delete/4` or the generic `request/5`.
  """
  @spec from_phoenix_endpoint(module()) :: Plug.Conn.t()
  def from_phoenix_endpoint(endpoint) when is_atom(endpoint) do
    adapter_state = %__MODULE__{
      owner: self(),
      next_plug: {endpoint, []}
    }

    conn =
      Plug.Conn.Adapter.conn(
        {__MODULE__.Adapter, adapter_state},
        nil,
        %URI{endpoint.struct_url() | path: "/"},
        adapter_state.peer_data.address,
        []
      )

    %Plug.Conn{conn | request_path: %Plug.Conn{}.request_path}
  end

  @doc """
  Readies a conn for requesting

  This function sets the necessary information to make a request: method, path, headers and body.
  """
  @spec request(Plug.Conn.t(), Plug.Conn.method(), binary(), Plug.Conn.headers(), binary() | nil) ::
          Plug.Conn.t()
  def request(
        %Plug.Conn{} = conn,
        <<_::binary>> = method,
        <<_::binary>> = path,
        headers \\ [],
        body \\ nil
      )
      when is_list(headers) and (is_binary(body) or is_nil(body)) do
    {__MODULE__.Adapter, adapter_state} = conn.adapter

    adapter_state = %__MODULE__{adapter_state | method: method, req_body: body}

    Plug.Conn.Adapter.conn(
      {__MODULE__.Adapter, adapter_state},
      method,
      conn
      |> Plug.Conn.request_url()
      |> String.trim_trailing("/")
      |> Kernel.<>(path)
      |> URI.parse(),
      adapter_state.peer_data.address,
      conn.req_headers ++ headers
    )
  end

  @doc """
  Shortcut for `request/1` with `"GET"` method
  """
  @spec get(Plug.Conn.t(), binary(), Plug.Conn.headers(), binary | nil) :: Plug.Conn.t()
  def get(conn, path, headers \\ [], body \\ nil) do
    request(conn, "GET", path, headers, body)
  end

  @doc """
  Shortcut for `request/1` with `"POST"` method
  """
  @spec post(Plug.Conn.t(), binary(), Plug.Conn.headers(), binary | nil) :: Plug.Conn.t()
  def post(conn, path, headers \\ [], body \\ nil) do
    request(conn, "POST", path, headers, body)
  end

  @doc """
  Shortcut for `request/1` with `"PUT"` method
  """
  @spec put(Plug.Conn.t(), binary(), Plug.Conn.headers(), binary | nil) :: Plug.Conn.t()
  def put(conn, path, headers \\ [], body \\ nil) do
    request(conn, "PUT", path, headers, body)
  end

  @doc """
  Shortcut for `request/1` with `"PATCH"` method
  """
  @spec patch(Plug.Conn.t(), binary(), Plug.Conn.headers(), binary | nil) :: Plug.Conn.t()
  def patch(conn, path, headers \\ [], body \\ nil) do
    request(conn, "PATCH", path, headers, body)
  end

  @doc """
  Shortcut for `request/1` with `"DELETE"` method
  """
  @spec delete(Plug.Conn.t(), binary(), Plug.Conn.headers(), binary | nil) :: Plug.Conn.t()
  def delete(conn, path, headers \\ [], body \\ nil) do
    request(conn, "DELETE", path, headers, body)
  end

  @doc """
  Shortcut for `request/1` with `"HEAD"` method
  """
  @spec head(Plug.Conn.t(), binary(), Plug.Conn.headers(), binary | nil) :: Plug.Conn.t()
  def head(conn, path, headers \\ [], body \\ nil) do
    request(conn, "HEAD", path, headers, body)
  end

  @doc """
  Runs a request created by functions of this module
  """
  @spec run(Plug.Conn.t()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn) do
    {__MODULE__.Adapter, adapter_state} = conn.adapter

    {endpoint, opts} = adapter_state.next_plug

    endpoint.call(conn, endpoint.init(opts))
  end

  defp req_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}) do
    raise "Unfetched request body"
  end

  defp req_body(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.map(&String.downcase/1)
    |> Enum.at(0)
    |> case do
      "application/x-www-form-urlencoded" ->
        conn.body_params
        |> Enum.into([])
        |> Plug.Conn.Query.encode()

      "multipart/" <> _ = multipart_type ->
        raise "MIME type `#{multipart_type}` is unsupported"

      "application/" <> subtype ->
        if subtype == "json" or String.ends_with?(subtype, "+json") do
          JSON.encode!(conn.body_params)
        else
          ""
        end

      _ ->
        ""
    end
  end

  defp next_plug(%Plug.Conn{private: %{phoenix_endpoint: _}} = conn) do
    {conn.private.phoenix_endpoint, []}
  end

  defp next_plug(_conn) do
    nil
  end
end
