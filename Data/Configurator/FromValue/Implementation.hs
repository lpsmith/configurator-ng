{-# LANGUAGE CPP, DeriveDataTypeable, DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances, DefaultSignatures #-}
{-# LANGUAGE ScopedTypeVariables, BangPatterns, ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module:      Data.Configurator.FromValue.Implementation
-- Copyright:   (c) 2016 Leon P Smith
-- License:     BSD3
-- Maintainer:  Leon P Smith <leon@melding-monads.com>

module Data.Configurator.FromValue.Implementation where

import           Control.Applicative
import           Control.Arrow (first, second)
import           Control.Exception (Exception)
import           Control.Monad (ap)
import qualified Control.Monad.Fail as Fail
import           Data.ByteString(ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import           Data.Complex (Complex((:+)))
import           Data.Configurator.Types(Value(..))
import           Data.DList (DList)
import qualified Data.DList as DList
import           Data.Fixed (Fixed, HasResolution)
import           Data.Int(Int8, Int16, Int32, Int64)
import           Data.Monoid
import           Data.Ratio ( Ratio, (%) )
import           Data.Scientific
                   ( Scientific,  coefficient, base10Exponent, normalize
                   , floatingOrInteger, toRealFloat, toBoundedInteger )
import           Data.Text(Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as L
import           Data.Text.Encoding(encodeUtf8)
import           Data.Typeable(Typeable, TypeRep, typeOf)
import           Data.Word(Word8, Word16, Word32, Word64)
import           Foreign.C.Types(CFloat, CDouble)

type ConversionErrors = Maybe (DList ConversionError)

data ConversionError = ConversionError {
      conversionErrorLoc  :: Text,
      conversionErrorWhy  :: ConversionErrorWhy,
      conversionErrorVal  :: !(Maybe Value),
      conversionErrorType :: !(Maybe TypeRep),
      conversionErrorSub  :: ![ConversionError],
      conversionErrorMsg  :: !(Maybe Text)
    } deriving (Show, Typeable)

instance Exception ConversionError

data ConversionErrorWhy =
    MissingValue
  | ExtraValues
  | ExhaustedValues
  | TypeError
  | ValueError
  | MonadFail
  | OtherError
    deriving (Eq, Typeable, Show)

defaultConversionError :: ConversionError
defaultConversionError =
    ConversionError "" OtherError Nothing Nothing [] Nothing

singleError :: ConversionError -> ConversionErrors
singleError = Just . DList.singleton

toErrors :: ConversionErrors -> [ConversionError]
toErrors = maybe [] DList.toList

newtype MaybeParser a = MaybeParser {
      unMaybeParser :: Maybe Value -> (Maybe a, ConversionErrors)
    } deriving (Functor, Typeable)

newtype ValueParser a = ValueParser {
      unValueParser :: Value -> (Maybe a, ConversionErrors)
    } deriving (Functor, Typeable)

data ListParserResult a =
     NonListError
   | ListError
   | ListOk a [Value]
     deriving (Functor, Typeable)

newtype ListParser a = ListParser {
      unListParser :: [Value] -> (ListParserResult a, ConversionErrors)
    } deriving (Functor, Typeable)

instance Applicative MaybeParser where
    pure a = MaybeParser $ \_v -> (Just a, mempty)
    (<*>) ff fa =
        MaybeParser $ \v ->
            case unMaybeParser ff v of
              (Nothing, w) -> (Nothing, w)
              (Just f , w) ->
                  case unMaybeParser fa v of
                    (Nothing, w') -> (Nothing   , w <> w')
                    (Just a , w') -> (Just (f a), w <> w')

instance Applicative ValueParser where
    pure a = ValueParser $ \_v -> (Just a, mempty)
    (<*>) ff fa =
        ValueParser $ \v ->
            case unValueParser ff v of
              (Nothing, w) -> (Nothing, w)
              (Just f , w) ->
                  case unValueParser fa v of
                    (Nothing, w') -> (Nothing   , w <> w')
                    (Just a , w') -> (Just (f a), w <> w')

instance Alternative ValueParser where
    empty   = ValueParser $ \_v -> (Nothing, mempty)
    f <|> g = ValueParser $ \v ->
                 case unValueParser f v of
                   (Nothing, Nothing) -> unValueParser g v
                   (Nothing, w) ->
                       case unValueParser g v of
                         (Nothing, w') -> (Nothing, w <> w')
                         res -> res
                   res -> res

    some v = repeat <$> v
    many v = some v <|> pure []

instance Alternative MaybeParser where
    empty   = MaybeParser $ \_v -> (Nothing, mempty)
    f <|> g = MaybeParser $ \v ->
                 case unMaybeParser f v of
                   (Nothing, Nothing) -> unMaybeParser g v
                   (Nothing, w) ->
                       case unMaybeParser g v of
                         (Nothing, w') -> (Nothing, w <> w')
                         res -> res
                   res -> res

    some v = repeat <$> v
    many v = some v <|> pure []

instance Monad MaybeParser where
#if !(MIN_VERSION_base(4,8,0))
    return = pure
#endif
    m >>= k  = MaybeParser $ \v ->
                   case unMaybeParser m v of
                     (Just a, w) ->
                         case w of
                           Nothing -> unMaybeParser (k a) v
                           Just _  -> let (mb, w') = unMaybeParser (k a) v
                                       in (mb, w <> w')
                     (Nothing, w) -> (Nothing, w)

    fail = Fail.fail

instance Monad ValueParser where
#if !(MIN_VERSION_base(4,8,0))
    return = pure
#endif
    m >>= k  = ValueParser $ \v ->
                   case unValueParser m v of
                     (Just a, w) ->
                         case w of
                           Nothing -> unValueParser (k a) v
                           Just _  -> let (mb, w') = unValueParser (k a) v
                                       in (mb, w <> w')
                     (Nothing, w) -> (Nothing, w)

    fail = Fail.fail

instance Fail.MonadFail MaybeParser where
    fail msg = MaybeParser $ \_v -> (Nothing, singleError (failError msg))

instance Fail.MonadFail ValueParser where
    fail msg = ValueParser $ \_v -> (Nothing, singleError (failError msg))

failError :: String -> ConversionError
failError msg = defaultConversionError {
                  conversionErrorLoc = "fail",
                  conversionErrorWhy = MonadFail,
                  conversionErrorMsg = Just (T.pack msg)
                }

runMaybeParser :: MaybeParser a -> Maybe Value -> (Maybe a, [ConversionError])
runMaybeParser p = second toErrors . unMaybeParser p

runValueParser :: ValueParser a -> Value -> (Maybe a, [ConversionError])
runValueParser p = second toErrors . unValueParser p

instance Applicative ListParser where
    pure a = ListParser $ \vs -> (ListOk a vs, mempty)
    (<*>) = ap

instance Alternative ListParser where
    empty   = ListParser $ \_v -> (ListError, mempty)
    f <|> g = ListParser $ \v ->
                 case unListParser f v of
                   (ListError, Nothing)  -> unListParser g v
                   (ListError, w) ->
                       case unListParser g v of
                         (ListError, w') -> (ListError, w <> w')
                         res -> res
                   res -> res

instance Monad ListParser where
#if !(MIN_VERSION_base(4,8,0))
    return = pure
#endif
    m >>= k  = ListParser $ \v ->
                   case unListParser m v of
                     (ListOk a v', w) ->
                         case w of
                           Nothing -> unListParser (k a) v'
                           Just _  -> let (mb, w') = unListParser (k a) v'
                                       in (mb, w <> w')
                     (ListError, w) ->
                         (ListError, w)
                     (NonListError, w) ->
                         (NonListError, w)

    fail = Fail.fail

instance Fail.MonadFail ListParser where
    fail msg = ListParser $ \_v -> (NonListError, singleError (failError msg))

optionalValue :: ValueParser a -> MaybeParser (Maybe a)
optionalValue p =
    MaybeParser $ \mv ->
       case mv of
         Nothing -> (Just Nothing, mempty)
         Just v  -> first (Just <$>) (unValueParser p v)
                      

requiredValue :: forall a. Typeable a => ValueParser a -> MaybeParser a
requiredValue p =
    MaybeParser $ \mv ->
        case mv of
          Nothing -> (Nothing, err)
          Just v  -> unValueParser p v
  where
    funcName = "requiredValue"
    err = singleError $ missingValueError funcName (typeOf (undefined :: a))

missingValueError :: Text -> TypeRep -> ConversionError
missingValueError funcName typ = defaultConversionError {
      conversionErrorLoc  = funcName,
      conversionErrorWhy  = MissingValue,
      conversionErrorType = Just typ
   }

listValue :: forall a. Typeable a => ListParser a -> ValueParser a
listValue p =
    ValueParser $ \v ->
        case v of
          List vs ->
              case unListParser p vs of
                (ListOk a vs', errs) ->
                   case vs' of
                     []    -> (Just a, errs)
                     (_:_) -> (,) (Just a) $! errs <> extraErr vs
                (_, errs)  -> (Nothing, errs)
          _ -> (Nothing, typeErr v)
  where
    fn = "listValue"
    extraErr vs = singleError $ extraValuesError fn vs (typeOf (undefined :: a))
    typeErr  v  = singleError $ typeError        fn v  (typeOf (undefined :: a))

listValue' :: forall a. Typeable a => ListParser a -> ValueParser a
listValue' p =
    ValueParser $ \v ->
        case v of
          List vs ->
              case unListParser p vs of
                (ListOk a vs', errs) ->
                   case vs' of
                     []    -> (Just a, errs)
                     (_:_) -> (,) Nothing $! errs <> extraErr vs
                (_, errs)  -> (Nothing, errs)
          _ -> (Nothing, typeErr v)
  where
    fn = "listValue'"
    extraErr vs = singleError $ extraValuesError fn vs (typeOf (undefined :: a))
    typeErr  v  = singleError $ typeError        fn v  (typeOf (undefined :: a))

listElem :: ValueParser a -> ListParser a
listElem p =
    ListParser $ \vs ->
        case vs of
          [] -> (ListError, mempty)
          (v:vs') -> case unValueParser p v of
                       (Nothing, errs) -> (NonListError, errs)
                       (Just a,  errs) -> (ListOk a vs', errs)

extraValuesError :: Text -> [Value] -> TypeRep -> ConversionError
extraValuesError funcName vals typ
    = defaultConversionError {
        conversionErrorLoc  = funcName,
        conversionErrorWhy  = ExtraValues,
        conversionErrorVal  = Just (List vals),
        conversionErrorType = Just typ
      }

typeError :: Text -> Value -> TypeRep -> ConversionError
typeError funcName val typ
    = defaultConversionError {
        conversionErrorLoc  = funcName,
        conversionErrorWhy  = TypeError,
        conversionErrorVal  = Just val,
        conversionErrorType = Just typ
      }

boundedIntegerValue :: forall a. (Typeable a, Integral a, Bounded a)
                    => ValueParser a
boundedIntegerValue =
    ValueParser $ \v ->
        case v of
          (Number r) ->
              case toBoundedInteger r of
                ja@(Just _) -> (ja     , mempty)
                Nothing     -> (Nothing, overflowErr r)
          _ -> (Nothing, typeErr v)
  where
    fn = "boundedIntegerValue"
    overflowErr v = singleError (overflowError fn v (typeOf (undefined :: a)))
    typeErr     v = singleError (typeError     fn v (typeOf (undefined :: a)))

overflowError :: Text -> Scientific -> TypeRep -> ConversionError
overflowError fn val typ = valueError fn (Number val) typ "overflow"

valueError :: Text -> Value -> TypeRep -> Text -> ConversionError
valueError funcName val typ msg
    = defaultConversionError {
        conversionErrorLoc  = funcName,
        conversionErrorWhy  = ValueError,
        conversionErrorVal  = Just val,
        conversionErrorType = Just typ,
        conversionErrorMsg  = Just msg
      }

integralValue :: forall a. (Typeable a, Integral a) => ValueParser a
integralValue =
    ValueParser $ \v ->
        case v of
          Number r ->
              if base10Exponent r >= 0
              then toIntegral v r
              else let r' = normalize r
                   in if base10Exponent r' >= 0
                      then toIntegral v r'
                      else (Nothing, intErr r)
          _  -> (Nothing, typeErr v)
  where
    fn = "integralValue"
    intErr  r = singleError (notAnIntegerError fn r (typeOf (undefined :: a)))
    typeErr v = singleError (typeError         fn v (typeOf (undefined :: a)))

    toIntegral v r =
        case floatingOrInteger r of
          Right a -> (Just a, mempty)
          -- This case should be impossible:
          Left  (_::Float) -> (Nothing, intErr r)

notAnIntegerError :: Text -> Scientific -> TypeRep -> ConversionError
notAnIntegerError fn val typ = valueError fn (Number val) typ "not an integer"

fractionalValue :: forall a. (Typeable a, Fractional a) => ValueParser a
fractionalValue =
    ValueParser $ \v ->
        case v of
          Number r ->
              let !c   = coefficient    r
                  !e   = base10Exponent r
                  !r'  = fromRational $! if e >= 0
                                         then (c * 10^e) % 1
                                         else c % (10^(- e))
               in (Just r', mempty)
          _ -> (Nothing, typeErr v)
  where
    fn = "fractionalValue"
    typeErr v = singleError (typeError fn v (typeOf (undefined :: a)))

realFloatValue :: forall a. (Typeable a, RealFloat a) => ValueParser a
realFloatValue = realFloatValue_ (typeOf (undefined :: a))

realFloatValue_ :: (RealFloat a) => TypeRep -> ValueParser a
realFloatValue_ typ =
    ValueParser $ \v ->
        case v of
          Number (toRealFloat -> !r) -> (Just r, mempty)
          _ -> (Nothing, typeErr v)
  where
    fn = "realFloatValue"
    typeErr v = singleError (typeError fn v typ)

fixedValue :: forall a. (Typeable a, HasResolution a) => ValueParser (Fixed a)
fixedValue = fractionalValue
  -- FIXME: optimize fixedValue and/or Data.Fixed

class FromMaybeValue a where
    fromMaybeValue :: MaybeParser a
    default fromMaybeValue :: (Typeable a, FromValue a) => MaybeParser a
    fromMaybeValue = requiredValue fromValue

class FromValue a where
    fromValue :: ValueParser a

class FromListValue a where
    fromListValue :: ListParser a

instance FromValue a => FromMaybeValue (Maybe a) where
    fromMaybeValue = optionalValue fromValue

instance FromMaybeValue Int
instance FromValue Int where
    fromValue = boundedIntegerValue

instance FromMaybeValue Integer
instance FromValue Integer where
    fromValue = integralValue

instance FromMaybeValue Int8
instance FromValue Int8 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Int16
instance FromValue Int16 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Int32
instance FromValue Int32 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Int64
instance FromValue Int64 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Word
instance FromValue Word where
    fromValue = boundedIntegerValue

instance FromMaybeValue Word8
instance FromValue Word8 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Word16
instance FromValue Word16 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Word32
instance FromValue Word32 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Word64
instance FromValue Word64 where
    fromValue = boundedIntegerValue

instance FromMaybeValue Double
instance FromValue Double where
    fromValue = realFloatValue

instance FromMaybeValue Float
instance FromValue Float where
    fromValue = realFloatValue

instance FromMaybeValue CDouble
instance FromValue CDouble where
    fromValue = realFloatValue

instance FromMaybeValue CFloat
instance FromValue CFloat where
    fromValue = realFloatValue

instance (Typeable a, Integral a) => FromMaybeValue (Ratio a)
instance (Typeable a, Integral a) => FromValue (Ratio a) where
    fromValue = fractionalValue

instance FromMaybeValue Scientific
instance FromValue Scientific where
    fromValue = scientificValue

scientificValue :: ValueParser Scientific
scientificValue =
    ValueParser $ \v ->
        case v of
          Number r -> (Just r, mempty)
          _ -> (Nothing, typeErr v)
  where
    fn = "scientificValue"
    typeErr v = singleError (typeError fn v (typeOf (undefined :: Scientific)))

instance (Typeable a, RealFloat a) => FromMaybeValue (Complex a)
instance (Typeable a, RealFloat a) => FromValue (Complex a) where
    fromValue = (:+ 0) <$> realFloatValue_ (typeOf (undefined :: Complex a))

instance (Typeable a, HasResolution a) => FromMaybeValue (Fixed a)
instance (Typeable a, HasResolution a) => FromValue (Fixed a) where
    fromValue = fixedValue

instance FromMaybeValue Text
instance FromValue Text where
    fromValue = textValue

textValue :: ValueParser Text
textValue = textValue_ (typeOf (undefined :: Text))

textValue_ :: TypeRep -> ValueParser Text
textValue_ typ =
    ValueParser $ \v ->
        case v of
          String r -> (Just r, mempty)
          _ -> (Nothing, typeErr v typ)
  where
    fn = "textValue"
    typeErr v t = singleError (typeError fn v t)

instance FromMaybeValue Char
instance FromValue Char where
    fromValue = charValue

charValue :: ValueParser Char
charValue =
    ValueParser $ \v ->
        case v of
          String txt ->
              case T.uncons txt of
                Nothing           -> (Nothing, charErr txt)
                Just (c,txt')
                    | T.null txt' -> (Just  c, mempty)
                    | otherwise   -> (Nothing, charErr txt)
          _ -> (Nothing, typeErr v)
  where
    fn  = "charValue"
    typ = typeOf (undefined :: Char)
    msg = "expecting exactly one character"
    charErr v = singleError (valueError fn (String v) typ msg)
    typeErr v = singleError (typeError fn v typ)

instance FromMaybeValue L.Text
instance FromValue L.Text where
    fromValue = L.fromStrict <$> textValue_ (typeOf (undefined :: L.Text))

instance FromMaybeValue B.ByteString
instance FromValue B.ByteString where
    fromValue = encodeUtf8 <$> textValue_ (typeOf (undefined :: B.ByteString))

instance FromMaybeValue LB.ByteString
instance FromValue LB.ByteString where
    fromValue = convert <$> textValue_ (typeOf (undefined :: LB.ByteString))
      where convert = LB.fromStrict . encodeUtf8

instance ( Typeable a, FromValue a
         , Typeable b, FromValue b ) => FromMaybeValue (a,b)
instance ( Typeable a, FromValue a
         , Typeable b, FromValue b ) => FromValue (a,b) where
    fromValue = listValue fromListValue
instance ( Typeable a, FromValue a
         , Typeable b, FromValue b ) => FromListValue (a,b) where
    fromListValue = (,) <$> listElem fromValue <*> listElem fromValue

instance ( Typeable a, FromValue a
         , Typeable b, FromValue b
         , Typeable c, FromValue c ) => FromMaybeValue (a,b,c)
instance ( Typeable a, FromValue a
         , Typeable b, FromValue b
         , Typeable c, FromValue c ) => FromValue (a,b,c) where
    fromValue = listValue fromListValue
instance ( Typeable a, FromValue a
         , Typeable b, FromValue b
         , Typeable c, FromValue c ) => FromListValue (a,b,c) where
    fromListValue = (,,) <$> listElem fromValue <*> listElem fromValue
                         <*> listElem fromValue

instance ( Typeable a, FromValue a
         , Typeable b, FromValue b
         , Typeable c, FromValue c
         , Typeable d, FromValue d ) => FromMaybeValue (a,b,c,d)
instance ( Typeable a, FromValue a
         , Typeable b, FromValue b
         , Typeable c, FromValue c
         , Typeable d, FromValue d ) => FromValue (a,b,c,d) where
    fromValue = listValue fromListValue
instance ( Typeable a, FromValue a
         , Typeable b, FromValue b
         , Typeable c, FromValue c
         , Typeable d, FromValue d ) => FromListValue (a,b,c,d) where
    fromListValue = (,,,) <$> listElem fromValue <*> listElem fromValue
                          <*> listElem fromValue <*> listElem fromValue

{--
parserFail :: forall a. Typeable a => T.Text -> Maybe T.Text -> ValueParser a
parserFail loc msg = ValueParser $ \st -> (Nothing, failError, st)
       where
         failError = singleError defaultConversionError {
                       conversionErrorLoc  = loc
                       conversionErrorWhy  = MonadFail,
                       conversionErrorType = Just (typeRep (undefined :: a)),
                       conversionErrorMsg  = msg
                     }
--}

{--
defaultValue :: Typeable a => a -> ValueParser a -> ValueParser a
defaultValue def m =
    ValueParser $ \vs ->
        case vs of
          (Nothing:vs') -> (Just def, mempty, vs')
          _
--}