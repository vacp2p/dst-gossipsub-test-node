package main

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"math/rand"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/libp2p/go-libp2p"

	pubsub "github.com/libp2p/go-libp2p-pubsub"
	lcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	"github.com/multiformats/go-multiaddr"
	ma "github.com/multiformats/go-multiaddr"
)

func getHostname() (string, int) {
	hostname, err := os.Hostname()
	if err != nil {
		fmt.Println(err)
		panic(err)
	}

	myID_str := hostname[4:]
	myID, err := strconv.Atoi(myID_str)
	if err != nil {
		panic(err)
	}

	return hostname, myID
}

func getEnvVariables() (int, int, int, int, int) {

	PEERS, err := strconv.Atoi(os.Getenv("PEERS"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	PUBLISHERS, err := strconv.Atoi(os.Getenv("PUBLISHERS"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	MSGSIZE, err := strconv.Atoi(os.Getenv("MSG_SIZE"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	CHUNKS, err := strconv.Atoi(os.Getenv("FRAGMENTS"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	CONNECTTO, err := strconv.Atoi(os.Getenv("CONNECTTO"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	return PEERS, PUBLISHERS, MSGSIZE, CHUNKS, CONNECTTO
}

func generateKey(podName string) lcrypto.PrivKey {
	hash := sha256.Sum256([]byte(podName))
	p, err := crypto.ToECDSA(hash[:])
	if err != nil {
		panic(err)
	}
	privK, _ := btcec.PrivKeyFromBytes(p.D.Bytes())
	key := (*lcrypto.Secp256k1PrivateKey)(privK)
	libp2pPrivkey := lcrypto.PrivKey(key)

	return libp2pPrivkey
}

func makeHost(peerName string) (host.Host, error) {
	sourceMultiAddr, _ := multiaddr.NewMultiaddr("/ip4/0.0.0.0/tcp/5000")

	pk := generateKey(peerName)

	return libp2p.New(
		libp2p.ListenAddrs(sourceMultiAddr),
		libp2p.Security(noise.ID, noise.New),
		libp2p.Identity(pk),
	)
}

func readLoop(sub *pubsub.Subscription, ctx context.Context) {
	for {
		msg, err := sub.Next(ctx)
		if err != nil {
			continue
		}

		receivedTimestamp := binary.LittleEndian.Uint64(msg.Data[:8])
		receivedTime := time.Unix(0, int64(receivedTimestamp))
		currentTimestamp := time.Now().UnixNano()
		currentTime := time.Unix(0, currentTimestamp)
		timeDifference := currentTime.Sub(receivedTime).Milliseconds()
		fmt.Printf("%d milliseconds: %d\n", receivedTimestamp, timeDifference)
	}
}

func createGSParams() pubsub.GossipSubParams {
	gsParams := pubsub.DefaultGossipSubParams()

	gsParams.D = 8
	gsParams.Dlo = 6
	gsParams.Dhi = 12
	gsParams.Dlazy = 6
	gsParams.Dout = 3
	gsParams.HeartbeatInterval = time.Second
	gsParams.PruneBackoff = time.Minute
	gsParams.GossipFactor = 0.05
	gsParams.IDontWantMessageThreshold = 1000

	return gsParams
}

func main() {
	numPeers, publisherCount, msgSize /*chunks*/, _, connectTo := getEnvVariables()
	hostName, myID := getHostname()
	warmupMessages := 0
	pubStart := 1
	pubEnd := pubStart + warmupMessages + publisherCount
	//publishWait := 3000 //milliseconds - Inter-packet publish delay
	isPublisher := myID >= pubStart && myID < pubEnd

	ctx := context.Background()
	gsParams := createGSParams()
	h, err := makeHost(hostName)
	if err != nil {
		panic(err)
	}
	fmt.Println("", myID, isPublisher, h.ID())

	//We need peerIDs for AddrInfo
	myIdInfo := fmt.Sprintf("%s", h.ID())
	fileErr := os.WriteFile("../"+hostName+".json", []byte(myIdInfo), 0644)
	if fileErr != nil {
		panic(fileErr)
	}

	ps, err := pubsub.NewGossipSub(ctx, h, pubsub.WithGossipSubParams(gsParams), pubsub.WithFloodPublish(false))
	if err != nil {
		println("Error starting pubsub protocol", err)
		panic(err)
	}

	topic, _ := ps.Join("test")
	topicScoreParams := pubsub.TopicScoreParams{
		TopicWeight:                  1,
		FirstMessageDeliveriesWeight: 1,
		FirstMessageDeliveriesCap:    30,
		MeshMessageDeliveriesDecay:   0.9,
	}
	_ = topic.SetScoreParams(&topicScoreParams)
	sub, _ := topic.Subscribe()

	//Wait for peers to accumulate their peerIDs
	time.Sleep(time.Second * 3)
	numbers := make([]int, numPeers)
	for i := 0; i < numPeers; i++ {
		numbers[i] = i + 1
	}
	source := rand.NewSource(int64(myID))
	r := rand.New(source)
	r.Shuffle(numPeers, func(i, j int) {
		numbers[i], numbers[j] = numbers[j], numbers[i]
	})

	for connections, i := 0, 0; i < numPeers; i++ {
		if connections >= connectTo {
			break
		}
		if numbers[i] == myID {
			continue
		}

		tAddress := fmt.Sprintf("peer%d", numbers[i])
		ips, err := net.LookupIP(tAddress)
		if err != nil {
			fmt.Printf("Error resolving address for %s \n", tAddress)
			time.Sleep(time.Second * 3)
			continue
		}

		ip := ips[0]
		ipString := ip.String()
		mAddrs := "/ip4/" + ipString + "/tcp/5000"
		multiAddrs, _ := ma.NewMultiaddr(mAddrs)
		multiaddrsArray := []ma.Multiaddr{multiAddrs}

		content, _ := os.ReadFile("../" + tAddress + ".json")
		stringValue := string(content)
		nodeID, _ := peer.Decode(stringValue)

		fmt.Printf("%s: %s: %s", tAddress, mAddrs, stringValue)
		info := peer.AddrInfo{
			ID:    nodeID,
			Addrs: multiaddrsArray,
		}
		cerr := h.Connect(ctx, info)
		if err != nil {
			fmt.Printf("Failed to dial %s: %s, reason: %s\n", mAddrs, stringValue, cerr)
			time.Sleep(time.Second * 2)
		} else {
			fmt.Println("Conected!", mAddrs, stringValue)
			connections += 1
		}
	}

	time.Sleep(time.Second * 20)
	peers := ps.ListPeers("test")
	fmt.Printf("Mesh size: %d\n", len(peers))
	//fmt.Printf("Publishing turn is: %d\n", id)

	go readLoop(sub, ctx)

	for i := pubStart; i < pubEnd; i++ {
		time.Sleep(time.Second * 3)
		if i == myID {
			now := time.Now().UnixNano()
			nowBytes := make([]byte, 8)
			binary.LittleEndian.PutUint64(nowBytes, uint64(now))
			var nowBytesExtended = append(nowBytes, make([]byte, msgSize)...)
			err := topic.Publish(ctx, nowBytesExtended)
			if err != nil {
				fmt.Printf("Error publishing: %s\n", err)
			} else {
				fmt.Printf("Done Publishing %d\n", now)
			}

		}
	}

	time.Sleep(time.Second * 30)

	/*
		topicScoreParams := pubsub.TopicScoreParams{
			TopicWeight:                  1,
			FirstMessageDeliveriesWeight: 1,
			FirstMessageDeliveriesCap:    30,
			MeshMessageDeliveriesDecay:   0.9,
		}

		_ = topic.SetScoreParams(&topicScoreParams)
	*/
}
