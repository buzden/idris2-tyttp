module TyTTP.Adapter.Node.HTTP2

import Data.Buffer
import Data.Buffer.Ext
import Data.String
import Data.Maybe
import Node
import public Node.Error
import Node.HTTP2.Server
import TyTTP
import TyTTP.URL
import public TyTTP.Adapter.Node.Error
import TyTTP.HTTP as HTTP

namespace Fields

  public export
  data RequestPseudoHeaderField
    = Method
    | Scheme
    | Authority
    | Path

  public export
  Show RequestPseudoHeaderField where
    show f = case f of
      Method => ":method"
      Scheme => ":scheme"
      Authority => ":authority"
      Path => ":path"

  public export
  data ResponsePseudoHeaderField
    = Status

  public export
  Show ResponsePseudoHeaderField where
    show Status = ":status"

public export
RawHttpRequest : Type
RawHttpRequest = HttpRequest SimpleURL StringHeaders $ Publisher IO NodeError Buffer

public export
RawHttpResponse : Type
RawHttpResponse = Response Status StringHeaders $ Publisher IO NodeError Buffer

public export
PushContext : Type
PushContext = Context Method SimpleURL Version StringHeaders Status StringHeaders () $ Publisher IO NodeError Buffer

sendResponse : RawHttpResponse -> ServerHttp2Stream -> IO () -> IO ()
sendResponse res stream closer = do
  let status = res.status.code
  headers <- mapHeaders res.headers status

  stream.respond headers
  res.body.subscribe $ MkSubscriber
        { onNext = \a => putStrLn (show a) >> stream.write a }
        { onFailed = \e => pure () }
        { onSucceded = \_ => closer }
  where
    mapHeaders : StringHeaders -> Int -> IO Headers
    mapHeaders h s = do
      let newHeaders = singleton (show Fields.Status) (show s)
      foldlM (\hs, (k,v) => hs.setHeader k v) newHeaders h

sendResponseFromPromise : Error e
  => (String -> RawHttpResponse)
  -> Promise e IO (Context Method SimpleURL Version StringHeaders Status StringHeaders b $ Publisher IO NodeError Buffer)
  -> ServerHttp2Stream
  -> IO ()
  -> IO ()
sendResponseFromPromise errorHandler (MkPromise cont) stream closer =
  let callbacks = MkCallbacks
        { onSucceded = \a => sendResponse a.response stream closer }
        { onFailed = \e => sendResponse (errorHandler $ message e) stream stream.end }
  in
    cont callbacks

parseRequest : Node.HTTP2.Server.ServerHttp2Stream -> Headers -> Either String RawHttpRequest
parseRequest stream headers =
  let Just method = parseMethod <$> headers.getHeader (show Fields.Method)
        | Nothing => Left "Method header is missing from request"
      scheme = parse <$> headers.getHeader (show Fields.Scheme)
      authority = headers.getHeader (show Fields.Authority)
      Just pathAndSearch = headers.getHeader (show Fields.Path)
        | Nothing => Left "Path header is missing from request"
      (path, search) = String.break (=='?') pathAndSearch
      url = MkURL scheme authority path search
      version = Version_2
  in Right $ HTTP.mkRequest method url version headers.asList $ MkPublisher $ \s => do
        stream.onData s.onNext
        stream.onError s.onFailed
        stream.onEnd s.onSucceded

pusher : ServerHttp2Stream -> Lazy PushContext -> Promise NodeError IO ()
pusher parent ctx = MkPromise $ \callbacks => do
  reqHeaders <- mapHeaders $ ctx.request.headers
    <+> (maybe [] pure $ map ((show Fields.Scheme,) . show) ctx.request.url.scheme)
    <+> (maybe [] pure $ map ((show Fields.Authority,) . show) ctx.request.url.authority)
    <+> [ (show Fields.Method, show ctx.request.method)
        , (show Fields.Path, show ctx.request.url.path)
        ]
  parent.pushStream reqHeaders $ \err, stream, headers => do
    if exists err then callbacks.onFailed err
                  else sendResponse ctx.response stream $ do
                    stream.end
                    callbacks.onSucceded ()
    where
      mapHeaders : HasIO io => StringHeaders -> io Headers
      mapHeaders h = do
        newHeaders <- empty
        foldlM (\hs, (k,v) => hs.setHeader k v) newHeaders h

public export
record ListenOptions where
  constructor MkListenOptions
  port : Int
  errorHandler : (String -> RawHttpResponse)

export
defaultListenOptions : ListenOptions
defaultListenOptions = MkListenOptions
  { port = 3000
  , errorHandler = \e => MkResponse
    { status = INTERNAL_SERVER_ERROR
    , headers =
      [ ("Content-Type", "text/plain")
      , ("Content-Length", show $ length e)
      ]
    , body = singleton $ fromString e
    }
  }

export
listen : HasIO io
   => Error e
   => HTTP2
   -> ListenOptions
   -> (
        (Lazy PushContext -> Promise NodeError IO ())
        -> Context Method SimpleURL Version StringHeaders Status StringHeaders (Publisher IO NodeError Buffer) ()
        -> Promise e IO $ Context Method SimpleURL Version StringHeaders Status StringHeaders b (Publisher IO NodeError Buffer)
      )
   -> io Http2Server
listen http options handler = do
  server <- http.createServer

  server.onStream $ \stream, headers => do
    let Right req = parseRequest stream headers
          | Left err => sendResponse (options.errorHandler err) stream stream.end
        initialRes = MkResponse OK [] () {h = StringHeaders}
        push = if stream.pushAllowed then pusher stream
                                     else const $ pure ()
        result = handler push $ MkContext req initialRes

    sendResponseFromPromise options.errorHandler result stream stream.end

  server.listen options.port
  pure server

export
listen' : HasIO io
   => Error e
   => { auto http : HTTP2 }
   -> { default defaultListenOptions options : ListenOptions }
   -> (
        (Lazy PushContext -> Promise NodeError IO ())
        -> Context Method SimpleURL Version StringHeaders Status StringHeaders (Publisher IO NodeError Buffer) ()
        -> Promise e IO $ Context Method SimpleURL Version StringHeaders Status StringHeaders b (Publisher IO NodeError Buffer)
      )
   -> io Http2Server
listen' {http} {options} handler = listen http options handler
