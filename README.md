# dst-gossipsub-test-node

* DST gossipsub test node for nim-libp2p, go-libp2p, rust-libp2p
* incl shadow simulation setup
* incl awk scripts for detailed analysis

## Shadow example (nim-libp2p)

./nimrun.sh <runs> <nodes> <Message_size> <num_fragment> <num_publishers> <min_bandwidth> <max_bandwidth> 
            <min_latency> <max_latency> <anchor_stages> <packet_loss> <publisher_id> <inter_message_delay>

The following sample command runs simulation 1 time, for a 1000 node network. Each published message size \
is 15KB single-message (no-fragmentation). A total of 10 messages are transmitted in the network. \
Peer bandwidth varies between 50-150 Mbps, Latency between 40-130ms, and bandwidth/latency is roughly \
distributed in five different groups. No packet loss is introduced on edges. Peer 4 publishes all messages \
with 4000 ms inter-packet delay. see the generated network_topology.gml and shadow.yaml for peers/edges details

```sh
cd shadow
./nimrun.sh 1 1000 15000 1 10 50 150 40 130 5 0.0 4 4000
```


## Shadow example (go-libp2p)

./gorun.sh <runs> <nodes> <Message_size> <num_fragment> <num_publishers> <min_bandwidth> <max_bandwidth> 
            <min_latency> <max_latency> <anchor_stages> <packet_loss> <publisher_id> <inter_message_delay> <D_Announce>

The following sample command runs simulation 1 time, for a 1000 node network. Each published message size \
is 15KB single-message (no-fragmentation). A total of 10 messages are transmitted in the network. \
Peer bandwidth varies between 50-150 Mbps, Latency between 40-130ms, and bandwidth/latency is roughly \
distributed in five different groups. No packet loss is introduced on edges. Peer 4 publishes all messages \
with 4000 ms inter-packet delay. see the generated network_topology.gml and shadow.yaml for peers/edges details.
D_announce flag is only intended for experimental go-GossipSubv2.0 (can be left 0 otherwise)

```sh
cd shadow
./gorun.sh 1 1000 15000 1 10 50 150 40 130 5 0.0 4 4000 7
```


## Shadow example (rust-libp2p)

./rustrun.sh <runs> <nodes> <Message_size> <num_fragment> <num_publishers> <min_bandwidth> <max_bandwidth> 
            <min_latency> <max_latency> <anchor_stages> <packet_loss> <publisher_id> <inter_message_delay>

The following sample command runs simulation 1 time, for a 1000 node network. Each published message size \
is 15KB single-message (no-fragmentation). A total of 10 messages are transmitted in the network. \
Peer bandwidth varies between 50-150 Mbps, Latency between 40-130ms, and bandwidth/latency is roughly \
distributed in five different groups. No packet loss is introduced on edges. Peer 4 publishes all messages \
with 4000 ms inter-packet delay. see the generated network_topology.gml and shadow.yaml for peers/edges details.

```sh
cd shadow
./rustrun.sh 1 1000 15000 1 10 50 150 40 130 5 0.0 4 4000 7
```
