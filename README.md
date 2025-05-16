# PlugLoopback

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

## Installation

```elixir
def deps do
  [
    {:plug_loopback, "~> 0.1.0"}
  ]
end
```

## Support

Requires Elixir 1.18+

### Replay request body

The tricky part when copying a conn is to reset the initial body. Check the support in the following
list:
- [x] JSON
- [x] URL-encoded
- [ ] multipart
- [ ] custom body
