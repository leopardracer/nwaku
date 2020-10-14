when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import std/[tables, strformat, strutils]
import confutils, chronicles, chronos, stew/shims/net as stewNet,
       eth/keys, bearssl
import libp2p/[switch,                   # manage transports, a single entry point for dialing and listening
               multistream,              # tag stream with short header to identify it
               crypto/crypto,            # cryptographic functions
               protocols/identify,       # identify the peer info of a peer
               stream/connection,        # create and close stream read / write connections
               transports/tcptransport,  # listen and dial to other peers using client-server protocol
               multiaddress,             # encode different addressing schemes. For example, /ip4/7.7.7.7/tcp/6543 means it is using IPv4 protocol and TCP
               peerinfo,                 # manage the information of a peer, such as peer ID and public / private key
               peerid,                   # Implement how peers interact
               protocols/protocol,       # define the protocol base type
               protocols/secure/secure,  # define the protocol of secure connection
               protocols/secure/secio,   # define the protocol of secure input / output, allows encrypted communication that uses public keys to validate signed messages instead of a certificate authority like in TLS
               muxers/muxer,             # define an interface for stream multiplexing, allowing peers to offer many protocols over a single connection
               muxers/mplex/mplex]       # define some contants and message types for stream multiplexing
import   ../../waku/node/v2/[config, wakunode2, waku_types],
         ../../waku/protocol/v2/[waku_relay, waku_store],
         ../../waku/node/common

const Help = """
  Commands: /[?|help|connect|disconnect|exit]
  help: Prints this help
  connect: dials a remote peer
  disconnect: ends current session
  exit: closes the chat
"""

const DefaultTopic = "waku"
const DefaultContentTopic = "dingpu"

# XXX Connected is a bit annoying, because incoming connections don't trigger state change
# Could poll connection pool or something here, I suppose
# TODO Ensure connected turns true on incoming connections, or get rid of it
type Chat = ref object
    node: WakuNode          # waku node for publishing, subscribing, etc
    transp: StreamTransport # transport streams between read & write file descriptor
    subscribed: bool        # indicates if a node is subscribed or not to a topic
    connected: bool         # if the node is connected to another peer
    started: bool           # if the node has started

type
  PrivateKey* = crypto.PrivateKey
  Topic* = waku_types.Topic

proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(ValueError,
                         "Invalid bootstrap node multi-address")

proc parsePeer(address: string): PeerInfo = 
  let multiAddr = MultiAddress.initAddress(address)
  let parts = address.split("/")
  result = PeerInfo.init(parts[^1], [multiAddr])

# NOTE Dialing on WakuRelay specifically
proc dialPeer(c: Chat, peer: PeerInfo) {.async.} =
  echo &"dialing peer: {peer.peerId}"
  # XXX Discarding conn, do we want to keep this here?
  discard await c.node.switch.dial(peer, WakuRelayCodec)
  c.connected = true

proc connectToNodes(c: Chat, nodes: openArray[string]) =
  echo "Connecting to nodes"
  for nodeId in nodes:
    let peer = parsePeer(nodeId)
    discard dialPeer(c, peer)

proc publish(c: Chat, line: string) =
  let payload = cast[seq[byte]](line)
  let message = WakuMessage(payload: payload, contentTopic: DefaultContentTopic)
  c.node.publish(DefaultTopic, message)

# TODO This should read or be subscribe handler subscribe
proc readAndPrint(c: Chat) {.async.} =
  while true:
#    while p.connected:
#      # TODO: echo &"{p.id} -> "
#
#      echo cast[string](await p.conn.readLp(1024))
    #echo "readAndPrint subscribe NYI"
    await sleepAsync(100.millis)

# TODO Implement
proc writeAndPrint(c: Chat) {.async.} =
  while true:
# Connect state not updated on incoming WakuRelay connections
#    if not c.connected:
#      echo "type an address or wait for a connection:"
#      echo "type /[help|?] for help"

    let line = await c.transp.readLine()
    if line.startsWith("/help") or line.startsWith("/?") or not c.started:
      echo Help
      continue

