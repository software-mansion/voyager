-module(mock_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> mock_root_sup:start_link().

stop(_State) -> ok.
