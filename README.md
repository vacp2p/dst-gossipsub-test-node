# dst-gossipsub-test-node

* DST gossipsub test node
* incl shadow simulation setup

## Shadow example

```sh
nimble install -dy
cd shadow
# the default shadow.yml will start 5k nodes, you might want to change that by removing
# lines and setting PEERS to the number of instances
./run.sh <runs> <nodes>
# the first parameter <runs> tells the number of simulation runs, and second parameter <nodes> tells the 
# number of nodes in simulation, for example ./run.sh 2 3000
# the output for each run creates latencies(X) and shadowlogX files. where X is the simulation number.

# the run script (run.sh) uses awk to summarize latencies(X) and shadowlogX files

# you can use the plotter tool to extract useful metrics & generate a graph
cd ../tools
nim -d:release c plotter
./plotter ../shadow/latencies "Clever graph name"
# will output averages, and generate a "test.svg" graph
```

The dependencies will be installed in the `nimbledeps` folder, which enables easy tweaking
