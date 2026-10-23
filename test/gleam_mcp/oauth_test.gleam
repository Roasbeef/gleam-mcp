import gleam/option.{None, Some}
import gleam/string
import gleam_mcp/oauth.{
  type HttpRequest, type HttpResponse, type Services, Attempt, Callback, Grant,
  HttpResponse, Metadata, Services,
}

fn fake_services(
  handler: fn(HttpRequest) -> Result(HttpResponse, String),
) -> Services {
  Services(
    fetch: fn(req, _limit) { handler(req) },
    now: fn() { 1_700_000_000_000 },
    entropy: fn(n) { <<1:size(n)-unit(8)>> },
  )
}

pub fn valid_oauth_url_accepts_https_and_loopback_only_test() {
  assert oauth.valid_oauth_url("https://mcp.linear.app/mcp")
  assert oauth.valid_oauth_url("http://127.0.0.1:8080/mcp")
  assert oauth.valid_oauth_url("http://[::1]:9000/mcp")
  assert !oauth.valid_oauth_url("http://mcp.linear.app/mcp")
  assert !oauth.valid_oauth_url("https://user:pass@mcp.linear.app/mcp")
  assert !oauth.valid_oauth_url("https://mcp.linear.app/mcp#frag")
}

pub fn discover_resolves_prm_and_asm_and_requires_s256_test() {
  let services =
    fake_services(fn(req) {
      case req.url {
        "https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"resource\":\"https://mcp.example.com/v1/mcp\",\"authorization_servers\":[\"https://auth.example.com\"],\"scopes_supported\":[\"mcp:tools\"]}",
          ))
        "https://auth.example.com/.well-known/oauth-authorization-server" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"issuer\":\"https://auth.example.com\",\"authorization_endpoint\":\"https://auth.example.com/authorize\",\"token_endpoint\":\"https://auth.example.com/token\",\"registration_endpoint\":\"https://auth.example.com/register\",\"scopes_supported\":[\"mcp:tools\",\"offline_access\"],\"code_challenge_methods_supported\":[\"S256\"]}",
          ))
        _ -> Ok(HttpResponse(status: 404, headers: [], body: ""))
      }
    })
  let assert Ok(meta) =
    oauth.discover("https://mcp.example.com/v1/mcp", services)
    as "discover must succeed"
  assert meta
    == Metadata(
      resource: "https://mcp.example.com/v1/mcp",
      issuer: "https://auth.example.com",
      authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token",
      registration_endpoint: Some("https://auth.example.com/register"),
      scopes: ["mcp:tools", "offline_access"],
    )
}

pub fn authorization_url_and_callback_verify_pkce_and_state_test() {
  let meta =
    Metadata(
      resource: "https://mcp.example.com/mcp",
      issuer: "https://auth.example.com",
      authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token",
      registration_endpoint: None,
      scopes: ["mcp:tools"],
    )
  let attempt =
    Attempt(
      verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
      state: "state-123",
      client_id: "client-abc",
    )
  let url =
    oauth.authorization_url(
      meta,
      attempt,
      "http://127.0.0.1:4321/auth/callback",
    )
  assert string.contains(
    url,
    "code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
  )
  assert string.contains(url, "code_challenge_method=S256")
  assert string.contains(url, "resource=https%3A%2F%2Fmcp.example.com%2Fmcp")
  assert oauth.callback(attempt, "state=state-123&code=code-xyz")
    == Ok(Callback("code-xyz"))
  assert oauth.callback(attempt, "state=wrong&code=code-xyz")
    == Error("invalid_callback")
  assert oauth.callback(attempt, "state=state-123&error=access_denied")
    == Error("authorization_denied")
}

