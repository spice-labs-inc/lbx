# llm-in-a-box-relay — the single door through the network wall.
# Runs UNPRIVILEGED (uid 65532), no capabilities, no shell beyond python.
# Policy files are mounted read-only; the only writable mount is the deny
# log directory. Never binds outside its container network (see lbx
# wiring: sessions reach it via an --internal network; vm sessions via a
# 127.0.0.1 guestfwd target).
# Base pinned by version and digest so a release rebuilds the same way;
# Dependabot (.github/dependabot.yml) proposes version and digest updates.
FROM python:3.15.0-alpine3.24@sha256:2699b90f4d562a22e2dd076c82f964032f64814204bff36d271a54ba4cc2c7e2
COPY relay.py /relay.py
RUN adduser -D -H -u 65532 relay
USER relay
ENTRYPOINT ["python3", "-u", "/relay.py"]
