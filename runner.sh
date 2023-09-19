#!/bin/bash

custom_network_name="my_custom_network"
num_peers=10

if ! docker network inspect "$custom_network_name" >/dev/null 2>&1; then
  docker network create "$custom_network_name"
  docker network create --attachable --driver bridge "$custom_network_name"
fi

for ((i = 1; i <= num_peers; i++)); do
    # Construct the hostname (e.g., peer1, peer2, ...)
    hostname="peer$i"

    # Run the Docker container with the current hostname
    docker run -e PEERS=10 -e CONNECTTO=5 --hostname="$hostname" --network="$custom_network_name" libp2pnode &
done