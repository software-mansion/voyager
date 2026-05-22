# This Dockerfile is used to create a Docker image for a remote node.
# It is used to test the remote node connection functionality.

FROM elixir:1.19-alpine

WORKDIR /app

CMD ["elixir", "--name", "app@127.0.0.1", "--cookie", "mycookie", "-e", "Process.sleep(:infinity)"]