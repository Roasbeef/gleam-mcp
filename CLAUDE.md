# Gleam MCP

Read `docs/next.md` before planning work and `docs/gleam-style.md` before
writing code. [Architecture](docs/architecture.md) supplies a source reading
path and custody map; [principles](docs/principles.md) applies the literate
Gleam rules to this standalone package. This repository inherits Loom's
literate Gleam style, total decoders, caller-owned effects, and house-rule
linter.

## Working here

Use Gleam >= 1.19 and Erlang/OTP >= 29. `make check` runs formatting, a
warning-free build, tests, the copied custom linter, and documentation checks.
`make fmt` formats the application and linter. Verify commands by their own
exit status. Public functions include examples; module documentation explains
ownership, transitions and failure behavior. Large modules include a `Flow`
section naming the execution path. State and message types precede their
implementation section, and critical lifetime machines include transition
tables. Qualified domain calls expose ownership; helpers name actual protocol
work rather than wrapping another call for cosmetic structure. Comments are
complete sentences with a blank line above them. Chain fallible steps with `use` and `result.try`.
Use opaque smart constructors for invariants, and domain variants for flags.

The application is an Erlang runtime package. Loom-specific rules in the
copied style guide about its broker, capabilities and frozen interfaces do
not create dependencies here. The pure wire modules remain free of effects;
`scripts/check_source.py` enforces their boundary. Custom Erlang FFI stays in
`internal/ffi_*.gleam` with the reason no maintained Gleam library suffices.
Process ownership and deadline machinery use weft when needed.

The copied linter retains Loom's R0 through R12 rules and promotion levels.
R0, R2, R4 and R10 apply to root source. R6 recognizes Loom's
`packages/core`, `packages/machine` and `packages/prompt` layout; the explicit
source gate owns pure-module enforcement in this standalone package.

## Changes and verification

Preserve unrelated work. Brief parallel workers with disjoint file ownership.
Make incremental commits with the repository owner's Git identity and no AI
attribution. Commit messages use `subsystem: imperative summary`, followed by
prose explaining why. Keep dependency locks and copied tooling separate from
application commits. Update `docs/next.md` and these mirrored package docs
when types, messages or dependencies change. Run one independent adversarial
review before declaring substantive work complete.

## Package boundary

`gleam_mcp/json` and `corruption` own strict values and bounded decoding
reports. `jsonrpc`, `protocol` and `stdio` own wire messages and framing.
`schema.Schema` compiles Draft 2020-12 assertions and offline resources;
`codec.Codec(a)` validates custom encoding and decoding against that schema.
`tool.Tool(args, output)` couples both codecs to a validated name and a
request-bound result decoder. `server.bind` admits a typed handler through
that same definition. Internal schema modules remain inside the pure gate.

`metadata`, `version`, `discovery`, `mrtr`, and `subscription` own the modern
request contracts. `request.Endpoint` binds a caller-owned exchange and
schema admission. `client.Continuation(output)` preserves the original
endpoint, arguments, output codec, and opaque state across explicit resumes.
`client` and `transport` own native client actors, pending request correlation,
and process-exit evidence. `server` owns the immutable tool registry and
profile dispatch; `server_stdio` owns scoped readers, writers, and handlers.

`http` and `http_headers` admit mirrored metadata before effects; `sse` frames
bounded byte chunks. `client_http` adopts Gun connections before sending;
`server_http` transfers Mist sockets before admitting a handler scope and
drains that scope after disconnect. Custom FFI translates maintained native
calls and close messages; the Gleam runtime owns policy and lifetime.

HTTP startup registers Mist's SSE factory before Glisten starts, and
Glisten's connection factory before its listener and acceptors start.
Reverse shutdown ends admission before retiring those factories. Public
Git pins for both libraries preserve that order and Mist's framing refusal;
[protocol contracts](docs/protocol.md#http-dependencies) record the exact
commits and [upstream issue #55](https://github.com/rawhat/glisten/issues/55).

Nothing depends on Loom core or capabilities. A tool handler owns argument
domain validation and its external effects. Callback cancellation proves worker
termination, not rollback of a remote effect. Raw non-text content remains
in the generic protocol value so consumers own any reduction policy.
