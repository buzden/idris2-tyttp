module TyTTP.HTTP.Consumer.JSON

import Data.Buffer
import Data.Mime.Apache
import JSON
import Language.JSON as LJ
import Node.Buffer
import TyTTP.HTTP.Consumer

%hide Language.JSON.Data.JSON

export
data JSON : Type where

export
implementation Accept JSON where
  contentType _ = [ show APPLICATION_JSON ]

export
implementation FromJSON a => Consumer a JSON where
  consumeRaw _ ct raw = 
    mapFst show $ decode $ toStringUTF8 raw
