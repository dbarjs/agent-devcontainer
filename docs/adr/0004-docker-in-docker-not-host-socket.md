# Docker-in-Docker, never the host socket

Agents need to spawn containers, and the two standard routes are docker-outside-of-docker (mount the host socket) and docker-in-docker (a daemon inside the container). We use docker-in-docker only, with `moby: false` on debian:trixie. The host socket is a sandbox escape — a YOLO agent with `/var/run/docker.sock` can mount the host filesystem into a privileged container — which breaks the premise of [ADR-0003](0003-container-is-the-sandbox.md). Combining both features doesn't work anyway: they collide on the same entrypoint.

Decided in [issue #5](https://github.com/dbarjs/agent-devcontainer/issues/5) ([map v1](https://github.com/dbarjs/agent-devcontainer/issues/1)).
