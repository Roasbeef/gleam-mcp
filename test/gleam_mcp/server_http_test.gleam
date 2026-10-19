import gleam/result
import gleam_mcp/server_http.{
  Authenticate, Interface, LocalUnauthenticated, Loopback,
}

fn config(admission) {
  let assert Ok(config) = server_http.new(0, "/mcp", [], admission)
  config
}

fn authenticate() {
  Authenticate(fn(_) { Ok(Nil) })
}

pub fn interface_requires_authentication_test() {
  assert server_http.with_listen(
      config(LocalUnauthenticated),
      Interface("0.0.0.0"),
    )
    |> result.is_error
  assert server_http.with_listen(config(LocalUnauthenticated), Interface("::1"))
    |> result.is_error

  // Local access under LocalUnauthenticated is spelled Loopback.
  assert server_http.with_listen(
      config(LocalUnauthenticated),
      Interface("127.0.0.1"),
    )
    |> result.is_error
}

pub fn loopback_is_always_admitted_test() {
  assert server_http.with_listen(config(LocalUnauthenticated), Loopback)
    |> result.is_ok
  assert server_http.with_listen(config(authenticate()), Loopback)
    |> result.is_ok
}

pub fn authenticated_interface_accepts_ip_literals_test() {
  let admitted = fn(address) {
    server_http.with_listen(config(authenticate()), Interface(address))
    |> result.is_ok
  }
  assert admitted("0.0.0.0")
  assert admitted("10.1.2.3")
  assert admitted("::")
  assert admitted("2001:db8::1")
}

pub fn interface_refuses_non_literal_addresses_test() {
  let refused = fn(address) {
    server_http.with_listen(config(authenticate()), Interface(address))
    |> result.is_error
  }
  assert refused("")
  assert refused("localhost")
  assert refused("example.com")
  assert refused("127.1")
  assert refused("256.0.0.1")
  assert refused("10.0.0.1:80")
  assert refused("not an address")
  assert refused("fe80::1%en0")
}
