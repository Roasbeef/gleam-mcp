# Design and literate Gleam principles

We keep the contract, dispatch and transport boundaries explicit so a reader
can trace one tool call without reconstructing hidden ownership. The
[architecture guide](architecture.md) follows that call through the source;
[protocol contracts](protocol.md) record its wire rules. The inherited
[Gleam style guide](gleam-style.md) supplies language idioms, while this document
applies them to this standalone SDK rather than Loom's UI or broker.

## Put invariants in construction

A typed tool binds one name, argument codec and output codec.
`tool.new` checks the name and input root before returning an opaque value.
`codec.Codec(a)` holds both callbacks and a compiled schema; neither custom
callback can replace that schema through the public API. `server.new` refuses
duplicate names before any tool can execute. These construction checks keep
later call sites small.

Construction doesn't make received bytes trustworthy. `mrtr.Required` checks
suspension shape, and an opaque client continuation retains the original call
contract. A server receiving `requestState` still has to validate any authority
encoded in it. Descriptive client identity, tool descriptions and schemas aren't
authentication or permission to perform effects.

## Keep values pure and effects owned

Wire framing, JSON-RPC envelopes, schema compilation and subscription admission
operate on values. The source-boundary gate in
[scripts/check_source.py](../scripts/check_source.py) keeps the designated pure
modules free of effect imports and externals. The runtime package still targets
Erlang; a pure boundary doesn't imply the whole SDK runs in a browser.

`request.Endpoint` is a caller-owned exchange. Native adapters put lifetime
under an actor or weft scope. A callback parks before work begins until its
owner is retained, and normal retirement consumes the relevant exit witness.
A final answer and resource retirement are separate events. Cancellation proves
local worker termination, with application cleanup obligations for remote work.
A transport failure never silently retries a tool effect.

## Read the flow before the helpers

Large module documentation includes a `Flow` section naming the function chain
in execution order. It identifies admission, effects and retirement rather than
listing declarations alphabetically. Multiple entry points get separate paths:
legacy initialize and modern request dispatch differ, as do JSON bodies and SSE.
Critical state machines have compact transition tables beside that flow.

Declarations follow call flow where that helps navigation, roughly depth first.
State, message and effect types precede the implementation that consumes them;
large modules can keep separate typed and native sections with their own types.
A comment-only pass need not reorder existing declarations to satisfy a
cosmetic rule. Reordering becomes useful when a reader otherwise has to jump
between responsibilities, and stays a separate behavior-preserving review.

Use qualified domain calls such as `schema.validate`, `subscription.accept`
and `request.exchange`. The module name exposes which boundary owns a check or
effect. Name helpers for the protocol work they own. A small domain helper can
remove a repeated decision; a one-line wrapper that only renames another call
adds another jump without explaining anything.

## Explain the order the type can't express

A useful comment states why work belongs here, what invariant the order
preserves, and what failure means to the caller. The ready event in
`server_stdio.admit_handler` cannot release a callback before its witnessed
scope is retained. The output answer is retained before worker release, then
normal scope exit authorizes publication. Comments belong at both sides of
those handoffs so moving either side makes the broken invariant visible.

For a timeout, distinguish reporting delay, request expiry, cancellation and
retirement evidence. For a validation failure, distinguish malformed envelope,
invalid arguments, visible tool failure and invalid successful output. A comment
that says only "send the message" or "validate the value" leaves the reasoning
with the reader.

Keep comments in paragraphs with blank lines above them, complete sentences
and concrete function names. Public types, variants and fields explain their
invariants; public functions include examples. Tiny accessors can rely on those
contracts, while recursion and branching need prose at the transition where
intent would otherwise be hidden. Comments describe verified behavior and
explicit limits, including paths that can't prove normal retirement.

## Learn the Gleam expressions at the boundary

`use value <- result.try(check())` passes the rest of its block as the success
callback. An `Error` propagates without running later steps. The chain makes
admission order visible; `case` remains appropriate for domain variants and
cleanup paths with different obligations.

`Record(..record, field: replacement)` builds a new immutable record. A child
schema evaluation can change its path and dynamic scope without mutating the
parent. The remaining allowance is different: the returned `Evaluated` carries
its updated count even on failure, so branches spend one shared budget.

`pub opaque type Codec(a)` exports the type but hides its constructor. `a`
connects the encoder and decoder statically; it doesn't prove their semantic
laws. Function values can close over the original arguments, which is how
request-bound result checks survive an explicit continuation. Read those
closures as retained contracts, with their captured values and lifetimes.

## Verify claims at the boundary they concern

Required JSON Schema vectors establish the recorded dialect coverage. Native
stdio and HTTP tests establish pipe, socket and custody behavior that pure unit
tests can't observe. A green test doesn't imply unsupported optional features,
arbitrary ECMAScript equivalence, a regex wall-clock bound, or effect rollback.
The [handoff](next.md) keeps validation claims tied to the tree and run that
produced them, with residual gaps left explicit.

A documentation pass can compare executable tokens against its base after
removing comments, whitespace and formatter-added trailing commas. That check
catches accidental code changes; it doesn't verify prose. Review each ownership
claim against its actual caller, transition and retirement path, then run
`make check` and capture that command's own exit status.
