# Container image that runs your code
FROM ubuntu
RUN <<EOF
apt-get update -qq
apt-get install -y \
        jq
EOF
COPY --from=flyio/flyctl:latest /flyctl /usr/local/bin/flyctl

WORKDIR /action

# Copies your code file from your action repository to the filesystem path `/` of the container
COPY entrypoint.sh ./entrypoint.sh
COPY lib ./lib

# Code file to execute when the docker container starts up (`entrypoint.sh`)
ENTRYPOINT ["/action/entrypoint.sh"]
