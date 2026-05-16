defmodule PlugLoopback do
  @moduledoc """
  A set of utils to programmatically call your own endpoints

  It happens that sometimes you need to programmatically call your own endpoint (for instance Phoenix
  endpoint). One could use an HTTP client locally calling your own deployed instance, but it's
  cumbersome, hard to test and comes with an overhead.

  This library intends to provide with a set of function to directly call your endpoint. It is very
  similar to `Phoenix.ConnTest` and reimplements a Plug adapter for this purpose.

  You can form a new request from a Phoenix endpoint:

  ```elixir
  MyAppWeb.Endpoint
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
  > For some very good reasons, you must run these commands in their own process. **Do not** run
  > it in a process that already processed a `%Plug.Conn{}`.

  """

  defmodule EndpointNotConfiguredError do
    @moduledoc """
    Error raised when the endpoint is not configured and the operation cannot succeed

    An endpoint is configured when `PlugLoopback.replay/1` is called on a conn that has been through
    a Phoenix endpoint, or when `PlugLoopback.from_phoenix_endpoint/1` was used.
    """

    defexception message: "Not endpoint was detected and configured, cannot run the current conn"
  end

  defmodule RequestBodyNotFetchedError do
    @moduledoc """
    Error raised when the request body is not fetched for POST, PUT or PATCH requests

    Body can be fetched using `Plug.Parsers`. Make sure to call this function after
    fetching the request body.
    """

    defexception message: "Request body needs to be fetched for this type of request"
  end

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

  or if the conn is from a phoenix endpoint:

  ```elixir
  conn
  |> PlugLoopback.replay()
  |> # modify the conn, for instance by setting new request headers
  |> PlugLoopback.run()
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

    %URI{} = uri = endpoint.struct_url()

    conn =
      Plug.Conn.Adapter.conn(
        {__MODULE__.Adapter, adapter_state},
        nil,
        %URI{uri | path: "/"},
        adapter_state.peer_data.address,
        []
      )

    %Plug.Conn{conn | request_path: %Plug.Conn{}.request_path}
  end

  @doc """
  Readies a conn for requesting

  This function sets the necessary information to make a request: method, path, headers and body.

  When setting a body, make sure to encode it to a binary **and** to set the correct
  `content-type` header. This library doesn't do it for you.

  ## Example

  ```elixir
  MyAppWeb.Endpoint
  |> PlugLoopback.from_phoenix_endpoint()
  |> PlugLoopback.post("/api/user", [{"content-type", "application/json"}, JSON.encode!(data)])
  |> PlugLoopback.run()
  ```
  """
  @spec request(
          Plug.Conn.t(),
          Plug.Conn.method() | atom(),
          binary(),
          Plug.Conn.headers(),
          binary() | nil
        ) ::
          Plug.Conn.t()
  def request(conn, method, path, req_headers \\ [], body \\ nil)

  def request(conn, method, path, headers, body) when is_atom(method) do
    request(conn, method |> to_string |> String.upcase(), path, headers, body)
  end

  def request(%Plug.Conn{} = conn, <<_::binary>> = method, <<_::binary>> = path, headers, body)
      when is_list(headers) and (is_binary(body) or is_nil(body)) do
    {__MODULE__.Adapter, %__MODULE__{} = adapter_state} = conn.adapter

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
  def run(
        %Plug.Conn{adapter: {__MODULE__.Adapter, %__MODULE__{next_plug: {endpoint, opts}}}} = conn
      ) do
    endpoint.call(conn, endpoint.init(opts))
  end

  def run(_conn) do
    raise __MODULE__.EndpointNotConfiguredError
  end

  defp req_body(%Plug.Conn{method: method, body_params: %Plug.Conn.Unfetched{}})
       when method in ~w|PATCH POST PUT| do
    raise __MODULE__.RequestBodyNotFetchedError
  end

  defp req_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}) do
    ""
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
