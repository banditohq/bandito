# Bandito test server: a plain Ubuntu 24.04 with sshd and no systemd.
# Driven by scripts/dev/testbed.sh. For local rehearsals only: the container is published on 127.0.0.1.
#
#   DEV_PASSWORD      password of user `dev` (sudo asks for it unless SUDO_NOPASSWD=1)
#   SUDO_NOPASSWD     1 = `dev` gets passwordless sudo, anything else = sudo asks for the password
#
# Host keys are generated while the image is built, so restarts of a container keep the same key.
# The login key is not baked in: testbed.sh copies it into the running container.
FROM ubuntu:24.04

ARG DEV_PASSWORD
ARG SUDO_NOPASSWD=0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server sudo curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# A server user with uid 1000 and a home directory. Ubuntu's image ships `ubuntu` on uid 1000; drop it.
RUN test -n "$DEV_PASSWORD" \
 && (userdel -r ubuntu 2>/dev/null || true) \
 && useradd --create-home --shell /bin/bash --uid 1000 dev \
 && echo "dev:${DEV_PASSWORD}" | chpasswd \
 && install -d -m 700 -o dev -g dev /home/dev/.ssh

RUN if [ "$SUDO_NOPASSWD" = "1" ]; then \
      echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev; \
    else \
      echo 'dev ALL=(ALL:ALL) ALL' > /etc/sudoers.d/dev; \
    fi \
 && chmod 0440 /etc/sudoers.d/dev \
 && visudo -cf /etc/sudoers.d/dev

# Key login only. The drop-in is read before the defaults in sshd_config (Include comes first).
RUN mkdir -p /run/sshd /etc/ssh/sshd_config.d \
 && printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PubkeyAuthentication yes' \
      'PermitRootLogin no' \
      'AllowUsers dev' \
      > /etc/ssh/sshd_config.d/10-bandito-testbed.conf \
 && ssh-keygen -A \
 && /usr/sbin/sshd -T | grep -qx 'passwordauthentication no'

EXPOSE 22

# -e sends sshd's log to stderr, so `docker logs` shows the logins.
CMD ["/usr/sbin/sshd", "-D", "-e"]
