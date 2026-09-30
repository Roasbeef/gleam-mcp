//// Wire ids must remain unique across concurrent callers sharing one stdio
//// endpoint. Maintained Gleam libraries expose references but no unique integer
//// conversion suitable for JSON-RPC; this wrapper uses the native allocator
//// directly, with no custom Erlang implementation or process machinery.

/// Mints a node-unique JSON-RPC integer, which may have either sign.
///
/// ## Examples
///
/// ```gleam
/// // ffi_request.next_id() is distinct for each concurrent request.
/// ```
@external(erlang, "erlang", "unique_integer")
pub fn next_id() -> Int