pub fn exchange_refresh_and_bindings_codec_round_trip_test() {
  let meta =
    Metadata(
      resource: "https://mcp.example.com/mcp",
      issuer: "https://auth.example.com",
      authorization_endpoint: "https://auth.example.com/authorize",
      token_endpoint: "https://auth.example.com/token",
      registration_endpoint: Some("https://auth.example.com/register"),
      scopes: ["mcp:tools"],
    )
  let services =
    fake_services(fn(req) {
      case req.url, string.contains(req.body, "grant_type=refresh_token") {
        "https://auth.example.com/register", _ ->
          Ok(HttpResponse(
            status: 201,
            headers: [],
            body: "{\"client_id\":\"dyn-client-1\"}",
          ))
        "https://auth.example.com/token", False -> {
          assert string.contains(
            req.body,
            "resource=https%3A%2F%2Fmcp.example.com%2Fmcp",
          )
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"access_token\":\"tok-1\",\"refresh_token\":\"ref-1\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"scope\":\"mcp:tools\"}",
          ))
        }
        "https://auth.example.com/token", True ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"access_token\":\"tok-2\",\"refresh_token\":\"ref-2\",\"token_type\":\"Bearer\",\"expires_in\":7200}",
          ))
        _, _ -> Ok(HttpResponse(status: 404, headers: [], body: ""))
      }
    })
  let assert Ok(client_id) =
    oauth.resolve_client_id(
      None,
      meta,
      None,
      "http://127.0.0.1:4321/auth/callback",
      "Loom",
      services,
    )
    as "dynamic client registration must succeed"
  assert client_id == "dyn-client-1"

  let attempt = Attempt(verifier: "v", state: "s", client_id:)
  let assert Ok(binding) =
    oauth.exchange_code(
      "linear",
      meta,
      attempt,
      "http://127.0.0.1:4321/auth/callback",
      Callback("code-1"),
      services,
    )
    as "code exchange must succeed"
  assert binding.grant
    == Some(Grant(
      access: "tok-1",
      refresh: Some("ref-1"),
      scopes: ["mcp:tools"],
      expires: 1_700_003_600_000,
    ))

  let assert Ok(refreshed) = oauth.refresh(binding, services)
    as "refresh must rotate tokens"
  assert refreshed.grant
    == Some(Grant(
      access: "tok-2",
      refresh: Some("ref-2"),
      scopes: ["mcp:tools"],
      expires: 1_700_007_200_000,
    ))

  let encoded = oauth.encode_bindings([refreshed])
  assert oauth.decode_bindings(encoded) == Ok([refreshed])
}

pub fn discover_rejects_mismatched_issuer_and_loopback_downgrade_from_public_resource_test() {
  let mismatched_issuer =
    fake_services(fn(req) {
      case req.url {
        "https://mcp.example.com/.well-known/oauth-protected-resource" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"authorization_servers\":[\"https://auth.example.com\"]}",
          ))
        "https://auth.example.com/.well-known/oauth-authorization-server" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"issuer\":\"https://other-issuer.example.com\",\"authorization_endpoint\":\"https://auth.example.com/authorize\",\"token_endpoint\":\"https://auth.example.com/token\"}",
          ))
        _ -> Ok(HttpResponse(status: 404, headers: [], body: ""))
      }
    })
  assert oauth.discover("https://mcp.example.com", mismatched_issuer)
    == Error("invalid_auth_server_metadata")

  let loopback_prm =
    fake_services(fn(req) {
      case req.url {
        "https://mcp.example.com/.well-known/oauth-protected-resource" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"authorization_servers\":[\"http://127.0.0.1:8080\"]}",
          ))
        _ -> Ok(HttpResponse(status: 404, headers: [], body: ""))
      }
    })
  assert oauth.discover("https://mcp.example.com", loopback_prm)
    == Error("invalid_protected_resource_metadata")

  let loopback_token_ep =
    fake_services(fn(req) {
      case req.url {
        "https://mcp.example.com/.well-known/oauth-protected-resource" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"authorization_servers\":[\"https://auth.example.com\"]}",
          ))
        "https://auth.example.com/.well-known/oauth-authorization-server" ->
          Ok(HttpResponse(
            status: 200,
            headers: [],
            body: "{\"issuer\":\"https://auth.example.com\",\"authorization_endpoint\":\"https://auth.example.com/authorize\",\"token_endpoint\":\"http://127.0.0.1:8080/token\"}",
          ))
        _ -> Ok(HttpResponse(status: 404, headers: [], body: ""))
      }
    })
  assert oauth.discover("https://mcp.example.com", loopback_token_ep)
    == Error("invalid_auth_server_metadata")
}
