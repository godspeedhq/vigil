# An OpenSSH server for the git and sftp sources, with a host key made for
# the run (mounted), and one account that only the run's key can log in to.
FROM debian:stable-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends git openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd
COPY entry.sh /entry.sh
ENTRYPOINT ["/bin/bash", "/entry.sh"]
