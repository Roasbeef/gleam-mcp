//// Wire ids must remain unique across concurrent callers sharing one stdio
//// endpoint. Maintained Gleam libraries expose references but no unique integer
//// conversion suitable for JSON-RPC; this wrapper uses the native allocator
//// directly, with no custom Erlang implementation or process machinery.
////
//// ## Flow
////
//// next_id calls erlang:unique_integer for one VM-local wire id. client uses that
//// value in an explicit request; the native actor may allocate a separate peer id
//// and restore the original at its endpoint boundary. IDs correlate attempts and
//// are not authentication tokens or durable identities.

/// Mints a node-unique JSON-RPC integer, which may have either sign.
///
/// ## Examples
///
/// ```gleam
/// // ffi_request.next_id() is distinct for each concurrent request.
/// ```
@external(erlang, "erlang", "unique_integer")
pub fn next_id() -> Int
