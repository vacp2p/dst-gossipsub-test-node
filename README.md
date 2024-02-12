# dst-gossipsub-test-node

* DST gossipsub test node
* incl shadow simulation setup

## Shadow example

```sh
nimble install -dy

cd shadow
#the run.sh script is automated to meet different experiment needs, use ./run.sh <num_runs num_peers msg_size num_fragments>
#The below example runs the simulation twice for a 500 node network. each publisher publishes a 2000 bytes messages, and messages are not fragmented  

./run.sh 2 500 2000 1
# The number of nodes is maintained in the shadow.yaml file, and automatically updated by run.sh.
# The output files latencies(x), stats(x) and shadowlog(x) carries the outputs for each simulation run.
# The summary_dontwant.awk, summary_latency.awk, summary_latency_large.awk, and summary_shadowlog.awk parse the output files.
# The run.sh script automatically calls these files to display the output
# a temperary data.shadow folder is created for each simulation and removed by the run.sh after the simulation is over

# you can use the plotter tool to extract useful metrics & generate a graph
cd ../tools
nim -d:release c plotter
./plotter ../shadow/latencies "Clever graph name"
# will output averages, and generate a "test.svg" graph
```

The dependencies will be installed in the `nimbledeps` folder, which enables easy tweaking
