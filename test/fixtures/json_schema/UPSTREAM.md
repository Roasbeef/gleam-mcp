# JSON Schema conformance corpus

The required and optional vectors come from the
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
at commit `5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8`. The MIT license is reproduced
in `LICENSE`. The `remotes` tree is the same revision's offline reference data;
the runner supplies resources explicitly and never starts an HTTP server.

`draft2020-12` contains every required Draft 2020-12 test file. `optional`
contains the complete optional corpus from that revision. The ordinary
`gleam test` gate asserts exactly **1301 required vectors, zero failures**.
A rejected schema counts as a failure regardless of the vector's expected
instance verdict. Nothing is silently skipped.

```sh
gleam run -m gleam_mcp/schema_conformance
gleam run -m gleam_mcp/schema_optional
```

The first command prints the required result and any failure. The second is
an informational capability probe: it prints every optional refusal or
mismatch. Its process exit code is not the conformance gate; the required
suite's zero-failure assertion lives in `schema_test.gleam`.

## Measured optional coverage

The implementation passes **546/1036** optional vectors. The other **490**
are reported, not excluded:

| Optional area | Pass / total | Treatment |
| --- | ---: | --- |
| Format examples (`optional/format/*.json`) | 408 / 874 | `format` remains an annotation; 466 assertion expectations differ. |
| ECMAScript regex | 68 / 74 | Six vectors use `\p{digit}`, which construction rejects as an unsupported property name. |
| Legacy `dependencies` compatibility | 22 / 36 | Legacy assertion behavior is not enabled by the 2020-12 dialect. |
| Format-Assertion vocabulary | 1 / 4 | Required Format-Assertion support is refused. |
| Cross-draft references | 0 / 1 | Historic dialect resource is not admitted. |
| Anchors, big numbers, dynamic refs, float overflow, IDs, absent dialect, non-BMP regex, unknown keywords and references into them | 47 / 47 | All vectors pass. |

The optional format category contains date, date-time, duration, email,
idn-email, hostname, idn-hostname, IPv4, IPv6, URI, URI-reference, IRI,
IRI-reference, URI-template, JSON Pointer, relative JSON Pointer, regex,
ECMAScript regex, time, UUID, and unknown-format files. Passing an individual
valid format example does not demonstrate format assertion support.

## Regex contract

[Core section 6.4](https://json-schema.org/draft/2020-12/json-schema-core#section-6.4)
recommends ECMA-262 syntax and Unicode semantics with **SHOULD**, and also
recommends a portable subset of tokens. Its prohibition on implicit anchoring
uses **MUST NOT**. [Validation section 6.3.3](https://json-schema.org/draft/2020-12/json-schema-validation#section-6.3.3)
says: “This string SHOULD be a valid regular expression, according to the
ECMA-262 regular expression dialect.”

The implementation uses the maintained `gleam_regexp` backend through an
explicit subset adapter. Literal Unicode, character classes, ranges,
quantifiers, groups, alternation, lookarounds, and general-category properties
are supported. The adapter preserves ASCII digit/word shorthand semantics,
Unicode whitespace, strict end-of-input, and ECMAScript dot line terminators.
Matching is unanchored unless the schema supplies anchors.

Construction refuses PCRE control verbs, inline flags, atomic groups,
possessive quantifiers, backreferences, named captures, nested/POSIX classes,
complemented shorthands inside classes, non-general-category Unicode
properties, octal escapes, and surrogate escapes. This is deliberately an
explicit supported subset, not a claim of arbitrary ECMA-262 equivalence.
Both `pattern` and `patternProperties` use the same admission and evaluation
path. Focused regressions check admission refusals and semantic translations.

[Validation sections 7.1–7.2](https://json-schema.org/draft/2020-12/json-schema-validation#section-7.2)
distinguish required Format-Annotation from optional Format-Assertion. This
implementation preserves `format` in the original schema and does not assert
it. It rejects a dialect requiring the unsupported assertion vocabulary.

## Offline metaschemas and work limits

The eight official default-dialect metaschemas are embedded in
`src/gleam_mcp/internal/schema/metaschema.gleam`, from the
[2020-12 release](https://github.com/json-schema-org/json-schema-spec/tree/601a66c8b0f25246bf0e1fb488c5b5f030a79b72)
at commit `601a66c8b0f25246bf0e1fb488c5b5f030a79b72`. That source module carries
the IETF code-component attribution and Revised BSD license. Compilation
loads only the reachable offline reference closure. Unknown external resources
and dialects produce construction errors.

Schemas and instances have a depth bound of 128 and a weighted input allowance
of 100,000. Compilation admits at most 10,000 schema locations. Evaluation has
100,000 work units shared across branches, with structural comparison charges
for `const`, `enum`, `uniqueItems`, and property-pattern scans. Failed branches
retain their charge. Exhaustion is a typed refusal, including cyclic evaluation.
These are logical work bounds; they do not impose a wall-clock deadline on the
native regular-expression engine or arbitrary-precision arithmetic.
