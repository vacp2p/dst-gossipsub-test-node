# Build nim
FROM debian:bookworm-slim AS build_nim

WORKDIR /

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt install -y git curl build-essential bash ca-certificates libssl-dev

ENV NIM_VERSION=version-2-0

RUN curl -O -L -s -S https://raw.githubusercontent.com/status-im/nimbus-build-system/master/scripts/build_nim.sh

RUN env MAKE="make -j$(nproc)" \
        ARCH_OVERRIDE=amd64 \
        NIM_COMMIT=$NIM_VERSION \
        QUICK_AND_DIRTY_COMPILER=1 \
        QUICK_AND_DIRTY_NIMBLE=1 \
        CC=gcc \
        bash build_nim.sh nim csources dist/nimble NimBinaries


# =============================================================================
# Build the app
FROM debian:bookworm-slim AS build_app

WORKDIR /node

# Copy nim
COPY --from=build_nim /nim /nim

ENV PATH="/root/.nimble/bin:/nim/bin:${PATH}"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt install -y git build-essential bash ca-certificates libssl-dev

# Configure git and install dependencies
RUN git config --global http.sslVerify false

# Install latest nimble version
RUN nimble install nimble@0.20.1

# Copy only files needed to install Nimble deps (optimizes layer caching)
COPY test_node.nimble .

RUN apt install -y mercurial

RUN nimble install https://github.com/vacp2p/nim-libp2p@#a923e204472dcc911ecf48bdcb6a00b3bee3386f
RUN nimble install https://github.com/vacp2p/mix@#e45cd05bfdb775a4cb2c9443077a15b9da13c037

RUN nimble install -y --depsOnly.

# Copy full source AFTER deps are cached
COPY . .

# Compile the Nim application
# RUN nimble c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:enable_mix_benchmarks  -d:release main --verbose --debug
# RUN nimble compile -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:enable_mix_benchmarks -d:release main --verbose
RUN nimble compile -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:enable_mix_benchmarks -d:release main --verbose --debuginfo

# =============================================================================
# Run the app
FROM debian:bookworm AS prod

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt -y install cron libpcre3 libssl-dev

# Set the working directory
WORKDIR /node

# Copy the compiled binary from the build stage
COPY --from=build_app /node/main /node/main

COPY ./cron_runner.sh .

RUN chmod +x cron_runner.sh
RUN chmod +x main

EXPOSE 5000 8008

ENV FILEPATH=/data
VOLUME ["/data"]

ENTRYPOINT ["./cron_runner.sh"]
