%% Native cryptographic and clock primitives unavailable in gleam_stdlib.
%% Gleam callers own PKCE challenge formatting, state validation, and HMAC
%% fault tagging; this module only bridges OTP's built-in crypto and erlang
%% clock functions without adding external dependencies.
%%
%% Flow: sha256 and hmac_sha256 call crypto:hash/2 and crypto:mac/4;
%% secure_compare uses crypto:hash_equals/2 when byte sizes agree;
%% strong_random_bytes calls crypto:strong_rand_bytes/1; monotonic_time_ms
%% and system_time_ms read OTP's millisecond clocks; fault_key derives a
%% VM-scoped HMAC key from the node and OS process identifier.
-module(gleam_mcp_crypto_ffi).

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

fault_key() ->
    NodeBin = atom_to_binary(node(), utf8),
    PidBin = unicode:characters_to_binary(os:getpid()),
    crypto:hash(sha256, <<"gleam-mcp-http-fault:", NodeBin/binary, ":", PidBin/binary>>).
