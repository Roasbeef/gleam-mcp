//// OAuth 2.1 authorization-code + PKCE discovery, dynamic registration,
//// callback verification, token exchange, refresh rotation, and credential
//// serialization for remote HTTP MCP servers.
////
//// Both the modern MCP `2026-07-28` specification and the `2025-06-18` /
//// `2025-03-26` Streamable HTTP specifications authenticate remote HTTP
//// endpoints with OAuth 2.1 (`S256` PKCE, Protected Resource Metadata
//// RFC 9728, Authorization Server Metadata RFC 8414, Dynamic Client
//// Registration RFC 7591, and Resource Indicators RFC 8707). This module owns
//// those protocol steps over an injected `Services` record; the host
//// application owns filesystem locks, private credential file permissions, and
//// browser listener supervision.
////
//// ## Flow
////
//// `discover` → `resolve_client_id` → `authorization_url` → `callback` →
//// `exchange_code` → `refresh`
////
//// 1. `valid_oauth_url` admits HTTPS endpoints and literal loopback HTTP
////    endpoints (`127.0.0.1`, `[::1]`) without userinfo or fragments.
//// 2. `discover` probes Protected Resource Metadata (`discover_protected_resource`,
////    `find_protected_resource`, `decode_protected_resource`) and Authorization
////    Server Metadata (`discover_auth_server`, `find_auth_server`,
////    `decode_auth_server`), requiring `S256` PKCE support when advertised.
//// 3. `resolve_client_id` selects a configured `client_id`, a matching saved
////    `Binding`, or Dynamic Client Registration (`register_client`).
//// 4. `authorization_url` builds the browser redirect URL with PKCE `S256` and
////    RFC 8707 `resource`; `callback` verifies `state` in constant time before
////    reading `error` or `code`.
//// 5. `exchange_code` and `refresh` call `token_request` with RFC 8707
////    `resource`, preserving scopes and rotating refresh tokens.
//// 6. `encode_bindings` and `decode_bindings` serialize and validate stored
////    credential files using `gleam_mcp/json` total decoders.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleam_mcp/internal/ffi_crypto
import gleam_mcp/json.{type JsonValue}

