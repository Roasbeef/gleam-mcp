%% Erlang shims for the mcp package (house rule: one flat FFI module per
%% package; every function here is reached only through the Gleam
%% externals in gleam_mcp/internal/ffi_port.gleam).
%%
%% Each shim converts to Gleam conventions at the boundary: exceptions
%% are caught and returned as {ok, X} | {error, Reason} — nil where the
%% caller can do nothing with a reason, a short lowercase binary where it
%% can — and raw terms are normalized into the tuple shapes of the Gleam
%% types declared on the other side of the external.
-module(gleam_mcp_ffi).

-export([
    open_stdio/4,
    port_send/2,
    port_os_pid/1,
    kill_os_process/1,
    port_event/1,
    stdio_read_line/1,
    stdio_collect_line/3,
    stdio_write/1
]).

%% erlang:open_port/2 with spawn_executable — the only way to run and
%% stream to an OS process from the BEAM without a NIF. Options: binary
%% frames both ways, stream mode (gleam_mcp/stdio owns line boundaries),
%% exit_status so server death is a message, and hide to suppress a
%% console window on other platforms. Env pairs and the working
%% directory arrive as Gleam strings (binaries) and are converted to the
%% charlists open_port's env option requires. Deliberately absent:
%% stderr_to_stdout, which would interleave the server's diagnostics
%% into the JSON-RPC line stream and corrupt framing.
open_stdio(Executable, Args, Env, Cd) ->
    try
        Base = [
            {args, Args},
            {env, env_pairs(Env)},
            binary,
            stream,
            exit_status,
            hide
        ],
        Options =
            case Cd of
                none -> Base;
                {some, Dir} -> [{cd, unicode:characters_to_list(Dir)} | Base]
            end,
        Port = erlang:open_port(
            {spawn_executable, unicode:characters_to_list(Executable)},
            Options
        ),
        {ok, Port}
    catch
        Class:Reason -> {error, spawn_reason(Class, Reason)}
    end.

%% Why the spawn failed, as a short lowercase binary for the Gleam side to
%% carry: an atom reason is its own name (`error:enoent` -> <<"enoent">>),
%% anything else is the class and a bounded ~p of the term. A blanket
%% {error, nil} here used to reach the port tests as an indistinguishable
%% "could not spawn", so an FFI regression read as a host without the
%% binary and skipped the suite silently.
spawn_reason(_Class, Reason) when is_atom(Reason) ->
    bounded(string:lowercase(atom_to_binary(Reason, utf8)));
spawn_reason(Class, Reason) ->
    %% Depth-limited (~0P with a depth of 8) so a deep term is cut by the
    %% formatter rather than by the byte cap below.
    Formatted = io_lib:format("~s: ~0P", [Class, Reason, 8]),
    case unicode:characters_to_binary(Formatted) of
        Text when is_binary(Text) -> bounded(string:lowercase(Text));
        _ -> <<"unknown spawn failure">>
    end.

%% Bounded so a spawn failure carrying a large term cannot become a large
%% string threaded through the client's error and into a log line. Cut with
%% string:slice/3, which counts characters, so the result stays valid UTF-8
%% and is a legal Gleam String.
bounded(Text) ->
    case string:length(Text) > 200 of
        true -> <<(string:slice(Text, 0, 200))/binary, "...">>;
        false -> Text
    end.

env_pairs(Env) ->
    [
        {unicode:characters_to_list(Name), unicode:characters_to_list(Value)}
     || {Name, Value} <- Env
    ].

%% erlang:port_command/2 — write one framed line to the server's stdin.
%% Raises badarg once the port is closed; that is normalized to an error
%% so the client actor settles the call in-band instead of crashing.
port_send(Port, Line) ->
    try
        true = erlang:port_command(Port, Line),
        {ok, nil}
    catch
        _:_ -> {error, nil}
    end.

%% erlang:port_info/2 with os_pid, queried immediately before termination.
%% The caller retains the port to observe its native exit-status event.
port_os_pid(Port) ->
    try erlang:port_info(Port, os_pid) of
        {os_pid, Pid} when is_integer(Pid) -> {ok, Pid};
        _ -> {error, nil}
    catch
        _:_ -> {error, nil}
    end.

%% os:cmd/1 running kill(1) — the BEAM has no direct kill(2) binding
%% without a NIF. Lookup and signal are not atomic; this does not join
%% descendants or undo effects the trusted server already performed.
kill_os_process(Pid) when is_integer(Pid), Pid > 1 ->
    _ = os:cmd("kill -KILL " ++ integer_to_list(Pid)),
    nil;
kill_os_process(_) ->
    nil.

%% Normalizes a raw port message (received via a record selector on the
%% port) into the gleam_mcp/internal/ffi_port.PortEvent shape. Pure term
%% inspection; it lives here because the message arrives as a Dynamic
%% whose shape only Erlang pattern matching can take apart safely.
port_event(Msg) ->
    case Msg of
        {Port, {data, Bin}} when is_port(Port), is_binary(Bin) ->
            {port_bytes, Bin};
        {Port, {exit_status, Status}} when is_port(Port), is_integer(Status) ->
            {port_closed, Status};
        _ ->
            port_junk
    end.

%% OTP's get_until callback stops at LF or the byte limit before converting
%% accumulated codepoints to a complete binary. Fixed-size get_chars would
%% wait for a full chunk and deadlock short interactive protocol requests.
stdio_read_line(Limit) when is_integer(Limit), Limit > 0 ->
    try
        ok = io:setopts(standard_io, [{encoding, latin1}]),
        io:request(standard_io,
            {get_until, latin1, "", ?MODULE, stdio_collect_line, [Limit]})
    of
        eof -> {ok, none};
        {line, Line} -> {ok, {some, Line}};
        {error, line_too_long} -> {error, line_too_long};
        _ -> {error, read_failed}
    catch
        _:_ -> {error, read_failed}
    end;
stdio_read_line(_) ->
    {error, read_failed}.

%% The IO server owns unread bytes returned as Rest, so lookahead never
%% consumes a later request just because the current worker finishes first.
stdio_collect_line([], Data, Limit) ->
    stdio_collect_line({[], 0}, Data, Limit);
stdio_collect_line({Rev, _Size}, eof, _Limit) ->
    case Rev of
        [] -> {done, eof, []};
        _ -> {done, stdio_line(Rev), []}
    end;
stdio_collect_line({Rev, _Size}, [10 | Rest], _Limit) ->
    {done, stdio_line(Rev), Rest};
stdio_collect_line({Rev, Size}, [Code | Rest], Limit) ->
    Width = 1,
    case Size + Width > Limit of
        true -> {done, {error, line_too_long}, Rest};
        false -> stdio_collect_line({[Code | Rev], Size + Width}, Rest, Limit)
    end;
stdio_collect_line(State, [], _Limit) ->
    {more, State}.

%% Treat the device as bytes, then validate exactly the protocol's UTF-8.
%% OTP's Unicode terminal decoder may fall back to Latin-1 on invalid input;
%% requesting Latin-1 at the device prevents that fallback changing wire bytes.
stdio_line(Rev) ->
    Bytes = list_to_binary(lists:reverse(Rev)),
    case unicode:characters_to_binary(Bytes, utf8, utf8) of
        Line when is_binary(Line) -> {line, Line};
        _ -> {error, read_failed}
    end.

%% Exceptions and device errors remain observable Results at the API.
stdio_write(Line) ->
    try io:request(standard_io, {put_chars, latin1, Line}) of
        ok -> {ok, nil};
        _ -> {error, nil}
    catch
        _:_ -> {error, nil}
    end.
