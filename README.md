# dst-gossipsub-test-node

* DST gossipsub test node
* incl shadow simulation setup

## Shadow example

```sh
nimble install -dy
cd shadow
./run.sh x n
# The run.sh file runs the simulation "x" number of times and every simulation run uses "n" number of nodes
# The number of nodes is maintained in the shadow.yaml file, and automatically updated by run.sh.
# The output files latencies(x), stats(x) and shadowlog(x) carries the outputs for each simulation run.
# The summary_dontwant.awk, summary_latency.awk, and summary_shadowlog.awk parse the output files.
# The run.sh script automatically calls these files to display the output
# a temperary data.shadow folder is created for each simulation and removed by the run.sh after the simulation is over

# you can use the plotter tool to extract useful metrics & generate a graph
cd ../tools
nim -d:release c plotter
./plotter ../shadow/latencies "Clever graph name"
# will output averages, and generate a "test.svg" graph
```

The dependencies will be installed in the `nimbledeps` folder, which enables easy tweaking
