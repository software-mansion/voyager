# powershell -ExecutionPolicy Bypass -File dev\mock_nodes\erl.ps1
# Or once: Set-ExecutionPolicy -Scope CurrentUser Bypass

erl -name erl@127.0.0.1 -setcookie mycookie
