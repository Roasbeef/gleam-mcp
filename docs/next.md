# Current handoff

Audited on 2026-09-30 against protocol source baseline `c3422db` and lock `7558e23`. The
initial published extraction baseline is `ed5758bb11939ceab4adaceda26e891172550ec1`;
its complete Linux and macOS CI passed in run `36687863801`. The previous
handoff's claim that initial publication was pending is superseded by that
result. This edition records the subsequent typed protocol and bounded HTTP extension separately from that baseline.

## Where the tree is

The modern profile follows released MCP `2026-07-28`, pinned to official
specification commit `046fa30efd374370afb87ef830bd788eac5f217e` after initial
publication. Typed definitions couple schemas, encoders and decoders for
both client and server. Stdio and HTTP use the required request/response,
explicit multi-round-trip and subscription envelopes. The initialized
`2025-06-18` and `2024-11-05` stdio profiles remain available to Loom.
Resources and prompts are tracked in [issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1);
optional providers, tasks and OAuth flows remain unadvertised.

The schema gate includes all 1,301 required Draft 2020-12 vectors at the
recorded upstream revision, with zero skips. The optional corpus measures
546/1,036 passing vectors; the remaining 490 refusals or mismatches are
reported explicitly. See the corpus record for regex admission, unsupported
vocabularies, licenses and logical work bounds. Do not infer arbitrary
ECMAScript equivalence or native regex wall-clock bounds from that census.

The complete `make check` gate passed with 232 unit tests (including all
required schema vectors), 139 linter tests, five negative tooling checks,
nine native stdio checks and 30 native HTTP/TLS checks. Its own exit status
was zero. Independent Astra review found malformed argument classification,
subscription completion admission and a false-pass regression fixture; all
three were fixed and rechecked in the same review context. A later Linux
consumer failure exposed unread rejected HTTP bodies; the final native gate
now verifies status delivery, actual socket reuse, and framing refusal before
callbacks. The existing Mist fork is pinned to `1a81d90`, whose full CI
passed [run 36712967634](https://github.com/Roasbeef/mist/actions/runs/36712967634).
Its parser regression fails against the original code and passes with the fix.

Jevelin's four tools and separate native typed client passed at the prior
published SDK pin. Consumer pins and their exact-head hosted results remain
separate acceptance criteria, never implied by the SDK gate. Loom's full
local gate and required Linux hosted gate passed at extraction head
`cd932374`; its hosted macOS e2e failure also reproduces on exact base main
`01f14ef8` at `worktree_diff_test.gleam:95`. Read consumer evidence at the
commit and CI run that actually produced it.

## Rulings already made

A typed codec checks custom encoders as well as decoders. Request-bound
result decoding closes over the original arguments. An opaque continuation
retains those arguments, the exact endpoint, revision and result decoder;
resumption is a new explicit attempt. Untrusted server continuation state
still needs application integrity validation when it represents authority.
Transport failure never triggers automatic effect replay.

The stdio reader, writer and admitted handlers have explicit custody. A
callback stays parked until its scope is adopted. EOF stops admission and
drains admitted work under its original deadline. Worker retirement proves
local termination, not rollback of a remote effect. A live subscription
must coexist with ordinary requests and map its allocated wire identifier
back to the caller's handle consistently.

HTTP binds loopback and requires an explicit admission policy. Present
Origins and mirrored headers validate before effects. Gun verifies HTTPS
peers and hostnames, disables retries and joins the actual connection owner
before return. Mist owns parsing and supervision; the narrow close-event
adapter exists because its public SSE interface omits socket-close delivery.
Server uploads require unambiguous `Content-Length` framing within eight MiB;
unsupported chunked uploads close before body collection. Bounded refusal
drains use a shared fifteen-second budget plus at most one native read;
this is not a claim of an aggregate deadline for every admitted body read.

The initial custody regression has positive synchronized liveness witnesses,
but restoring the old custody code passed under the ordinary scheduler.
That mutation does not prove the old race was detected. Independent native
HTTP tests keep the client VM alive after return to avoid masking a leaked
connection with VM exit.

## What to do next

1. Keep consumer dependency updates exact and reproducible. Exit: clean
   Jevelin/Loom builds and hosted Linux/macOS checks pass the named published
   commits, including real Loom MCP and jailed code-mode exchanges.
2. Implement resources and prompts under issue #1 as a separate body of work.
   Exit: typed APIs, capability negotiation and independent exchanges prove
   the advertised behavior. See [optional features](extensions.md).

Run `make check`; [execution](execution.md) explains verification hazards,
and [protocol contracts](protocol.md) record the current wire and ownership
boundaries. The inherited style guide and custom linter remain the gates.
