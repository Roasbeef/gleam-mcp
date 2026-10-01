%% Mist's SSE interface omits socket-close delivery. Gleam retains the opaque
%% socket and selects raw events; this adapter classifies those native terms.
%%
%% Flow: classify returns closed, unexpected_data or unrelated. Every admitted
%% TCP or TLS arm repeats the exact socket identity, so an event from another
%% connection cannot cancel this stream. Gleam owns the ensuing scope drain.
%% Unexpected request data closes the stream rather than reusing its socket.
-module(gleam_mcp_http_socket_ffi).
-export([classify/2]).
classify(Socket, {tcp_closed, Socket}) -> closed;
classify(Socket, {ssl_closed, Socket}) -> closed;
classify(Socket, {tcp_error, Socket, _}) -> closed;
classify(Socket, {ssl_error, Socket, _}) -> closed;
classify(Socket, {tcp, Socket, _}) -> unexpected_data;
classify(Socket, {ssl, Socket, _}) -> unexpected_data;
classify(_, _) -> unrelated.
