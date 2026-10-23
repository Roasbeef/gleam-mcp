//// OTP cryptographic and clock wrappers for PKCE S256, constant-time state
//// comparison, and in-VM HTTP fault authentication.
////
//// Neither `gleam_stdlib`, `gleam_erlang`, `gleam_otp` nor `weft` exposes
//// SHA-256, HMAC-SHA256, constant-time binary equality, or millisecond wall
//// clocks. Keeping these one-line OTP calls behind an internal FFI module
//// avoids pulling external crypto or time dependencies into the SDK.
////
//// ## Flow
////
//// `sha256` and `strong_random_bytes` feed OAuth PKCE `S256` challenge
//// generation in `gleam_mcp/oauth`. `secure_compare` checks callback state and
//// HMAC tags in constant time. `hmac_sha256` and `fault_key` authenticate
//// local HTTP transport faults in `gleam_mcp/streamable_http`.
//// `monotonic_time_ms` and `system_time_ms` supply elapsed and epoch clocks.

/// Computes the 32-byte SHA-256 digest of `bytes`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.sha256(<<"abc":utf8>>)
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "sha256")
pub fn sha256(bytes: BitArray) -> BitArray

/// Computes the 32-byte HMAC-SHA256 authentication tag of `data` under `key`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.hmac_sha256(<<"msg":utf8>>, key)
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "hmac_sha256")
pub fn hmac_sha256(data: BitArray, key: BitArray) -> BitArray

/// Compares two byte arrays in constant time when their lengths match.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.secure_compare(<<"a":utf8>>, <<"a":utf8>>) == True
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "secure_compare")
pub fn secure_compare(left: BitArray, right: BitArray) -> Bool

/// Generates `count` cryptographically strong random bytes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.strong_random_bytes(32)
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "strong_random_bytes")
pub fn strong_random_bytes(count: Int) -> BitArray

/// Reads the BEAM's monotonic clock in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.monotonic_time_ms()
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "monotonic_time_ms")
pub fn monotonic_time_ms() -> Int

/// Reads the current Unix epoch time in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.system_time_ms()
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "system_time_ms")
pub fn system_time_ms() -> Int

/// Derives the VM-local secret used to authenticate local HTTP fault tags.
///
/// ## Examples
///
/// ```gleam
/// // ffi_crypto.fault_key()
/// ```
@external(erlang, "gleam_mcp_crypto_ffi", "fault_key")
pub fn fault_key() -> BitArray
