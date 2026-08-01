# A systemd-capable Debian image that runs the whole deploy/ stack: the unit,
# journald, fail2ban, nftables — against the audited app in deploy/verify/app.
#
# Build from the repository root (the build context must be the repo, not this
# directory), then run with the flags a systemd payload needs:
#
#   docker build -f deploy/verify/Dockerfile -t otsh-verify .
#   docker run -d --name otsh-sut --privileged \
#       -v /sys/fs/cgroup:/sys/fs/cgroup:rw otsh-verify
#
# deploy/verify/verify.sh does all of that and runs the test phases; this file
# is only the machine. See deploy/verify/README-free notes in docs/deploy.md
# ("What was verified, and where") for what the phases prove.
#
# debian:13 (trixie) is chosen deliberately: it ships the exact versions the
# repo's claims are measured against — systemd 257, fail2ban 1.1.0,
# nftables 1.1.x.
FROM debian:13

ARG ODIN_RELEASE=dev-2026-07a
ENV DEBIAN_FRONTEND=noninteractive

# systemd + the three deploy layers + the otsh build/run dependencies + the
# client tools the attacker role uses (one image plays both roles).
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus \
        libssh-4 libssh-dev pkg-config clang curl ca-certificates \
        fail2ban python3-systemd nftables \
        iproute2 iputils-ping procps psmisc \
        openssh-client netcat-openbsd python3 \
    && rm -rf /var/lib/apt/lists/*

# The pinned Odin toolchain (see env.ODIN_RELEASE in .github/workflows/ci.yml).
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/odin.tar.gz \
        "https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/odin-linux-${arch}-${ODIN_RELEASE}.tar.gz" \
    && mkdir -p /opt/odin \
    && tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1 \
    && rm /tmp/odin.tar.gz \
    && /opt/odin/odin version

# Build the audited app and install it at the exact path the shipped unit's
# ExecStart names, so the unit file needs no edits at all.
COPY . /src/otsh
RUN cd /src/otsh \
    && ODIN=/opt/odin/odin ./build.sh deploy/verify/app \
    && install -D -m 0755 ./app /usr/local/lib/otsh/tracker \
    && rm -f ./app

# Install the shipped deploy artifacts verbatim, exactly as docs/deploy.md
# instructs. Debian's own defaults-debian.conf enables an sshd jail this
# machine has no sshd for; remove it rather than carry its noise.
RUN install -D -m 0644 /src/otsh/deploy/otsh.service /etc/systemd/system/otsh.service \
    && install -D -m 0644 /src/otsh/deploy/fail2ban/filter.d/otsh.conf /etc/fail2ban/filter.d/otsh.conf \
    && install -D -m 0644 /src/otsh/deploy/fail2ban/jail.d/otsh.local /etc/fail2ban/jail.d/otsh.local \
    && rm -f /etc/fail2ban/jail.d/defaults-debian.conf \
    && systemctl enable otsh.service \
    && systemctl disable fail2ban

CMD ["/sbin/init"]
