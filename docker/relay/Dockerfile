# llm-in-a-box-relay — the single door through the network wall.
# Runs UNPRIVILEGED (uid 65532), no capabilities, no shell beyond python.
# Policy files are mounted read-only; the only writable mount is the deny
# log directory. Never binds outside its container network (see lbx
# wiring: sessions reach it via an --internal network; vm sessions via a
# 127.0.0.1 guestfwd target).
# Base pinned by version and digest so a release rebuilds the same way;
# Dependabot (.github/dependabot.yml) proposes version and digest updates.
FROM python:3.14.7-alpine3.24@sha256:9e9fde4d32eedce0b661d9ab91e826b62dddf28e928c230ec55f1866cac66b01
COPY relay.py /relay.py
RUN adduser -D -H -u 65532 relay
USER relay
ENTRYPOINT ["python3", "-u", "/relay.py"]
