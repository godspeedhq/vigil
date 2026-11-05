# A fleet host: slim Debian with what Vigil needs, and nothing of Vigil's.
# Vigil is installed when the container starts, from the run's releases.
FROM debian:stable-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git openssh-client openssl procps python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash vigil
COPY entry.sh run.sh /fleet-bin/
ENTRYPOINT ["/bin/bash", "/fleet-bin/entry.sh"]
