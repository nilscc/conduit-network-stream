Conduits
===

The [Conduit package](http://hackage.haskell.org/package/conduit) by [Michael
Snoyman](http://www.snoyman.com/) is an approach to the streaming data problem.
It is meant as an alternative to enumerators/iterators, hoping to address the
same issues with different trade-offs based on real-world experience with
enumerators.

Conduit statements always have a `Source` and a `Sink` for data. These can be
anything read- or writeable, for example a file, a network connection or simply
`stdin`/`stdout`. Between the `Source` and the `Sink` you can use conduits to
modify stream elements.

A very simple example for an application using conduits would be the "uppercase
copy" of a text file: The `sourceFile` streams its characters to the `uppercase`
conduit before all elements are stored to a new file by the `sinkFile` command.

```haskell
sourceFile "myfile.txt" $= uppercase $$ sinkFile "mycopy.txt"
```

For more detailed information about conduits, head over to [Michaels
github](https://github.com/snoyberg/conduit/) and take a look at the [haddock
documentation on hackage](http://hackage.haskell.org/package/conduit).


A Network Protocol with Conduits
===

The main goal of this library is a simple-to-use network library based on
conduits which supports sending and receiving of single and multiple "messages"
through one single server/client connection.

Part of the Conduit project is the [network-conduit
package](http://hackage.haskell.org/package/network-conduit), which provides
basic functions for streaming binary data over a network connection:

```haskell
type Application m = AppData m -> m ()

appSource :: AppData m -> Source m ByteString
appSink   :: AppData m -> Sink ByteString m ()

runTCPServer :: (MonadIO m, MonadBaseControl IO m)
             => ServerSettings m -> Application m -> m ()
runTCPClient :: (MonadIO m, MonadBaseControl IO m)
             => ClientSettings m -> Application m -> m ()
```

For example, you could copy a file over network by using `sourceFile` and
`appSink` in the client...

```haskell
runTCPClient (clientSettings ..) $ \appData ->
    sourceFile "myfile.txt" $$ appSink appData
```

... and `appSource` with `sinkFile` in the server:

```haskell
runTCPServer (serverSettings ..) $ \appData ->
    appSource appData $$ sinkFile "myfile-networkcopy.txt"
```

With this very rudimentary API, it is difficult to distinguish between separate
`ByteString` packages ("messages"). To solve this problem, the
`conduit-network-stream` library wraps every `ByteString` into a tiny header
which contains its exact length. This header is designed such that it's not only
possible to send single `ByteString` packages but also lists of `ByteString`s:

```haskell
send1    :: (Monad m, Sendable a m)
         => AppData m -> Source (Stream m) a -> m ()
sendList :: (Monad m, Sendable a m)
         => AppData m -> Source (Stream m) a -> m ()
```

Using these functions, it is very simple to receive those `ByteString` packages.
All you have to supply is a `ByteString` sink (Note that these are lazy
`ByteString`s):

```haskell
receive :: AppData m
        -> Sink ByteString (Stream m) b
        -> m (ResumableSource (Stream m) ByteString, b)
```

To avoid two different functions for "fresh" (`AppData m`) and "old"
(`ResumableSource`) sources I introduced a type class with instances for both:

```haskell
class Streamable source m where
      receive :: source
              -> Sink ByteString (Stream m) b
              -> m (ResumableSource (Stream m) ByteString, b)

instance Streamable (AppData m)                             m where ...
instance Streamable (ResumableSource (Stream m) ByteString) m where ...
```

With this function you could then for example define a function which would
receive [protocol-buffer](http://hackage.haskell.org/package/protocol-buffers)
messages:

```haskell
receiveProtoBuff :: (Streamable source m, ReflectDescriptor msg, Wire msg)
                 => source
                 -> Sink msg (Stream m) b
                 -> m (ResumableSource (Stream m) ByteString, b)
receiveProtoBuff src sink = receive src $ toMsg =$ sink
  where
    toMsg = Data.Conduits.List.mapMaybe $ \bs ->
              case messageGet bs of
                   Right (msg,_) -> Just msg
                   Left  _       -> Nothing
```

A simple client/server application with this package (and `-XOverloadedStrings`)
could look like this:

```haskell
client = runTCPClient myClientSettings $ \appData -> do

    -- send one single `ByteString`
    send1 appData $
        Data.Conduit.yield "Hello world!"

    -- send a `ByteString` list
    sendList appData $
        mapM_ Data.Conduit.yield ["This", "is", "a", "list", "of", "words."]

server = runTCPServer myServerSettings $ \appData -> do

    (next, bs) <- receive appData $
        Data.Conduit.List.consume

    -- print: "Hello world!"
    liftIO $
        mapM_ print bs

    (next', bs') <- receive next $
        Data.Conduit.List.consume

    -- print: "This"
    --        "is"
    --        "a"
    --        "list"
    --        "of"
    --        "words."
    liftIO $
        mapM_ print bs'

    -- close the conduit stream
    close next'
```

Note that `receive` automatically terminates as soon as the end of a list/block
is reached, without closing the connection. All conduits inside a `receive` will
only manipulate the elements of this one block/list.

Also note that I deviated from the original `Source`/`Sink` model by accepting a
`Sink`/`Source` argument to the `send`/`recive` functions instead of using the
standard `$$` operator to pipe one to the other. This has a couple of reasons:

  - *Convenience:* I found that in practice, there is very little difference
    between a `Source` and a `Sink` conduit. Usually it doesn't matter whether
    you write `src $= conduit $$ sink` or `src $$ conduit =$ sink`. Having just
    one argument to each function simplifies the API a bit.

  - *Type safety:* Using the `send` and `receive` functions I can wrap the
    "inner" conduit into a `Stream` newtype. This makes it impossible to use a
    stream with this encoding outside of its intended context. (Despite this
    point I still exported the `~~` operator, a lifted version of `$$`. There
    are a number of scenarios where this is useful, but try to avoid whenever
    possible)

  - *Immutable source:* Applying a conduit to a `Source` changes the source for
    all "resumed" instances aswell. This would make it impossible to decode the
    stream properly later on. By using `receive` this problem can be avoided.

The Protocol
---

A detailed explanation of the used protocol/header is at the top of
[`Conduit.Network.Stream.Header`](https://github.com/mcmaniac/conduit-network-stream/blob/master/src/Data/Conduit/Network/Stream/Header.hs).