#    if line.startsWith("/disconnect"):
#      echo "Ending current session"
#      if p.connected and p.conn.closed.not:
#        await p.conn.close()
#      p.connected = false
    elif line.startsWith("/connect"):
      # TODO Should be able to connect to multiple peers for Waku chat
      if c.connected:
        echo "already connected to at least one peer"
        continue

      echo "enter address of remote peer"
      let address = await c.transp.readLine()
      if address.len > 0:
        let peer = parsePeer(address)
        await c.dialPeer(peer)

#    elif line.startsWith("/exit"):
#      if p.connected and p.conn.closed.not:
#        await p.conn.close()
#        p.connected = false
#
#      await p.switch.stop()
#      echo "quitting..."
#      quit(0)
    else:
      # XXX connected state problematic
      if c.started:
        c.publish(line)
        # TODO Connect to peer logic?
      else:
        try:
          if line.startsWith("/") and "p2p" in line:
            let peer = parsePeer(line)
            await c.dialPeer(peer)
        except:
          echo &"unable to dial remote peer {line}"
          echo getCurrentExceptionMsg()

proc readWriteLoop(c: Chat) {.async.} =
  asyncCheck c.writeAndPrint() # execute the async function but does not block
  asyncCheck c.readAndPrint()

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  let transp = fromPipe(wfd)

  while true:
    let line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc processInput(rfd: AsyncFD, rng: ref BrHmacDrbgContext) {.async.} =
  let transp = fromPipe(rfd)

  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.libp2pAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort, conf.topics.split(" "))

  # waitFor vs await
  await node.start()

  var chat = Chat(node: node, transp: transp, subscribed: true, connected: false, started: true)

  if conf.staticnodes.len > 0:
    connectToNodes(chat, conf.staticnodes)

  let peerInfo = node.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  echo &"Listening on\n {listenStr}"

  let topic = cast[Topic](DefaultContentTopic)
  let multiAddr = MultiAddress.initAddress(conf.storenode)
  let parts = conf.storenode.split("/")

  node.wakuStore.setPeer(PeerInfo.init(parts[^1], [multiAddr]))

  proc storeHandler(response: HistoryResponse) {.gcsafe.} =
    for msg in response.messages:
      let payload = cast[string](msg.payload)
      echo &"{payload}"
    info "Hit store handler"

  await node.query(HistoryQuery(topics: @[topic]), storeHandler)

  # Subscribe to a topic
  # TODO To get end to end sender would require more information in payload
  # We could possibly indicate the relayer point with connection somehow probably (?)
  proc handler(topic: Topic, data: seq[byte]) {.async, gcsafe.} =
    let message = WakuMessage.init(data).value
    let payload = cast[string](message.payload)
    echo &"{payload}"
    info "Hit subscribe handler", topic=topic, payload=payload, contentTopic=message.contentTopic

  # XXX Timing issue with subscribe, need to wait a bit to ensure GRAFT message is sent
  await sleepAsync(5.seconds)
  await node.subscribe(topic, handler)

  await chat.readWriteLoop()
  runForever()
  #await allFuturesThrowing(libp2pFuts)

proc main() {.async.} =
  let rng = crypto.newRng() # Singe random number source for the whole application
  let (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")

  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)

  await processInput(rfd, rng)

when isMainModule: # isMainModule = true when the module is compiled as the main file
  waitFor(main())

## Dump of things that can be improved:
##
## - Incoming dialed peer does not change connected state (not relying on it for now)
## - Unclear if staticnode argument works (can enter manually)
## - Don't trigger self / double publish own messages
## - Integrate store protocol (fetch messages in beginning)
## - Integrate filter protocol (default/option to be light node, connect to filter node)
## - Test/default to cluster node connection (diff protocol version)
## - Redirect logs to separate file
## - Expose basic publish/subscribe etc commands with /syntax
## - Show part of peerid to know who sent message
## - Deal with protobuf messages (e.g. other chat protocol, or encrypted)