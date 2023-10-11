# Create the build image
FROM nimlang/nim

# Copy the wls files to the production image
WORKDIR /node
COPY . .


RUN apt-get update
RUN apt-get install -y netcat

RUN git config --global http.sslVerify false

RUN nimble install -dy

RUN nimble c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics  -d:release main


EXPOSE 5000

ENTRYPOINT ["./main"]