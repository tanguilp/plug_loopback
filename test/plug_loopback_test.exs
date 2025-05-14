defmodule PlugLoopbackTest do
  use ExUnit.Case

  import Plug.Conn
  import Phoenix.ConnTest

  Application.put_env(:phoenix, PlugLoopbackTest.Endpoint,
    url: [host: "www.example.com", port: 1234, scheme: "https"]
  )

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :phoenix
    def init(opts), do: opts
    def call(conn, :set), do: resp(conn, 200, "ok")

    def call(conn, opts) do
      Router.call(conn, Router.init([]))
    end
  end

  setup_all do
    Logger.disable(self())
    Endpoint.start_link()
    :ok
  end

  describe "replay/1" do
    test "build a new conn from an unsent one" do
      conn =
        build_conn(:get, "/some/path")
        |> fetch_req_body()
        |> assign(:some, :value)
        |> put_req_header("some", "header")

      fresh_conn = PlugLoopback.replay(conn)

      assert fresh_conn.method == conn.method
      assert fresh_conn.assigns == %{}
      assert %Plug.Conn.Unfetched{} = fresh_conn.body_params
      assert fresh_conn.host == conn.host
      assert fresh_conn.path_info == conn.path_info
      assert fresh_conn.port == conn.port
      assert fresh_conn.private == %{}
      assert fresh_conn.req_headers == conn.req_headers
      assert fresh_conn.request_path == conn.request_path
      assert fresh_conn.scheme == conn.scheme
      assert Plug.Conn.get_peer_data(fresh_conn) == Plug.Conn.get_peer_data(conn)
      assert fresh_conn.state == :unset
      assert fresh_conn.status == nil
    end

    test "build a new conn from a sent one" do
      conn =
        build_conn(:get, "/some/path")
        |> fetch_req_body()
        |> assign(:some, :value)
        |> put_req_header("some", "header")
        |> Endpoint.call(:set)

      fresh_conn = PlugLoopback.replay(conn)

      assert fresh_conn.method == conn.method
      assert fresh_conn.assigns == %{}
      assert %Plug.Conn.Unfetched{} = fresh_conn.body_params
      assert fresh_conn.host == conn.host
      assert fresh_conn.path_info == conn.path_info
      assert fresh_conn.port == conn.port
      assert fresh_conn.private == %{}
      assert fresh_conn.req_headers == conn.req_headers
      assert fresh_conn.request_path == conn.request_path
      assert fresh_conn.scheme == conn.scheme
      assert Plug.Conn.get_peer_data(fresh_conn) == Plug.Conn.get_peer_data(conn)
      assert fresh_conn.state == :unset
      assert fresh_conn.status == nil
    end

    test "copies back application/x-www-form-urlencoded content to new conn" do
      req_data = [{"foo bar", "1"}, {"city", "東京"}]

      conn =
        build_conn(:post, "/some/path", :uri_string.compose_query(req_data))
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> fetch_req_body([:urlencoded])

      fresh_conn = conn |> PlugLoopback.replay() |> fetch_req_body([:urlencoded])

      assert fresh_conn.body_params == Enum.into(req_data, %{})
    end

    test "copies back JSON content to new conn" do
      req_data = %{"some" => ["json"]}

      conn =
        build_conn(:post, "/some/path", JSON.encode!(req_data))
        |> put_req_header("content-type", "application/json")
        |> fetch_req_body([:json])

      fresh_conn = conn |> PlugLoopback.replay() |> fetch_req_body([:json])

      assert fresh_conn.body_params == req_data
    end
  end

  describe "from_phoenix_endpoint/1" do
    test "builds a new conn from a Phoenix endpoint" do
      conn = PlugLoopback.from_phoenix_endpoint(Endpoint)

      assert conn.method == nil
      assert conn.assigns == %{}
      assert %Plug.Conn.Unfetched{} = conn.body_params
      assert conn.host == "www.example.com"
      assert conn.path_info == []
      assert conn.port == 1234
      assert conn.private == %{}
      assert conn.req_headers == %Plug.Conn{}.req_headers
      assert conn.request_path == %Plug.Conn{}.request_path
      assert conn.scheme == :https
      assert Plug.Conn.get_peer_data(conn).address == {127, 0, 0, 1}
      assert conn.state == :unset
      assert conn.status == nil
    end
  end

  defp fetch_req_body(conn, formats \\ []) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(parsers: formats, json_decoder: JSON)
    )
  end
end
