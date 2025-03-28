use chrono::{Utc, Timelike};
use byteorder::{LittleEndian, WriteBytesExt, ReadBytesExt};
use rand::{seq::SliceRandom, thread_rng};

use std::{
    collections::hash_map::DefaultHasher,
    error::Error,
    hash::{Hash, Hasher},
    time::Duration, env, io::Cursor,
};

use futures::stream::StreamExt;
use libp2p::{
    gossipsub::{self, TopicScoreParams}, noise,
    swarm::{NetworkBehaviour, SwarmEvent, dial_opts::DialOpts},
    tcp, yamux, Multiaddr, core::ConnectedPoint,
};
use tokio::{io, select, net::lookup_host,};
use gethostname::gethostname;

#[derive(NetworkBehaviour)]
struct MyBehaviour {
    gossipsub: gossipsub::Behaviour,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    //import environment settings, mainly from shadow.yaml
    let numPeers: usize = env::var("PEERS").expect("Number of peers not set").parse().unwrap_or(100);
    let publisherCount: u32 = env::var("PUBLISHERS").expect("Publishers not set").parse().unwrap_or(4);
    let msgSize: u32 = env::var("MSG_SIZE").expect("Msg Size not set").parse().unwrap_or(10000);
    let chunks: u32 = env::var("FRAGMENTS").expect("Num_Fragments not set").parse().unwrap_or(1);
    let connectTo: u32 = env::var("CONNECTTO").expect("Peers to connect").parse().unwrap_or(1);
    let mut hostName: String = gethostname().into_string().expect("Hostname not parsed");
    
    println!("MyPeer # {hostName}, Network Size: {numPeers} Publisher count: {publisherCount}, message size: {msgSize}, number of fragments {chunks}, Connect To {connectTo}");
    
    let myID_str = hostName.split_off(4);
    let myID: u32 = myID_str.parse().expect("Peer # not correct");
    
    let warmupMessages: u32 = 0;
    let pubStart: u32 = 1;
    let pubEnd = pubStart + warmupMessages + publisherCount;
    let publishWait = 2000;                        //milliseconds - Inter-packet publish delay
    let isPublisher = myID >= pubStart && myID <= pubEnd;

    println!("MyID: {myID}, 1st Publisher: {pubStart}, Last Publisher: {pubEnd} Including {warmupMessages} warmup messages");

    let mut swarm = libp2p::SwarmBuilder::with_new_identity()
        .with_tokio()        
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        //.with_quic()
        .with_behaviour(|key| {
            // To content-address message, we can take the hash of message and use it as an ID.
            let message_id_fn = |message: &gossipsub::Message| {
                let mut s = DefaultHasher::new();
                message.data.hash(&mut s);
                gossipsub::MessageId::from(s.finish().to_string())
            };

            // Set a custom gossipsub configuration
            let gossipsub_config = gossipsub::ConfigBuilder::default()
                .validation_mode(gossipsub::ValidationMode::Strict) // This sets the kind of message validation. The default is Strict (enforce message
                // signing)
                .message_id_fn(message_id_fn) // content-address messages. No two messages of the same content will be propagated.
                .mesh_n(8)
                .mesh_n_low(6)
                .mesh_n_high(12)
                .gossip_lazy(6)
                .gossip_factor(0.05)
                .heartbeat_interval(Duration::from_millis(1000))
                .prune_backoff(Duration::from_secs(3))
                .flood_publish(false)
                .retain_scores(6)
                //.opportunistic_graft_ticks(10000)
                .mesh_outbound_min(3)
                .build()
                .map_err(|msg| io::Error::new(io::ErrorKind::Other, msg))?; // Temporary hack because `build` does not return a proper `std::error::Error`.
                


            // build a gossipsub network behaviour
            let gossipsub = gossipsub::Behaviour::new(
                gossipsub::MessageAuthenticity::Signed(key.clone()),
                gossipsub_config,
            )?;
            Ok(MyBehaviour { gossipsub })
        })?
        .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
        .build();

    //println!("localpeerID {}", swarm.local_peer_id().to_string());
    // Initialize parameter scoring
    let mut params = TopicScoreParams::default();
    params.topic_weight = 1.0;
    params.first_message_deliveries_weight = 1.0;
    params.first_message_deliveries_cap = 30.0;
    params.first_message_deliveries_decay = 0.90;

    // Create a Gossipsub topic
    let topic = gossipsub::IdentTopic::new("test");
    // subscribes to our topic
    swarm.behaviour_mut().gossipsub.subscribe(&topic)?;

    println!("{}, {}, {}", myID, isPublisher, swarm.local_peer_id().to_string());
    //quic support in shadow?
    //swarm.listen_on("/ip4/0.0.0.0/udp/5000/quic-v1".parse()?)?;
    swarm.listen_on("/ip4/0.0.0.0/tcp/5000".parse()?)?;

    //Wait for peers to start listening
    tokio::time::sleep(Duration::from_secs(5)).await;
    
    // Create mesh (Dial Peers)
    let mut listPeers: Vec<usize> = (1..=numPeers).collect();
    let mut rng = thread_rng();
    listPeers.shuffle(&mut rng);

