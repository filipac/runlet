# Disposable SSH host for Runlet's SSH target tests: OpenSSH server + PHP 8.4 (Debian).
#
# - `runlet` logs in with a key only. The tests generate a throwaway key at run time and
#   install its public half with `docker exec`; nothing secret is baked into the image.
#   Its home directory belongs to root, so the account can't write there: runs must not
#   need to write anything on the server.
# - `runletpw` logs in with a password only (`runlet-fixture-password`, a test value), for the
#   pty-driven Connect test (ControlMaster login in a terminal).
# - /home/runlet/site is a Forge-style zero-downtime layout: `current` is a symlink to
#   `releases/20260101` (bind-mounted from Tests/Fixtures/plain by compose.yml).
# - A pre-auth banner checks that Runlet's `LogLevel=ERROR` keeps it out of run output.
FROM php:8.4-cli

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server procps \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && useradd --create-home --shell /bin/bash runlet \
 && useradd --create-home --shell /bin/bash runletpw \
 && echo 'runletpw:runlet-fixture-password' | chpasswd \
 && chown root:root /home/runlet && chmod 755 /home/runlet \
 && install -d -m 700 -o runlet -g runlet /home/runlet/.ssh \
 && install -d -m 755 /home/runlet/site/releases/20260101 \
 && ln -s releases/20260101 /home/runlet/site/current \
 && echo 'Runlet fixture banner: authorized use only.' > /etc/ssh/runlet-banner.txt

COPY sshd_config /etc/ssh/sshd_config.d/runlet-fixture.conf

# Host keys are created when the container starts (and kept across restarts).
CMD ["/bin/sh", "-c", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
