module TyTTP.Adapter.Node.URI

import Control.Monad.Maybe
import Node.URI
import TyTTP

export
uri : Alternative m
  => (
    Step me String h1 s h2 a b
    -> m $ Step me' String h1' s' h2' a' b'
  )
  -> Step me String h1 s h2 a b
  -> m $ Step me' String h1' s' h2' a' b'
uri handler step = case decodeURI step.request.url of
  Right str => handler $ { request.url := str } step
  Left _ => empty

export
uri' : Monad m
  => (
    Step me String h1 s h2 a b
    -> m $ Step me' String h1' s' h2' a' b'
  )
  -> (
    Step me String h1 s h2 a b
    -> MaybeT m $ Step me' String h1' s' h2' a' b'
  )
  -> Step me String h1 s h2 a b
  -> m $ Step me' String h1' s' h2' a' b'
uri' defHandler handler step = do
  Just result <- runMaybeT $ uri handler step
    | Nothing => defHandler step
  pure result
