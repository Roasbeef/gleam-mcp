# Optional MCP features

The current implementation work focuses on tools, the base protocol, and
stdio and HTTP transports. The protocol baseline is the released
[2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28),
checked out from `modelcontextprotocol/modelcontextprotocol` at
`046fa30efd374370afb87ef830bd788eac5f217e`.

An omitted server capability is a statement that the feature isn't available.
The client and server should agree on capabilities through discovery and
per-request metadata. A generic JSON-RPC transport doesn't by itself implement
any of the features below.

## Resources and prompts

[Issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1) tracks resources and
prompts for both the client and server. Resources supply URI-addressed context
through `resources/list`, `resources/templates/list`, and `resources/read`.
Their contents may be text or binary, with MIME types and annotations. Hosts
choose how to incorporate this context. A URI is an identifier, not permission
for the library to fetch an arbitrary file or network location.

Prompts supply named message templates through `prompts/list` and
`prompts/get`. A user selects a prompt and supplies its arguments. The template
returns messages with explicit roles and content. Typed definitions should
bind argument validation and message construction, just as a typed tool binds
its arguments and result decoder.

The follow-up includes pagination, caching, capability negotiation, and
optional change notifications through the base subscription protocol.
Resource update subscriptions and list-change notifications require their own
advertised capabilities. Argument completion remains a separately scoped
optional feature. Possible Jevelin examples are a model catalog resource and
a criteria-design prompt; the library doesn't require those application
features.

## Client providers

Sampling lets a server ask the client to generate model output. Elicitation
lets it request structured input from a user. Roots let a client disclose the
resource locations it wants a server to consider. These provider APIs need
typed request and response definitions, explicit host admission, and tests of
the permissions exercised by the provider. Their absence shouldn't prevent a
tools-only client from handling the mandatory base request patterns.

Base support for a result that requires further input doesn't imply that a
client implements every provider. A continuation preserves the original
endpoint, arguments, and result contract. The application chooses when to
resume it and supplies the required input; the library mustn't silently
repeat an effect after an interrupted exchange.

## Other extensions

OAuth authorization flows, provider-specific delegation, argument completion,
logging, and application extensions require separate implementation and
conformance work. HTTP deployments need a host-supplied authentication and
authorization policy even when OAuth discovery and token flows are absent.
Transport admission and browser Origin validation serve different purposes
from application authorization.

The existing stdio compatibility profiles don't promise support for every
historical MCP transport. Deprecated HTTP+SSE endpoints, session identifiers,
and event replay aren't implied by support for the current HTTP transport.
Tasks and experimental extensions likewise need an explicit feature decision
before they are advertised.
