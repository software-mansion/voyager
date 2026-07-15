{application, mock_app, [
    {description, "Mock supervision tree for Voyager e2e tests"},
    {vsn, "0.1.0"},
    {modules, [
        mock_app,
        mock_root_sup,
        mock_deep_sup,
        mock_dyn_sup,
        mock_worker,
        mock_app_ctl
    ]},
    {registered, [mock_root_sup]},
    {applications, [kernel, stdlib]},
    {mod, {mock_app, []}}
]}.