/// One outbound HTTP request issued during OAuth discovery, registration, or
/// token exchange.
pub type HttpRequest {
  /// The complete request envelope passed to the caller's HTTP client.
  HttpRequest(
    /// HTTP verb (`"GET"`, `"POST"`, `"DELETE"`).
    method: String,
    /// Validated target URL.
    url: String,
    /// Request header pairs.
    headers: List(#(String, String)),
    /// UTF-8 request body.
    body: String,
  )
}

/// One bounded HTTP response returned by `Services.fetch`.
pub type HttpResponse {
  /// The status, headers and bounded body of a completed HTTP response.
  HttpResponse(
    /// HTTP status code.
    status: Int,
    /// Lowercased or raw response headers.
    headers: List(#(String, String)),
    /// UTF-8 response body, bounded by the caller's byte limit.
    body: String,
  )
}

/// Injected effect callbacks for deterministic OAuth protocol execution.
pub type Services {
  /// The HTTP, clock and entropy callbacks supplied by the host.
  Services(
    /// Performs a redirect-refusing HTTP request bounded by the given byte cap.
    fetch: fn(HttpRequest, Int) -> Result(HttpResponse, String),
    /// Supplies the current wall-clock time in Unix milliseconds.
    now: fn() -> Int,
    /// Supplies cryptographically strong random bytes for PKCE and state.
    entropy: fn(Int) -> BitArray,
  )
}

/// An active OAuth 2.1 token grant for one remote MCP server.
pub type Grant {
  /// The bearer access token, optional refresh token, scopes and expiry.
  Grant(
    /// Bearer access token sent in `Authorization: Bearer <access>`.
    access: String,
    /// Optional refresh token used to rotate `access` when it expires.
    refresh: Option(String),
    /// Granted OAuth scopes.
    scopes: List(String),
    /// Expiration timestamp in Unix milliseconds.
    expires: Int,
  )
}

/// A saved OAuth 2.1 server registration and optional active grant.
pub type Binding {
  /// The persisted registration and optional token grant for one server.
  Binding(
    /// The configured MCP server name.
    server: String,
    /// The canonical MCP server URL (`resource` parameter in RFC 8707).
    resource: String,
    /// The authorization server's canonical issuer URL.
    issuer: String,
    /// The authorization server's token endpoint URL.
    token_endpoint: String,
    /// The pre-registered or dynamically registered OAuth `client_id`.
    client_id: String,
    /// The active token grant, or `None` after logout or refresh rejection.
    grant: Option(Grant),
  )
}

/// Discovered OAuth 2.1 endpoints for one remote MCP server.
pub type Metadata {
  /// The validated resource, issuer, endpoints and scopes for an OAuth flow.
  Metadata(
    /// The MCP server's canonical resource URL (RFC 8707).
    resource: String,
    /// The authorization server's canonical issuer URL.
    issuer: String,
    /// The browser authorization endpoint URL.
    authorization_endpoint: String,
    /// The token exchange and refresh endpoint URL.
    token_endpoint: String,
    /// Optional dynamic client registration endpoint URL (RFC 7591).
    registration_endpoint: Option(String),
    /// Scopes to request during authorization.
    scopes: List(String),
  )
}

/// The transaction values retained only by a pending browser login attempt.
pub type Attempt {
  /// The PKCE verifier, CSRF state and resolved client identifier.
  Attempt(
    /// Secret PKCE verifier, never placed in an authorization URL.
    verifier: String,
    /// One-use state checked in constant time before `code` or `error` is read.
    state: String,
    /// Resolved OAuth client identifier for this attempt.
    client_id: String,
  )
}

/// A state-checked browser callback ready for authorization-code exchange.
pub type Callback {
  /// The verified one-use authorization code returned to the loopback listener.
  Callback(
    /// The one-use authorization code.
    code: String,
  )
}

type Token {
  Token(
    access: String,
    refresh: Option(String),
    token_type: String,
    expires_in: Int,
    scopes: List(String),
  )
}

type ProtectedResource {
  ProtectedResource(
    resource: Option(String),
    authorization_servers: List(String),
    scopes_supported: List(String),
  )
}

type AuthServer {
  AuthServer(
    issuer: Option(String),
    authorization_endpoint: String,
    token_endpoint: String,
    registration_endpoint: Option(String),
    scopes_supported: List(String),
    code_challenge_methods_supported: Option(List(String)),
  )
}

/// Validates that an OAuth URL uses `https://` or literal loopback `http://`
/// (`127.0.0.1` or `[::1]`) with no userinfo or fragment.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.valid_oauth_url("https://mcp.example.com/v1")
/// assert oauth.valid_oauth_url("http://127.0.0.1:8080/mcp")
/// assert !oauth.valid_oauth_url("http://mcp.example.com/v1")
/// ```
pub fn valid_oauth_url(raw: String) -> Bool {
  case raw != "" && !string.contains(raw, "\n") && !string.contains(raw, "\r") {
    False -> False
    True ->
      case uri.parse(raw) {
        Error(_) -> False
        Ok(parsed) ->
          case parsed.scheme, parsed.host, parsed.userinfo, parsed.fragment {
            Some("https"), Some(host), None, None ->
              host != "" && valid_port(parsed.port)
            Some("http"), Some(host), None, None ->
              loopback_host(host) && valid_port(parsed.port)
            _, _, _, _ -> False
          }
      }
  }
}

fn loopback_host(host: String) -> Bool {
  host == "127.0.0.1" || host == "[::1]" || host == "::1"
}

fn valid_port(port: Option(Int)) -> Bool {
  case port {
    None -> True
    Some(value) -> value > 0 && value <= 65_535
  }
}

/// Generates a fresh 43-character URL-safe base64 PKCE secret or state token
/// from 32 random bytes.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(oauth.secret_token(<<0:size(256)>>)) == 43
/// ```
pub fn secret_token(random_bytes: BitArray) -> String {
  base64url(random_bytes)
}

/// The literal loopback URL an operator opens to begin the browser attempt.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.start_url(1455) == "http://127.0.0.1:1455/auth/start"
/// ```
pub fn start_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/auth/start"
}

/// Constructs the authorization server redirect URL with PKCE `S256` and
/// RFC 8707 `resource` binding.
///
/// ## Examples
///
/// ```gleam
/// // oauth.authorization_url(metadata, attempt, "http://127.0.0.1:1455/auth/callback")
/// ```
pub fn authorization_url(
  metadata: Metadata,
  attempt: Attempt,
  redirect_uri: String,
) -> String {
  let challenge =
    ffi_crypto.sha256(bit_array.from_string(attempt.verifier))
    |> base64url
  let scope_param = case metadata.scopes {
    [] -> []
    scopes -> [#("scope", string.join(scopes, " "))]
  }
  let params =
    list.append(
      [
        #("response_type", "code"),
        #("client_id", attempt.client_id),
        #("redirect_uri", redirect_uri),
        #("resource", metadata.resource),
      ],
      list.append(scope_param, [
        #("state", attempt.state),
        #("code_challenge", challenge),
        #("code_challenge_method", "S256"),
      ]),
    )
  let sep = case string.contains(metadata.authorization_endpoint, "?") {
    True -> "&"
    False -> "?"
  }
  metadata.authorization_endpoint <> sep <> uri.query_to_string(params)
}

/// Validates a loopback callback's state in constant time before reading `code`.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.callback(oauth.Attempt("v", "s", "c"), "state=s&code=abc")
///   == Ok(oauth.Callback("abc"))
/// ```
pub fn callback(attempt: Attempt, query: String) -> Result(Callback, String) {
  use <- bool.guard(
    when: string.byte_size(query) > 8192,
    return: Error("invalid_callback"),
  )
  use fields <- result.try(
    uri.parse_query(query) |> result.replace_error("invalid_callback"),
  )
  use state <- result.try(unique(fields, "state"))
  use <- bool.guard(
    when: !ffi_crypto.secure_compare(
      bit_array.from_string(state),
      bit_array.from_string(attempt.state),
    ),
    return: Error("invalid_callback"),
  )
  use <- bool.guard(
    when: list.key_find(fields, "error") != Error(Nil),
    return: Error("authorization_denied"),
  )
  use code <- result.try(unique(fields, "code"))
  Ok(Callback(code:))
}

fn unique(
  fields: List(#(String, String)),
  name: String,
) -> Result(String, String) {
  case list.filter(fields, fn(field) { field.0 == name }) {
    [#(_, value)] if value != "" -> Ok(value)
    [] | [_] | [_, _, ..] -> Error("invalid_callback")
  }
}

/// Discovers OAuth 2.1 endpoints for a remote MCP server URL.
///
/// Checks Protected Resource Metadata (RFC 9728) at the path-suffixed and root
/// `.well-known/oauth-protected-resource` endpoints, then Authorization Server
/// Metadata (RFC 8414) at `.well-known/oauth-authorization-server` and
/// `.well-known/openid-configuration`, falling back to standard `/authorize`,
/// `/token`, and `/register` routes at the authorization server origin when
/// discovery documents return 404.
///
/// ## Examples
///
/// ```gleam
/// // oauth.discover("https://mcp.example.com/mcp", services)
/// ```
pub fn discover(
  server_url: String,
  services: Services,
) -> Result(Metadata, String) {
  use <- bool.guard(
    when: !valid_oauth_url(server_url),
    return: Error("invalid_server_url"),
  )
  use #(origin, path) <- result.try(split_origin_and_path(server_url))
  use #(auth_server_url, prm_scopes) <- result.try(discover_protected_resource(
    server_url,
    origin,
    path,
    services,
  ))
  discover_auth_server(server_url, auth_server_url, prm_scopes, services)
}

fn discover_protected_resource(
  server_url: String,
  origin: String,
  path: String,
  services: Services,
) -> Result(#(String, List(String)), String) {
  let candidates = case path {
    "" | "/" -> [origin <> "/.well-known/oauth-protected-resource"]
    _ -> [
      origin <> "/.well-known/oauth-protected-resource" <> path,
      origin <> "/.well-known/oauth-protected-resource",
    ]
  }
  find_protected_resource(candidates, server_url, origin, services)
}

fn find_protected_resource(
  candidates: List(String),
  server_url: String,
  origin: String,
  services: Services,
) -> Result(#(String, List(String)), String) {
  case candidates {
    [] -> Ok(#(origin, []))
    [url, ..rest] ->
      case fetch_json(url, services) {
        Error("not_found") ->
          find_protected_resource(rest, server_url, origin, services)
        Error(reason) -> Error(reason)
        Ok(body) -> decode_protected_resource(body, server_url, origin)
      }
  }
}

fn decode_protected_resource(
  body: String,
  server_url: String,
  origin: String,
) -> Result(#(String, List(String)), String) {
  use prm <- result.try(
    json.parse(body)
    |> result.replace_error("invalid_protected_resource_metadata")
    |> result.try(decode_protected_resource_value),
  )
  use Nil <- result.try(validate_prm_resource(prm.resource, server_url, origin))
  case prm.authorization_servers {
    [first, ..] ->
      case valid_oauth_url(first) {
        True -> Ok(#(strip_trailing_slash(first), prm.scopes_supported))
        False -> Error("invalid_protected_resource_metadata")
      }
    [] -> Error("invalid_protected_resource_metadata")
  }
}

fn decode_protected_resource_value(
  value: JsonValue,
) -> Result(ProtectedResource, String) {
  use fields <- result.try(object_fields(
    value,
    "invalid_protected_resource_metadata",
  ))
  use resource <- result.try(optional_string(
    fields,
    "resource",
    "invalid_protected_resource_metadata",
  ))
  use authorization_servers <- result.try(optional_string_list(
    fields,
    "authorization_servers",
    "invalid_protected_resource_metadata",
  ))
  use scopes_supported <- result.try(optional_string_list(
    fields,
    "scopes_supported",
    "invalid_protected_resource_metadata",
  ))
  Ok(ProtectedResource(resource:, authorization_servers:, scopes_supported:))
}

fn validate_prm_resource(
  reported: Option(String),
  server_url: String,
  origin: String,
) -> Result(Nil, String) {
  case reported {
    None -> Ok(Nil)
    Some(value) -> {
      let trimmed = strip_trailing_slash(value)
      case
        trimmed == strip_trailing_slash(server_url)
        || trimmed == strip_trailing_slash(origin)
      {
        True -> Ok(Nil)
        False -> Error("protected_resource_mismatch")
      }
    }
  }
}

fn discover_auth_server(
  server_url: String,
  auth_server_url: String,
  prm_scopes: List(String),
  services: Services,
) -> Result(Metadata, String) {
  use #(as_origin, as_path) <- result.try(split_origin_and_path(auth_server_url))
  let candidates = case as_path {
    "" | "/" -> [
      as_origin <> "/.well-known/oauth-authorization-server",
      as_origin <> "/.well-known/openid-configuration",
    ]
    _ -> [
      as_origin <> "/.well-known/oauth-authorization-server" <> as_path,
      as_origin <> "/.well-known/openid-configuration" <> as_path,
      as_origin <> as_path <> "/.well-known/openid-configuration",
    ]
  }
  find_auth_server(
    candidates,
    server_url,
    auth_server_url,
    as_origin,
    prm_scopes,
    services,
  )
}

fn find_auth_server(
  candidates: List(String),
  server_url: String,
  auth_server_url: String,
  as_origin: String,
  prm_scopes: List(String),
  services: Services,
) -> Result(Metadata, String) {
  case candidates {
    [] ->
      Ok(Metadata(
        resource: server_url,
        issuer: auth_server_url,
        authorization_endpoint: as_origin <> "/authorize",
        token_endpoint: as_origin <> "/token",
        registration_endpoint: Some(as_origin <> "/register"),
        scopes: prm_scopes,
      ))
    [url, ..rest] ->
      case fetch_json(url, services) {
        Error("not_found") ->
          find_auth_server(
            rest,
            server_url,
            auth_server_url,
            as_origin,
            prm_scopes,
            services,
          )
        Error(reason) -> Error(reason)
        Ok(body) ->
          decode_auth_server(body, server_url, auth_server_url, prm_scopes)
      }
  }
}

fn decode_auth_server(
  body: String,
  server_url: String,
  auth_server_url: String,
  prm_scopes: List(String),
) -> Result(Metadata, String) {
  use parsed <- result.try(
    json.parse(body)
    |> result.replace_error("invalid_auth_server_metadata")
    |> result.try(decode_auth_server_value),
  )
  use Nil <- result.try(check_pkce_methods(
    parsed.code_challenge_methods_supported,
  ))
  let issuer =
    option.unwrap(parsed.issuer, auth_server_url) |> strip_trailing_slash
  use Nil <- result.try(check_auth_server_urls(issuer, parsed))
  let base_scopes = case prm_scopes {
    [] -> parsed.scopes_supported
    _ -> prm_scopes
  }
  let scopes = case
    list.contains(parsed.scopes_supported, "offline_access")
    && !list.contains(base_scopes, "offline_access")
  {
    True -> list.append(base_scopes, ["offline_access"])
    False -> base_scopes
  }
  Ok(Metadata(
    resource: server_url,
    issuer:,
    authorization_endpoint: parsed.authorization_endpoint,
    token_endpoint: parsed.token_endpoint,
    registration_endpoint: parsed.registration_endpoint,
    scopes:,
  ))
}

fn check_pkce_methods(methods: Option(List(String))) -> Result(Nil, String) {
  case methods {
    None -> Ok(Nil)
    Some(supported) ->
      case list.contains(supported, "S256") {
        True -> Ok(Nil)
        False -> Error("pkce_s256_unsupported")
      }
  }
}

fn check_auth_server_urls(
  issuer: String,
  parsed: AuthServer,
) -> Result(Nil, String) {
  let valid_reg = case parsed.registration_endpoint {
    None -> True
    Some(reg) -> valid_oauth_url(reg)
  }
  case
    valid_oauth_url(issuer)
    && valid_oauth_url(parsed.authorization_endpoint)
    && valid_oauth_url(parsed.token_endpoint)
    && valid_reg
  {
    True -> Ok(Nil)
    False -> Error("invalid_auth_server_metadata")
  }
}

fn decode_auth_server_value(value: JsonValue) -> Result(AuthServer, String) {
  let fault = "invalid_auth_server_metadata"
  use fields <- result.try(object_fields(value, fault))
  use issuer <- result.try(optional_string(fields, "issuer", fault))
  use authorization_endpoint <- result.try(required_string(
    fields,
    "authorization_endpoint",
    fault,
  ))
  use token_endpoint <- result.try(required_string(
    fields,
    "token_endpoint",
    fault,
  ))
  use registration_endpoint <- result.try(optional_string(
    fields,
    "registration_endpoint",
    fault,
  ))
  use scopes_supported <- result.try(optional_string_list(
    fields,
    "scopes_supported",
    fault,
  ))
  use code_challenge_methods_supported <- result.try(
    case list.key_find(fields, "code_challenge_methods_supported") {
      Error(Nil) | Ok(json.Null) -> Ok(None)
      Ok(json.Array(items)) ->
        list.try_map(items, fn(item) { string_value(item, fault) })
        |> result.map(Some)
      Ok(_) -> Error(fault)
    },
  )
  Ok(AuthServer(
    issuer:,
    authorization_endpoint:,
    token_endpoint:,
    registration_endpoint:,
    scopes_supported:,
    code_challenge_methods_supported:,
  ))
}

/// Resolves the OAuth `client_id` for a login attempt from a pre-configured ID,
/// a matching saved `Binding`, or RFC 7591 Dynamic Client Registration.
///
/// ## Examples
///
/// ```gleam
/// // oauth.resolve_client_id(None, metadata, Some("pre-reg"), redirect, "Loom", services)
/// //   == Ok("pre-reg")
/// ```
pub fn resolve_client_id(
  stored: Option(Binding),
  metadata: Metadata,
  configured_client_id: Option(String),
  redirect_uri: String,
  client_name: String,
  services: Services,
) -> Result(String, String) {
  case configured_client_id {
    Some(client_id) -> Ok(client_id)
    None ->
      case stored {
        Some(existing)
          if existing.resource == metadata.resource
          && existing.issuer == metadata.issuer
        -> Ok(existing.client_id)
        _ ->
          register_client(
            metadata.registration_endpoint,
            redirect_uri,
            client_name,
            services,
          )
      }
  }
}

/// Dynamically registers a public loopback OAuth client (RFC 7591).
///
/// ## Examples
///
/// ```gleam
/// // oauth.register_client(metadata.registration_endpoint, redirect, "Loom", services)
/// ```
pub fn register_client(
  registration_endpoint: Option(String),
  redirect_uri: String,
  client_name: String,
  services: Services,
) -> Result(String, String) {
  use endpoint <- result.try(option.to_result(
    registration_endpoint,
    "client_id_required",
  ))
  let body =
    json.Object([
      #("client_name", json.String(client_name)),
      #("redirect_uris", json.Array([json.String(redirect_uri)])),
      #(
        "grant_types",
        json.Array([
          json.String("authorization_code"),
          json.String("refresh_token"),
        ]),
      ),
      #("response_types", json.Array([json.String("code")])),
      #("token_endpoint_auth_method", json.String("none")),
    ])
    |> json.to_string
  use resp <- result.try(services.fetch(
    HttpRequest(
      "POST",
      endpoint,
      [
        #("content-type", "application/json"),
        #("accept", "application/json"),
      ],
      body,
    ),
    65_536,
  ))
  use <- bool.guard(
    when: resp.status != 200 && resp.status != 201,
    return: Error("client_registration_failed"),
  )
  use parsed <- result.try(
    json.parse(resp.body)
    |> result.replace_error("invalid_client_registration"),
  )
  use fields <- result.try(object_fields(parsed, "invalid_client_registration"))
  use client_id <- result.try(required_string(
    fields,
    "client_id",
    "invalid_client_registration",
  ))
  use <- bool.guard(
    when: !valid_identifier(client_id),
    return: Error("invalid_client_registration"),
  )
  Ok(client_id)
}

/// Exchanges a verified callback code for a `Binding` with an active `Grant`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.exchange_code("linear", metadata, attempt, redirect, callback, services)
/// ```
pub fn exchange_code(
  server: String,
  metadata: Metadata,
  attempt: Attempt,
  redirect_uri: String,
  received: Callback,
  services: Services,
) -> Result(Binding, String) {
  use token <- result.try(token_request(
    metadata.token_endpoint,
    [
      #("grant_type", "authorization_code"),
      #("client_id", attempt.client_id),
      #("code", received.code),
      #("code_verifier", attempt.verifier),
      #("redirect_uri", redirect_uri),
      #("resource", metadata.resource),
    ],
    services,
  ))
  let scopes = case token.scopes {
    [] -> metadata.scopes
    granted -> granted
  }
  Ok(Binding(
    server:,
    resource: metadata.resource,
    issuer: metadata.issuer,
    token_endpoint: metadata.token_endpoint,
    client_id: attempt.client_id,
    grant: Some(Grant(
      access: token.access,
      refresh: token.refresh,
      scopes:,
      expires: services.now() + token.expires_in * 1000,
    )),
  ))
}

/// Refreshes an expired grant at the authorization server's token endpoint.
///
/// ## Examples
///
/// ```gleam
/// // oauth.refresh(binding, services)
/// ```
pub fn refresh(
  binding: Binding,
  services: Services,
) -> Result(Binding, String) {
  use previous <- result.try(option.to_result(binding.grant, "not_logged_in"))
  use refresh_token <- result.try(option.to_result(
    previous.refresh,
    "reauthorization_required",
  ))
  use token <- result.try(token_request(
    binding.token_endpoint,
    [
      #("grant_type", "refresh_token"),
      #("client_id", binding.client_id),
      #("refresh_token", refresh_token),
      #("resource", binding.resource),
    ],
    services,
  ))
  let next_refresh = case token.refresh {
    Some(_) -> token.refresh
    None -> previous.refresh
  }
  let next_scopes = case token.scopes {
    [] -> previous.scopes
    scopes -> scopes
  }
  Ok(
    Binding(
      ..binding,
      grant: Some(Grant(
        access: token.access,
        refresh: next_refresh,
        scopes: next_scopes,
        expires: services.now() + token.expires_in * 1000,
      )),
    ),
  )
}

/// Verifies that a saved `Binding` still matches the server's configured
/// `resource` URL and optional `client_id`.
///
/// ## Examples
///
/// ```gleam
/// // oauth.check_binding_config(binding, "https://mcp.example.com/mcp", None)
/// ```
pub fn check_binding_config(
  binding: Binding,
  server_url: String,
  configured_client_id: Option(String),
) -> Result(Nil, String) {
  use <- bool.guard(
    when: binding.resource != server_url,
    return: Error("resource_mismatch"),
  )
  case configured_client_id {
    None -> Ok(Nil)
    Some(expected) ->
      case binding.client_id == expected {
        True -> Ok(Nil)
        False -> Error("client_id_mismatch")
      }
  }
}

/// Words an OAuth error code for an operator log line or in-band refusal,
/// never quoting a token value.
///
/// ## Examples
///
/// ```gleam
/// assert string.contains(
///   oauth.describe_auth_error("linear", "loomd mcp login", "not_logged_in"),
///   "loomd mcp login linear",
/// )
/// ```
pub fn describe_auth_error(
  server: String,
  login_command: String,
  code: String,
) -> String {
  let suffix = "; run `" <> login_command <> " " <> server <> "`"
  case code {
    "not_logged_in" -> "its OAuth credential is not signed in" <> suffix
    "reauthorization_required" ->
      "the OAuth token for mcp."
      <> server
      <> " expired and requires reauthorization"
      <> suffix
    "resource_mismatch" | "client_id_mismatch" ->
      "its saved OAuth registration does not match the current configuration"
      <> suffix
    other ->
      "its OAuth credential could not be resolved (" <> other <> ")" <> suffix
  }
}

/// Encodes a list of OAuth `Binding`s to a versioned JSON document.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.decode_bindings(oauth.encode_bindings([])) == Ok([])
/// ```
pub fn encode_bindings(bindings: List(Binding)) -> String {
  json.Object([
    #("version", json.Int(1)),
    #("servers", json.Array(list.map(bindings, encode_binding))),
  ])
  |> json.to_string
  <> "\n"
}

fn encode_binding(binding: Binding) -> JsonValue {
  let base = [
    #("server", json.String(binding.server)),
    #("resource", json.String(binding.resource)),
    #("issuer", json.String(binding.issuer)),
    #("token_endpoint", json.String(binding.token_endpoint)),
    #("client_id", json.String(binding.client_id)),
  ]
  let with_grant = case binding.grant {
    None -> base
    Some(grant) ->
      list.append(base, [
        #("access", json.String(grant.access)),
        #("refresh", case grant.refresh {
          Some(refresh) -> json.String(refresh)
          None -> json.Null
        }),
        #("scopes", json.Array(list.map(grant.scopes, json.String))),
        #("expires", json.Int(grant.expires)),
      ])
  }
  json.Object(with_grant)
}

/// Decodes and validates a versioned JSON document of OAuth `Binding`s.
///
/// ## Examples
///
/// ```gleam
/// assert oauth.decode_bindings("{\"version\":1,\"servers\":[]}") == Ok([])
/// ```
pub fn decode_bindings(text: String) -> Result(List(Binding), String) {
  let fault = "mcp credentials could not be decoded"
  use root <- result.try(json.parse(text) |> result.replace_error(fault))
  use fields <- result.try(object_fields(root, fault))
  use version <- result.try(case list.key_find(fields, "version") {
    Ok(json.Int(version)) -> Ok(version)
    _ -> Error(fault)
  })
  use <- bool.guard(
    when: version != 1,
    return: Error("unsupported mcp credentials version"),
  )
  use servers <- result.try(case list.key_find(fields, "servers") {
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) { decode_binding_value(item, fault) })
    _ -> Error(fault)
  })
  let names = list.map(servers, fn(item) { item.server })
  use <- bool.guard(
    when: names != list.unique(names),
    return: Error("duplicate mcp server entry in credentials file"),
  )
  Ok(servers)
}

