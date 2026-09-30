%% Gun owns HTTP parsing, connection shutdown, TLS and flow control.
-module(gleam_mcp_http_ffi).
-export([open/4, post/5, next/3, credit/2, close/1, now/0]).

open(Host, Port, Scheme, Timeout) ->
    try
        Name = binary_to_list(Host),
        Base = #{supervise => false, retry => 0, protocols => [http],
            connect_timeout => Timeout, domain_lookup_timeout => Timeout,
            http_opts => #{max_headers => 128, max_header_block_size => 65536}},
        Opts = case Scheme of
            <<"http">> -> Base#{transport => tcp};
            <<"https">> -> Base#{transport => tls,
                tls_handshake_timeout => Timeout,
                tls_opts => [{verify, verify_peer},
                    {cacerts, public_key:cacerts_get()},
                    {server_name_indication, Name},
                    {customize_hostname_check,
                        [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}
        end,
        case gun:open(Name, Port, Opts) of
            {ok, Pid} -> {ok, Pid};
            _ -> {error, <<"cannot open HTTP connection">>}
        end
    catch _:_ -> {error, <<"cannot open verified HTTP connection">>} end.

post(Pid, Path, Headers, Body, Timeout) ->
    case gun:await_up(Pid, Timeout) of
        {ok, http} -> {ok, gun:post(Pid, Path, Headers, Body, #{flow => 1})};
        _ -> {error, <<"HTTP connection failed before request">>}
    end.

next(Pid, Stream, Timeout) when Timeout > 0 ->
    case gun:await(Pid, Stream, Timeout) of
        {response, Fin, Status, Headers} ->
            {ok, {headers, completion(Fin), Status, Headers}};
        {data, Fin, Data} -> {ok, {data, completion(Fin), Data}};
        {inform, _, _} -> {ok, inform};
        {trailers, _} -> {ok, trailers};
        _ -> {error, <<"HTTP stream interrupted; execution outcome is unknown">>}
    end;
next(_, _, _) -> {error, <<"HTTP deadline elapsed; execution outcome is unknown">>}.

completion(fin) -> finished;
completion(nofin) -> more.
credit(Pid, Stream) -> gun:update_flow(Pid, Stream, 1), nil.
now() -> erlang:monotonic_time(millisecond).
close(Pid) ->
    try gen_statem:stop(Pid, normal, infinity) catch exit:_ -> ok end,
    nil.
