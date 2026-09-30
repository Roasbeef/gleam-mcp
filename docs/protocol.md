# Protocol and ownership contracts

The modern profile is the released MCP `2026-07-28` specification, pinned from
[modelcontextprotocol/modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/046fa30efd374370afb87ef830bd788eac5f217e)
at `046fa30efd374370afb87ef830bd788eac5f217e`. The compatibility profiles retain
`2025-06-18` and `2024-11-05` over stdio. These profiles have different lifecycles;
a modern request doesn't inherit a legacy initialization session.

## Typed tools

A `codec.Codec(a)` binds a compiled `schema.Schema` to typed encoding and
decoding. Encoding validates the emitted JSON, including custom encoders.
Decoding validates the received JSON before the custom decoder runs. A
`tool.Tool(args, output)` binds the method name, input codec, and output codec.
Both client and server consume that same definition.

`server.bind` admits a typed handler through the definition's input contract,
then checks its emitted output. `client.call` obtains argument encoding and
result decoding from the definition. `tool.with_result_decoder` ties domain
validation to the original arguments. A Choice decoder can therefore reject a
label that belongs to another request even when both outputs satisfy the same
structural JSON Schema.

The raw client path remains available for dynamic discovery and Loom's
capability adapter. Its JSON values aren't substitutes for a known typed tool
in ordinary application code. Descriptions and schemas explain a tool to its
consumer; they don't confer authority to run its effects.

## Modern request patterns

Each modern request carries protocol version, client capabilities, and client
identity through `_meta`. Discovery and listing results carry their result
kind and cache hints. Server identity is returned through result metadata.
Protocol errors retain structured error data, and an uncorrelated error isn't
assigned a fabricated request id.

The base protocol includes request/response, multi-round-trip requests, and
subscriptions even in a tools-only server. A completed tool error belongs in
an `isError` result; an unknown tool or malformed request remains a protocol
error. Optional providers aren't implied by support for the base envelopes.

An `input_required` result ends that attempt. The client returns an opaque
continuation that retains the original endpoint, arguments, output decoder,
version, and latest opaque state. The application supplies responses through
`mrtr.responses` and explicitly calls `client.resume`. It can't select another
endpoint or replace the result contract during resumption. A new request id
identifies the new attempt. Missing opaque state stays absent.

The server receives opaque state as untrusted request input. Applications that
put authorization or business state in it must supply their own integrity and
freshness validation. An opaque Gleam type doesn't authenticate bytes received
from another process. Jevelin's four tools complete in one round trip and need
no continuation authority.

A subscription is a live, owned request. Its acknowledgment identifies the
subscription and accepted filter. An immutable tools catalog can accept an
empty filter without claiming dynamic tool-list notifications. Cancellation
and stream close retire the request scope; worker exit proves local retirement,
not rollback of an external effect.

## HTTP transport

Modern HTTP uses one POST endpoint. `Accept` admits JSON and event streams.
Protocol version, method, and applicable name headers derive from the same JSON
body that is sent. `x-mcp-header` annotations compile into a checked header
plan; malformed plans fail client admission. Server mirror validation precedes
handler admission. Unsafe string values use the specified Base64 sentinel.

The listener binds loopback and requires the host to choose an admission
policy. A present Origin must match the explicit allowlist, including before
routing and authentication. Origin validation and authentication are separate
checks. Descriptive client identity isn't authentication.

Mist owns HTTP parsing and listener supervision. A stream actor receives
socket ownership before admitting its weft handler scope. Native socket-close
messages initiate cancellation; the actor waits for the scope's drained
verdict before it stops. The narrow socket adapter translates close events
that Mist's public SSE API doesn't expose.

Gun owns client HTTP/TLS parsing and flow control. A connection is adopted by
the request scope before the POST. Retries are disabled. Incremental SSE
framing bounds event bytes and handles split UTF-8, comments, and multiline
data. A missing final correlated result leaves execution outcome unknown;
the library doesn't replay a tool effect after a disconnect or timeout.
HTTP uses no session ids, event replay, or deprecated GET event channel.

The native Gun shim translates maintained library calls and events; Gleam
owns deadlines, framing, correlation, and custody. Native process identifiers
are internal resources, not publicly forgeable transport handles.

## JSON Schema coverage

The default dialect is Draft 2020-12. Schemas compile against an offline
resource registry, including the official metaschemas. External references
aren't fetched automatically. Unsupported dialects, unknown required
vocabularies, and complexity exhaustion are typed construction refusals.
Validation charges work across branches and tracks evaluated locations for
`unevaluatedProperties` and `unevaluatedItems`.

The ordinary test gate includes all 1,301 required vectors at the pinned
upstream suite revision, with zero skips. See
[the corpus record](../test/fixtures/json_schema/UPSTREAM.md) for the full
optional probe, supported regex subset, annotations, licenses, exact pins,
and logical work limits. Optional Format-Assertion is absent. Unsupported
regex forms are refused during construction. Logical budgets don't establish
a native regex wall-clock deadline.

See [optional features](extensions.md) for resources, prompts, providers,
OAuth flows, and other extensions outside the current tools scope.