    let mut connected: u32 = 0;
    for peer in listPeers {
        if connected > connectTo+1 {
            break;
        }
        if peer == myID as usize {continue;}

        let t_address = format!("peer{}:5000", peer);
        let mut addrs = String::from("/ip4/");
        
        loop {
            match lookup_host(&t_address).await {
                Ok(lookup_result) => {
                    for addr in lookup_result {
                        if addr.is_ipv4() {
                            println!("Resolved IPv4 address: {} for peer {peer}", addr.ip());
                            addrs.push_str(addr.ip().to_string().as_str());
                            addrs.push_str("/tcp/5000");
                        }
                    }
                }
                Err(e) => {
                    print!("Failed to resolve address for {peer}: {:?}", e);
                    continue;
                }
            }
            break;
        }

        loop {
            println!("Trying to dial with {}", addrs);
            match swarm.dial(DialOpts::unknown_peer_id()
                        .address(addrs.parse().unwrap())
                        .build()) {
                            Ok(..) => {
                                connected += 1;
                                println!("Dial sent to {}, total connected {}", addrs, connected);
                                break;
                            }
                            Err(e) => {
                                println!("Failed to dial {addrs}: {:?}", e);
                            }

            }
        }
        //let mut addr = Multiaddr::empty();
        //let rawAddr = format!("/ip4/x.x.x.{}/tcp/5000",peer); 
        //let addr: Multiaddr = rawAddr.parse().unwrap();
        //println!("dialing {}", addr.to_string());
        //swarm.dial(addr).expect("Dial Failed");
    }

    let timeout_duration = Duration::from_secs(20);
    let result = tokio::time::timeout(timeout_duration, async {
        loop {
            match swarm.select_next_some().await {
                SwarmEvent::ConnectionEstablished {
                    endpoint: ConnectedPoint::Dialer { address, .. },
                    established_in,
                    ..
                } => {
                    //println!("Connected to {:?}, took {:?}", address, established_in);
                }
                swarm_event => {
                    //println!("{:?}", swarm_event);
                }
            }
        }
    }).await;

    //Wait a little foe the mesh to be ready
    tokio::time::sleep(Duration::from_secs(5)).await;
    let mut start = Utc::now();
    let mut start_nano = start.timestamp() * 1_000_000_000 + start.nanosecond() as i64;
    let mut index = pubStart;

    let result = tokio::time::timeout(timeout_duration, async {
        loop {
            if isPublisher && index <= pubEnd {
                let now = Utc::now();
                let now_nano = now.timestamp() * 1_000_000_000 + now.nanosecond() as i64;
                let elapsed = (now_nano - start_nano) / 1_000_000; 
                if elapsed >= publishWait {
                    if index == myID {
                        //publish message
                        let mut buffer = vec![0u8; msgSize as usize];
                        let mut cursor = &mut buffer[..8];
                        cursor.write_i64::<LittleEndian>(now_nano).unwrap();

                        if let Err(e) = swarm
                                .behaviour_mut().gossipsub
                                .publish(topic.clone(), buffer) {
                                    println!("Publish error: {e:?}");
                        }
                        else {
                            let prev_nano = start.timestamp() * 1_000_000_000 + start.nanosecond() as i64;
                            println!("Peer {myID} published at {now_nano}, timediff : {}", elapsed );
                        }
                    }
                    index = index + 1;
                    start = Utc::now();
                    start_nano = start.timestamp() * 1_000_000_000 + start.nanosecond() as i64;
                }
            }
            //look for swarm events
            select! {
                event = swarm.select_next_some() => match event {
                    SwarmEvent::Behaviour(MyBehaviourEvent::Gossipsub(gossipsub::Event::Message {
                        propagation_source: peer_id,
                        message_id: id,
                        message,
                    })) => {
                        //We received a message
                        let mut cursor = Cursor::new(&message.data);
                        let txTime = cursor.read_i64::<LittleEndian>().unwrap();
                        let now = Utc::now();
                        let unix_nano = now.timestamp() * 1_000_000_000 + now.nanosecond() as i64;
                        println!("{} milliseconds: {}", txTime, (unix_nano - txTime)/1_000_000);
                    },
                    SwarmEvent::Behaviour(MyBehaviourEvent::Gossipsub(gossipsub::Event::Subscribed {
                        peer_id,
                        topic,
                    })) => println!(
                            "Successfully connected to {}", peer_id
                        ),
                    SwarmEvent::Behaviour(MyBehaviourEvent::Gossipsub(gossipsub::Event::Unsubscribed {
                        peer_id,
                        topic,
                    })) => print!(
                            "Peer {} unsubscribed", peer_id
                        ),
                    SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                            //println!("Connection established with  {peer_id}");
                    }
                    SwarmEvent::IncomingConnection { connection_id, local_addr, send_back_addr } => {
                            //println!("Incoming connection request from {}", send_back_addr.to_string());
                    }
                    SwarmEvent::IncomingConnectionError { connection_id, local_addr, send_back_addr, error } => {
                            println!("Incomming Connection Error from {}: Reason {error}", send_back_addr.to_string());
                    }
                    SwarmEvent::OutgoingConnectionError { connection_id, peer_id, error } => {
                            println!("Outgoing Connection error: Reason {error}");
                    }
                    SwarmEvent::NewListenAddr { address, .. } => {
                            //println!("Local node is listening on {address}");
                    }
                    _ => {}
                }
            }
        }
    }).await;
    Ok(())
}
