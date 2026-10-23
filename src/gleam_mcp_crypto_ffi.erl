%% Native cryptographic and clock primitives unavailable in gleam_stdlib.
%% Gleam callers own PKCE challenge formatting, state validation, and HMAC
%% fault tagging; this module only bridges OTP's built-in crypto and erlang
%% clock functions without adding external dependencies.
%%
%% Flow: sha256 and hmac_sha256 call crypto:hash/2 and crypto:mac/4;
%% secure_compare uses crypto:hash_equals/2 when byte sizes agree;
%% strong_random_bytes calls crypto:strong_rand_bytes/1; monotonic_time_ms
%% and system_time_ms read OTP's millisecond clocks; fault_key generates a
%% cryptographically random 32-byte VM-lifetime secret in persistent_term.
-module(gleam_mcp_crypto_ffi).
-on_load(init_fault_key/0).

-export([
    sha256/1,
    hmac_sha256/2,
    secure_compare/2,
    strong_random_bytes/1,
    monotonic_time_ms/0,
    system_time_ms/0,
    fault_key/0
]).

sha256(Bytes) when is_binary(Bytes) ->
    crypto:hash(sha256, Bytes).

hmac_sha256(Data, Key) when is_binary(Data), is_binary(Key) ->
    crypto:mac(hmac, sha256, Key, Data).

secure_compare(<<>>, <<>>) ->
    true;
secure_compare(Left, Right) when is_binary(Left), is_binary(Right) ->
    case byte_size(Left) =:= byte_size(Right) of
        true -> crypto:hash_equals(Left, Right);
        false -> false
    end.

strong_random_bytes(Count) when is_integer(Count), Count > 0 ->
    crypto:strong_rand_bytes(Count);
strong_random_bytes(_) ->
    <<>>.

monotonic_time_ms() ->
    erlang:monotonic_time(millisecond).

system_time_ms() ->
    erlang:system_time(millisecond).

init_fault_key() ->
    _ = fault_key(),
    ok.

fault_key() ->
    case persistent_term:get({?MODULE, fault_key}, undefined) of
        Key when is_binary(Key) ->
            Key;
        undefined ->
            global:trans({{?MODULE, fault_key}, self()}, fun() ->
                case persistent_term:get({?MODULE, fault_key}, undefined) of
                    Existing when is_binary(Existing) -> Existing;
                    undefined ->
                        Generated = crypto:strong_rand_bytes(32),
                        persistent_term:put({?MODULE, fault_key}, Generated),
                        Generated
                end
            end)
    end.