fn decode_binding_value(
  value: JsonValue,
  fault: String,
) -> Result(Binding, String) {
  use fields <- result.try(object_fields(value, fault))
  use server <- result.try(required_string(fields, "server", fault))
  use resource <- result.try(required_string(fields, "resource", fault))
  use issuer <- result.try(required_string(fields, "issuer", fault))
  use token_endpoint <- result.try(required_string(
    fields,
    "token_endpoint",
    fault,
  ))
  use client_id <- result.try(required_string(fields, "client_id", fault))
  use access <- result.try(optional_string(fields, "access", fault))
  use refresh <- result.try(optional_string(fields, "refresh", fault))
  use scopes <- result.try(optional_string_list(fields, "scopes", fault))
  use expires <- result.try(optional_int(fields, "expires", fault))
  use grant <- result.try(validate_decoded_grant(
    access,
    refresh,
    scopes,
    expires,
  ))
  use <- bool.guard(
    when: !valid_identifier(server)
      || !valid_oauth_url(resource)
      || !valid_oauth_url(issuer)
      || !valid_oauth_url(token_endpoint)
      || !valid_identifier(client_id),
    return: Error("invalid mcp credential record"),
  )
  Ok(Binding(server:, resource:, issuer:, token_endpoint:, client_id:, grant:))
}

