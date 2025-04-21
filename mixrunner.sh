#!/bin/bash

N="$1"
DATADIR="$2"

if [[ -z "$N" || -z "$DATADIR" ]]; then
  echo "usage: $0 <N> <datadir>"
  exit 1
fi

mkdir -p "$DATADIR"
if [[ "$(ls -A "$DATADIR")" ]]; then
  echo "error: $DATADIR is not empty"
  exit 1
fi

for i in $(seq 1 "$N"); do
  docker run --rm \
    -d \
    -v "$DATADIR":/data \
    -e MSGRATE=10 \
    -e MSGSIZE=10 \
    -e PUBLISHERS="$N" \
    -e CONNECTTO=5 \
    -e MIXPOOLSIZE="$N" \
    --entrypoint /node/main \
    mixrunner
done
