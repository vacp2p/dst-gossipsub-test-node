import sys, math, networkx as nx

args = sys.argv
if len(args) != 11:
    print("Usage: python topogen.py <network_size> <min_bandwidth> <max_bandwidth> <min_latency> <max_latency> <anchor_stages> \
          <packet_loss> <message_size> <num_frags> <num_publishers>")
    print("Please note that bandwith and latency are integer values in Mbps and ms respectively")
    print("Anchor stages represent the number of bandwidth and latency variations")
    print("packet_loss [0-1], Message size [KB], num_frags [number of fragments/message 1-10], num_publishers [number of publishers]")
    exit(-1)

print (args[1:])
try:
    networkSize     = int(args[1])
    minBandwidth    = int(args[2])
    maxBandwidth    = int(args[3])
    minLatency      = int(args[4])
    maxLatency      = int(args[5])
    steps           = int(args[6])
    packetLoss      = float(args[7])
    messageSize     = int(args[8])
    numFrags        = int(args[9])
    numPublishers   = int(args[10])

except ValueError:
    print("Usage: python topogen.py <network_size> <min_bandwidth> <max_bandwidth> <min_latency> <max_latency> <anchor_stages> \
          <packet_loss> <message_size> <num_frags> <num_publishers>")
    print("Please note that bandwith and latency are integer values in Mbps and ms respectively")
    print("Anchor stages represent the number of bandwidth and latency variations")
    print("packet_loss [0-1], Message size [KB], num_frags [number of fragments/message 1-10], num_publishers [number of publishers]")
    exit(-1)

gml_file  = "network_topology.gml"      #network topology layout in gml format, to be used by the yaml file
yaml_file = "shadow.yaml"               #shadow simulator settings
connections = 5                         #Initial connections to form full-message mesh
bandwidthJump = (maxBandwidth-minBandwidth)/(steps-1)
latencyJump = int((maxLatency-minLatency)/steps)

"""
We create network work graph, with 'steps' number of independent nodes. And all the nodes must be connected. 
Shadow uses accumulative edge latencies to route traffic through the shortest paths (accumulative link latencies)

Multiple hosts can connect with a single node. The node must define 'host_bandwidth_up' and 'host_bandwidth_down' 
bandwidths, and each connected host gets this bandwidth allocated (bandwidth is not shared between hosts)

We MUST have an edge connecting a node to itself. All the Intra-node communications (among the hosts connected to 
the same node) happen by using that edge. 

latency and packet loss are edge characteristics
"""

G=nx.complete_graph(steps)

for i in range(0, steps):
    nodeBw = str(math.ceil(i * bandwidthJump + minBandwidth)) + " Mbit"
    G.nodes[i]["hostbandwidthup"] = nodeBw
    G.nodes[i]["hostbandwidthdown"] = nodeBw
    G.add_edge(i,i)
    G.edges[i,i]["latency"] = str( max((steps-i)*latencyJump, minLatency) ) + " ms"
    G.edges[i,i]["packetloss"] = packetLoss

    for j in range(i+1, steps):
        edgeLatency = min(math.ceil((steps-j)*latencyJump + minLatency), maxLatency)
        G.edges[i,j]["latency"] = str(edgeLatency) + " ms"
        G.edges[i,j]["packetloss"] = packetLoss

nx.write_gml(G, gml_file)


#networkx package can not write underscores. so we created gml without underscores. Now we embed them underscores 
with open(gml_file, 'r') as file:
    gml_content = file.read()

modified_content = gml_content.replace("hostbandwidth", "host_bandwidth_")
modified_content = modified_content.replace("packetloss", "packet_loss")

with open(gml_file, "w") as file:
    file.write(modified_content)
    

#we created the gml. now we create the yaml file required by shadow
m1 = "\n    network_node_id: "
m2 = "\n    processes:"
m3 = "\n    - path: ./main"
m4 = "\n      start_time: 5s"

with open(yaml_file, "w") as file:
    file.write("general:\n  bootstrap_end_time: 10s\n  heartbeat_interval: 12s\n  stop_time: 15m\n")
    file.write("  progress: true\n\nexperimental:\n  use_memory_manager: false\n\n")
    file.write("network:\n  graph:\n    type: gml\n    file:\n      path: " + gml_file)
    file.write("\n\nhosts:\n")
    
    #we create 'steps' number of template peers, to be used by the remaining peers
    for i in range(0,steps):
        file.write("  peer" + str(i+1) + ": &client_host" + str(i))
        file.write(m1 + str(i) + m2 + m3 + m4)
        file.write("\n      environment: {\"PEERS\": \"" + str(networkSize) + 
                   "\", \"CONNECTTO\": \"" + str(connections) + 
                   "\", \"MSG_SIZE\": \"" + str(messageSize) + 
                   "\", \"FRAGMENTS\": \"" + str(numFrags) +
                   "\", \"PUBLISHERS\": \"" + str(numPublishers) + "\"}\n")
        
    #we populate remaining peers on populated samples    
    for i in range(steps, networkSize):
        file.write("  peer" + str(i+1) + ": *client_host" + str(i%steps) + "\n")

