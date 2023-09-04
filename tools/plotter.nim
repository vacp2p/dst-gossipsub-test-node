import os
import strutils, sequtils
import ggplotnim

var
  time: seq[int]
  latency: seq[int]
  bandwidth: seq[int]

for l in lines(paramStr(1)):
  if "BW:" in l:
    bandwidth.add(parseInt(l.split({' ', ':'})[^1].split(".")[0]))
  if "DUPS:" in l: continue
  if "milliseconds" notin l: continue

  let splitted = l.split({' ', ':'})
  time.add(splitted[^4].parseInt)
  latency.add(splitted[^1].parseInt)

echo "BW: ", foldl(bandwidth, a + b, 0)
#var
#  time = @[0, 0, 0, 5, 5, 5, 9, 9]
#  latency = @[300, 500, 600, 100, 500, 600, 800, 900]

var df = toDf(time, latency)

let minTime = df["time", int].min

df = df
  .mutate(f{"time" ~ float(`time` - minTime) / 1000000000})
  .arrange("time").groupBy("time")
  .summarize(f{int: "amount" << int(size(col("latency")))},
        f{int -> int: "maxLatencies"  << max(col("latency"))},
        f{int -> int: "meanLatencies" << mean(col("latency"))},
        f{int -> int: "minLatencies"  << min(col("latency"))})

let
  maxLatency = df["maxLatencies", int].max
  maxTime = df["time", float].max
  maxAmount = df["amount", int].max
  factor = float(maxLatency) / float(maxAmount)

df = df.filter(f{`time` < maxTime - 3}).mutate(f{"scaled_amount" ~ `amount` * factor})

df.writeCsv("/tmp/df.csv")

echo "Average max latency: ", df["maxLatencies", int].mean
echo "Average mean latency: ", df["meanLatencies", int].mean
echo "Average min latency: ", df["minLatencies", int].mean
echo "Average received count: ", df["amount", int].mean
echo "Minimum received count: ", df["amount", int].min

let sa = secAxis(name = "Reception count", trans = f{1.0 / factor})
ggplot(df, aes("time", "maxLatencies")) +
  geom_line(aes("time", y = "scaled_amount", color = "Amount")) +
  ylim(0, maxLatency) +
  ggtitle(paramStr(2)) +
  legendPosition(0.8, -0.2) +
  scale_y_continuous(name = "Latency (ms)", secAxis = sa) +
  geom_line(aes("time", y = "maxLatencies", color = "Max")) +
  geom_line(aes("time", y = "meanLatencies", color = "Mean")) +
  geom_line(aes("time", y = "minLatencies", color = "Min")) +
  ggsave("test.svg", width = 640.0 * 2, height = 480 * 1.5)
