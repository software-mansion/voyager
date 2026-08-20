-module(dual_tcp).
-moduledoc false.

%% Thin wrapper around inet_tcp, used only as the low-level Driver argument
%% to inet_tcp_dist:gen_setup/6 (via dual_tcp_dist:setup/5) for the "connect
%% over IPv4" branch.
%%
%% family/0, connect/3, send/2 and recv/3 delegate to inet_tcp unchanged --
%% the actual socket is genuinely IPv4 (an SSH-tunnelled node is always reached
%% through a v4 loopback forward, because :ssh cannot bind a v6 forward
%% listener). The one override is parse_address/1: inet_tcp_dist's own
%% literal-host validation (splitnode/3, run inside gen_setup before any socket
%% is opened) requires a dotless node-name host to parse under whichever driver
%% we hand it, regardless of how it actually connects -- and discards the parsed
%% value once the check passes, so it is never used to route the connection.
%% A tunnelled node's literal identity can be a real IPv6 address (e.g.
%% `app@::1`, or a Fly.io 6PN address) even though the tunnel itself is v4, so
%% this accepts IPv6 literal syntax too, purely to satisfy that gate.
-export([family/0, parse_address/1, connect/3, send/2, recv/3]).

family() -> inet.

parse_address(Host) ->
    case inet_parse:ipv4strict_address(Host) of
        {ok, _} = Ok -> Ok;
        _ -> inet_parse:ipv6strict_address(Host)
    end.

connect(Ip, Port, Opts) -> inet_tcp:connect(Ip, Port, Opts).
send(Socket, Packet) -> inet_tcp:send(Socket, Packet).
recv(Socket, Length, Timeout) -> inet_tcp:recv(Socket, Length, Timeout).
