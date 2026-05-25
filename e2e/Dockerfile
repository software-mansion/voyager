FROM erlang:29-alpine

ENV ERL_DIST_PORT=9001

CMD ["erl", "-name", "test@127.0.0.1", "-setcookie", "e2e_cookie", "-noshell"]
