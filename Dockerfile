# BUILD NIM APP ----------------------------------------------------------------
FROM rust:1.77.1-alpine3.18  AS nim-build

ARG NIMFLAGS
ARG MAKE_TARGET
ARG NIM_COMMIT

# Get build tools and required header files
RUN apk add --no-cache bash git build-base pcre-dev linux-headers curl jq

WORKDIR /app
COPY . .

# workaround for alpine issue: https://github.com/alpinelinux/docker-alpine/issues/383
RUN apk update && apk upgrade

# Ran separately from 'make' to avoid re-doing
RUN git submodule update --init --recursive

# Slowest build step for the sake of caching layers
RUN make -j$(nproc) deps QUICK_AND_DIRTY_COMPILER=1

# Build the final node binary
RUN make -j$(nproc) $MAKE_TARGET NIMFLAGS="${NIMFLAGS}"

# PRODUCTION IMAGE -------------------------------------------------------------

FROM alpine:3.18 as prod

LABEL maintainer="asoutullo@status.im"
LABEL source="https://github.com/vacp2p/dst-gossipsub-test-node/tree/dockerized"

# LibP2P, Metrics ports
EXPOSE 5000 8008

# Referenced in the binary
RUN apk add --no-cache busybox-suid \
    && apk add --no-cache --update busybox-extras \
    && apk add --no-cache bash

# Copy to separate location to accomodate different MAKE_TARGET values
COPY --from=nim-build /app/build/ /node/main

WORKDIR /node

COPY cron_runner.sh .

RUN chmod +x cron_runner.sh

ENTRYPOINT ["./cron_runner.sh"]