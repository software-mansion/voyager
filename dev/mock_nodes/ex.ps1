# powershell -ExecutionPolicy Bypass -File dev\mock_nodes\ex.ps1
# Or once: Set-ExecutionPolicy -Scope CurrentUser Bypass

iex.bat --name ex@127.0.0.1 --cookie mycookie
