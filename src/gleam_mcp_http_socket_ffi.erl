%% Exact socket identity prevents another connection from cancelling this stream.
-module(gleam_mcp_http_socket_ffi).
-export([classify/2]).
classify(Socket, {tcp_closed, Socket}) -> closed;
classify(Socket, {ssl_closed, Socket}) -> closed;
classify(Socket, {tcp_error, Socket, _}) -> closed;
classify(Socket, {ssl_error, Socket, _}) -> closed;
classify(Socket, {tcp, Socket, _}) -> unexpected_data;
classify(Socket, {ssl, Socket, _}) -> unexpected_data;
classify(_, _) -> unrelated.
