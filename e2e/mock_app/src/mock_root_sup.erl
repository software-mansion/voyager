%% Root of the mock supervision tree inspected by the e2e tests.
%%
%%   mock_root_sup
%%   ├── mock_static_worker                 worker leaf, never expandable
%%   ├── mock_deep_sup_1
%%   │   └── mock_deep_sup_2
%%   │       └── mock_deep_sup_3
%%   │           └── mock_leaf_worker       chain deeper than the default walk depth
%%   ├── mock_dyn_sup_a                     starts empty, children added at runtime
%%   └── mock_dyn_sup_b                     starts with one child (mock_dyn_worker_b1)
-module(mock_root_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    DeepSup3 =
        sup_spec(mock_deep_sup, mock_deep_sup_3, [worker_spec(mock_leaf_worker)]),
    DeepSup2 = sup_spec(mock_deep_sup, mock_deep_sup_2, [DeepSup3]),
    DeepSup1 = sup_spec(mock_deep_sup, mock_deep_sup_1, [DeepSup2]),
    RelSupA = sup_spec(mock_deep_sup, rel_sup_a, [worker_spec(rel_leaf_a)]),
    DynSupA = sup_spec(mock_dyn_sup, mock_dyn_sup_a, [RelSupA]),
    RelSupB = sup_spec(mock_deep_sup, rel_sup_b, [worker_spec(rel_leaf_b)]),
    DynSupB = sup_spec(mock_dyn_sup, mock_dyn_sup_b, [RelSupB, worker_spec(mock_dyn_worker_b1)]),
    {ok,
     {#{strategy => one_for_one},
      [worker_spec(mock_static_worker), DeepSup1, DynSupA, DynSupB]}}.

sup_spec(Module, Name, ChildSpecs) ->
    #{id => Name, type => supervisor, start => {Module, start_link, [Name, ChildSpecs]}}.

worker_spec(Name) ->
    #{id => Name, start => {mock_worker, start_link, [Name]}}.
