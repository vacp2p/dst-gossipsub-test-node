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
		fmt.Println("Error getting hostname")
		panic(err)
	}

	myID_str := hostname[4:]
	myID, err := strconv.Atoi(myID_str)
	if err != nil {
		panic(err)
	}

	return hostname, myID
}

func getEnvVariables() (int, int, int, int, int, int, int, int) {

	//network size
	PEERS, err := strconv.Atoi(os.Getenv("PEERS"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	//number of messages to transmit. Usually every publisher sends 1 message
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

	PUBLISHERID, err := strconv.Atoi(os.Getenv("PUBLISHER_ID"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}
	//inter-message delay in milliseconds
	MSGDELAY, err := strconv.Atoi(os.Getenv("MESSAGE_DELAY"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	//Needed for GossipSub v2.0, set 0 otherwise
	DANNOUNCE, err := strconv.Atoi(os.Getenv("DANNOUNCE"))
	if err != nil {
		fmt.Println("Error converting string to integer:", err)
		panic(err)
	}

	return PEERS, PUBLISHERS, MSGSIZE, CHUNKS, CONNECTTO, PUBLISHERID, MSGDELAY, DANNOUNCE
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

func createGSParams(dAnnounce int) pubsub.GossipSubParams {
	gsParams := pubsub.DefaultGossipSubParams()

	gsParams.D = 8
	gsParams.Dlo = 6
	gsParams.Dhi = 12
	gsParams.Dlazy = 6
	//gsParams.Dout = 3
	gsParams.HeartbeatInterval = time.Duration(1000) * time.Millisecond
	gsParams.PruneBackoff = time.Minute
	gsParams.GossipFactor = 0.05
	gsParams.IDontWantMessageThreshold = 1000
	//GossipSubv2.0 specific, uncomment for GossipSubv2.0
	//gsParams.HistoryLength = 6
	//gsParams.HistoryGossip = 3
	//gsParams.Dannounce = dAnnounce
	//gsParams.Timeout = time.Duration(1000) * time.Millisecond

	return gsParams
}

func main() {
	numPeers, publisherCount, msgSize /*chunks*/, _, connectTo, publisherID, publishWait, dAnnounce := getEnvVariables()
	hostName, myID := getHostname()
	warmupMessages := 2
	pubStart := 1
	pubEnd := pubStart + warmupMessages + publisherCount
	isPublisher := myID >= pubStart && myID < pubEnd

	ctx := context.Background()
	gsParams := createGSParams(dAnnounce)
	h, err := makeHost(hostName)
	if err != nil {
		fmt.Print("Error making host")
		panic(err)
	}
	fmt.Println("", myID, isPublisher, h.ID())

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

		if connections > connectTo+2 {
			break
		}
		/*
			if len(ps.ListPeers("test")) >= 70 {
				break
			}
		*/
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

		nodeID, err := peer.IDFromPrivateKey(generateKey(tAddress))
		if err != nil {
			fmt.Printf("Error generating nodeID from hostname")
			panic(err)
		}

		fmt.Printf("%s: %s: %s", tAddress, mAddrs, nodeID)
		info := peer.AddrInfo{
			ID:    nodeID,
			Addrs: multiaddrsArray,
		}
		cerr := h.Connect(ctx, info)
		if err != nil {
			fmt.Printf("Failed to dial %s: %s, reason: %s\n", mAddrs, nodeID, cerr)
			time.Sleep(time.Second * 2)
		} else {
			fmt.Println("Conected!", mAddrs, nodeID)
			connections += 1
		}
	}

	//wait for mesh to build up
	time.Sleep(time.Second * 10)
	peers := ps.ListPeers("test")
	fmt.Println("Mesh size: ", len(peers))

	go readLoop(sub, ctx)

	var nextSender int
	for i := pubStart; i < (pubStart + warmupMessages); i++ {
		time.Sleep(time.Second * 5)

		if publisherID != 0 {
			nextSender = publisherID
		} else {
			nextSender = i
		}
		if nextSender == myID {
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

	//wait for message queues to be empty
	time.Sleep(time.Second * 10)

	for i := (pubStart + warmupMessages); i < pubEnd; i++ {
		//inter-message delay.
		//We send current time to identify messages. waitInterval=0 will make that time same (same ID for all messages)
		time.Sleep(time.Duration(publishWait) * time.Millisecond)
		if publisherID != 0 {
			nextSender = publisherID
		} else {
			nextSender = i
		}

		if nextSender == myID {
			now := time.Now().UnixNano()
			nowBytes := make([]byte, 8)
			binary.LittleEndian.PutUint64(nowBytes, (uint64(now)))
			var nowBytesExtended = append(nowBytes, make([]byte, msgSize)...)
			err := topic.Publish(ctx, nowBytesExtended)
			if err != nil {
				fmt.Printf("Error publishing: %s\n", err)
			} else {
				fmt.Printf("Done Publishing %d\n", now)
			}

		}
	}

	time.Sleep(time.Second * 40)

}
