Conduits
===

The [Conduit package](http://hackage.haskell.org/package/conduit) by Michael
Snoyman 

Conduits always have a `Source` and a `Sink` for your data. These can be
anything read- or writeable, for example a file, a network connection or
simply `stdin`/`stdout`. Between the `Source` and the `Sink` you can use
`Conduit`s to modify stream elements.

The following example copies a file and turns all letters in it to capital
letters. The `sourceFile` streams its `Char`s to the `uppercase` conduit before
all elements are stored to the new file by the `sinkFile` command:

    sourceFile "myfile.txt" $= uppercase $$ sinkFile "mycopy.txt"

For more detailed information about conduits, head over to [Michaels
github](https://github.com/snoyberg/conduit/) and take a look at the [haddock
documentation on hackage](http://hackage.haskell.org/package/conduit).


A Network Protocol with Conduits
===

Part of the Conduit project is the [network-conduit
package](http://hackage.haskell.org/package/network-conduit), which provides
basic functions for streaming binary data over a network connection:

    type Application m = AppData m -> m ()

    appSource :: AppData m -> Source m ByteString
    appSink   :: AppData m -> Sink ByteString m ()

    runTCPServer :: (MonadIO m, MonadBaseControl IO m)
                 => ServerSettings m -> Application m -> m ()
    runTCPClient :: (MonadIO m, MonadBaseControl IO m)
                 => ClientSettings m -> Application m -> m ()

For example, you could copy a file over network by using `sourceFile` and
`appSink` in the client...

    runTCPClient (clientSettings ..) $ \appData ->
      sourceFile "myfile.txt" $$ appSink appData

... and `appSource` with `sinkFile` in the server:

    runTCPServer (serverSettings ..) $ \appData ->
      appSource appData $$ sinkFile "myfile-networkcopy.txt"

With this very rudimentary API, it is difficult to distinguish between separate
`ByteString` packages ("messages"). To solve this problem, the
`conduit-network-stream` library wraps every `ByteString` into a tiny header
which contains its exact length. This header is designed such that it's not only
possible to send single `ByteString` packages but also lists of `ByteString`s:

    send1    :: (Monad m, Sendable a m)
             => AppData m -> Source (Stream m) a -> m ()
    sendList :: (Monad m, Sendable a m)
             => AppData m -> Source (Stream m) a -> m ()

Using these functions, it is very simple to receive a block or list 

    receive :: AppData m
            -> Sink ByteString (Stream m) b
            -> m (ResumableSource (Stream m) ByteString, b)

To avoid 2 different functions for "fresh" (`AppData m`) and "old"
(`ResumableSource`) sources I introduced a type class with instances for both:

    class Streamable source m where
          receive :: source
                  -> Sink ByteString (Stream m) b
                  -> m (ResumableSource (Stream m) ByteString, b)

A simple client/server application with this package (and `-XOverloadedStrings`)
could look like:

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



If you want to stream [protcol
buffers](http://hackage.haskell.org/package/protocol-buffers)

The Protocol
---

A detailed explanation of the used protocol header is at the top of the
[`Conduit.Network.Stream.Header`
module](https://github.com/mcmaniac/conduit-network-stream/blob/master/src/Data/Conduit/Network/Stream/Header.hs).
