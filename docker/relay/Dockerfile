# llm-in-a-box-relay — the single door through the network wall.
# Runs UNPRIVILEGED (uid 65532), no capabilities, no shell beyond python.
# Policy files are mounted read-only; the only writable mount is the deny
# log directory. Never binds outside its container network (see lbx
# wiring: sessions reach it via an --internal network; vm sessions via a
# 127.0.0.1 guestfwd target).
# Base pinned by version and digest so a release rebuilds the same way;
# Dependabot (.github/dependabot.yml) proposes version and digest updates.
FROM python:3.15.2-alpine3.24@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd
COPY relay.py /relay.py
RUN adduser -D -H -u 65532 relay
USER relay
ENTRYPOINT ["python3", "-u", "/relay.py"]
