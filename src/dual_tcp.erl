-module(dual_tcp).
-moduledoc false.

%% inet_tcp with a permissive parse_address/1: gen_setup's literal-host check
%% (splitnode/3) validates a dotless node host against the connecting driver,
%% and a node reached over a v4 SSH tunnel can still be named with an IPv6
%% literal (app@::1, a Fly.io 6PN address). The parsed value only gates the
%% check -- sockets stay plain inet_tcp IPv4.

-export([family/0, parse_address/1, connect/3, send/2, send/3, recv/3]).

family() -> inet.

parse_address(Host) ->
    case inet_parse:ipv4strict_address(Host) of
        {ok, _} = Ok -> Ok;
        _ -> inet_parse:ipv6strict_address(Host)
    end.

connect(Ip, Port, Opts) -> inet_tcp:connect(Ip, Port, Opts).
send(Socket, Packet) -> inet_tcp:send(Socket, Packet).
send(Socket, Packet, Opts) -> inet_tcp:send(Socket, Packet, Opts).
recv(Socket, Length, Timeout) -> inet_tcp:recv(Socket, Length, Timeout).