fn validate_decoded_grant(
  access: Option(String),
  refresh: Option(String),
  scopes: List(String),
  expires: Option(Int),
) -> Result(Option(Grant), String) {
  case access, expires {
    None, None -> Ok(None)
    Some(token), Some(exp) ->
      case
        valid_secret(token)
        && exp > 0
        && valid_optional_secret(refresh)
        && list.all(scopes, valid_scope)
      {
        True -> Ok(Some(Grant(access: token, refresh:, scopes:, expires: exp)))
        False -> Error("invalid mcp token grant in credentials file")
      }
    _, _ -> Error("incomplete mcp token grant in credentials file")
  }
}

fn valid_identifier(value: String) -> Bool {
  value != ""
  && string.byte_size(value) <= 256
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_secret(value: String) -> Bool {
  value != ""
  && string.byte_size(value) <= 16_384
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn valid_optional_secret(value: Option(String)) -> Bool {
  case value {
    None -> True
    Some(secret) -> valid_secret(secret)
  }
}

fn valid_scope(value: String) -> Bool {
  value != ""
  && string.byte_size(value) <= 256
  && !string.contains(value, " ")
  && !string.contains(value, "\n")
  && !string.contains(value, "\r")
}

fn token_request(
  token_endpoint: String,
  fields: List(#(String, String)),
  services: Services,
) -> Result(Token, String) {
  use resp <- result.try(services.fetch(
    HttpRequest(
      "POST",
      token_endpoint,
      [
        #("content-type", "application/x-www-form-urlencoded"),
        #("accept", "application/json"),
      ],
      uri.query_to_string(fields),
    ),
    65_536,
  ))
  use Nil <- result.try(case resp.status {
    200 -> Ok(Nil)
    status -> Error(token_error(status, resp.body))
  })
  use token <- result.try(
    json.parse(resp.body)
    |> result.replace_error("invalid_token_response")
    |> result.try(decode_token_value),
  )
  use <- bool.guard(
    when: token.access == ""
      || token.refresh == Some("")
      || string.lowercase(token.token_type) != "bearer"
      || token.expires_in <= 0
      || token.expires_in > 31_536_000,
    return: Error("invalid_token_response"),
  )
  Ok(token)
}

fn decode_token_value(value: JsonValue) -> Result(Token, String) {
  let fault = "invalid_token_response"
  use fields <- result.try(object_fields(value, fault))
  use access <- result.try(required_string(fields, "access_token", fault))
  use refresh <- result.try(optional_string(fields, "refresh_token", fault))
  use token_type <- result.try(required_string(fields, "token_type", fault))
  use expires_in <- result.try(
    optional_int(fields, "expires_in", fault)
    |> result.map(option.unwrap(_, 3600)),
  )
  use scope_opt <- result.try(optional_string(fields, "scope", fault))
  let scopes =
    option.unwrap(scope_opt, "")
    |> string.split(" ")
    |> list.filter(fn(scope) { scope != "" })
  Ok(Token(access:, refresh:, token_type:, expires_in:, scopes:))
}

fn token_error(status: Int, body: String) -> String {
  let code =
    json.parse(body)
    |> result.replace_error(Nil)
    |> result.try(extract_error_code)
  case code, status {
    Ok("invalid_client"), _ -> "invalid_client"
    Ok("invalid_grant"), _
    | Ok("invalid_refresh_token"), _
    | Ok("token_expired"), _
    | Ok("refresh_token_expired"), _
    | Ok("refresh_token_invalidated"), _
    | Ok("refresh_token_reused"), _
    | Ok("unauthorized_client"), _
    | _, 400
    | _, 401
    | _, 403
    -> "reauthorization_required"
    _, _ -> "token_endpoint_unavailable"
  }
}

fn extract_error_code(value: JsonValue) -> Result(String, Nil) {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "error") {
        Ok(json.String(code)) -> Ok(code)
        Ok(json.Object(inner)) ->
          case list.key_find(inner, "code") {
            Ok(json.String(code)) -> Ok(code)
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn fetch_json(url: String, services: Services) -> Result(String, String) {
  use resp <- result.try(services.fetch(
    HttpRequest("GET", url, [#("accept", "application/json")], ""),
    65_536,
  ))
  case resp.status {
    200 -> Ok(resp.body)
    404 -> Error("not_found")
    _ -> Error("discovery_unavailable")
  }
}

fn split_origin_and_path(raw: String) -> Result(#(String, String), String) {
  use parsed <- result.try(
    uri.parse(raw) |> result.replace_error("invalid_server_url"),
  )
  use #(scheme, host) <- result.try(case parsed.scheme, parsed.host {
    Some(scheme), Some(host) if host != "" -> Ok(#(scheme, host))
    _, _ -> Error("invalid_server_url")
  })
  let port_suffix = case parsed.port {
    None -> ""
    Some(port) -> ":" <> int.to_string(port)
  }
  let origin = scheme <> "://" <> host <> port_suffix
  let path = strip_trailing_slash(parsed.path)
  Ok(#(origin, path))
}

fn strip_trailing_slash(value: String) -> String {
  case string.ends_with(value, "/") && value != "/" {
    True -> string.drop_end(value, 1)
    False -> value
  }
}

fn base64url(bytes: BitArray) -> String {
  bit_array.base64_encode(bytes, False)
  |> string.replace("+", "-")
  |> string.replace("/", "_")
  |> string.replace("=", "")
}

fn object_fields(
  value: JsonValue,
  fault: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(fault)
  }
}

fn string_value(value: JsonValue, fault: String) -> Result(String, String) {
  case value {
    json.String(text) -> Ok(text)
    _ -> Error(fault)
  }
}

fn required_string(
  fields: List(#(String, JsonValue)),
  key: String,
  fault: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Ok(text)
    _ -> Error(fault)
  }
}

fn optional_string(
  fields: List(#(String, JsonValue)),
  key: String,
  fault: String,
) -> Result(Option(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.String(text)) -> Ok(Some(text))
    Ok(_) -> Error(fault)
  }
}

fn optional_int(
  fields: List(#(String, JsonValue)),
  key: String,
  fault: String,
) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(json.Int(number)) -> Ok(Some(number))
    Ok(_) -> Error(fault)
  }
}

fn optional_string_list(
  fields: List(#(String, JsonValue)),
  key: String,
  fault: String,
) -> Result(List(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok([])
    Ok(json.Array(items)) ->
      list.try_map(items, fn(item) { string_value(item, fault) })
    Ok(_) -> Error(fault)
  }
}
