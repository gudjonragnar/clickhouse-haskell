{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE BlockArguments #-}
module ClickHouseDriver.Core.Column(
  readColumn,
  ClickhouseType(..),
  transpose,
  writeColumn,
  ClickHouseDriver.Core.Column.putStrLn
) where

import ClickHouseDriver.Core.Types
import ClickHouseDriver.IO.BufferedReader
import ClickHouseDriver.IO.BufferedWriter
import Data.Binary (Word64, Word8)
import Data.Int (Int64)
import Data.Bits ((.&.), (.|.), shift)
import qualified Data.ByteString as BS
  ( drop,
    filter,
    intercalate,
    length,
    pack,
    splitWith,
    take,
    unpack,
  )
import Data.ByteString (ByteString, isPrefixOf)
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Char8 as C8
import Data.ByteString.Char8 (readInt)
import qualified Data.List as List
import qualified Data.HashMap.Strict as Map
import Data.Maybe (fromJust)
import Data.Time (Day, addDays, diffDays, fromGregorian, toGregorian)
import Data.UUID as UUID (fromString, fromWords, toString, toWords)
import Data.UnixTime (UnixTime (..), formatUnixTimeGMT, webDateFormat)
import Data.Vector ((!), (!?), Vector)
import Data.Hashable
import qualified Data.Vector as V
  ( cons,
    drop,
    fromList,
    generate,
    length,
    map,
    mapM,
    mapM_,
    replicateM,
    scanl',
    sum,
    take,
    toList,
    zipWith,
    zipWithM_,
    foldl'
  )
import Foreign.C.Types (CTime (..))
import Network.IP.Addr (IP4 (..), IP6 (..))
--Debug 
import Debug.Trace
---------------------------------------------------------------------------------------
---Readers 

readColumn ::  Int -> ByteString -> Reader (Vector ClickhouseType)
readColumn n_rows spec
  | "String" `isPrefixOf` spec = V.replicateM n_rows (CKString <$> readBinaryStr)
  | "Array" `isPrefixOf` spec = readArray n_rows spec
  | "FixedString" `isPrefixOf` spec = readFixed n_rows spec
  | "DateTime" `isPrefixOf` spec = readDateTime n_rows spec
  | "Date"     `isPrefixOf` spec = readDate n_rows
  | "Tuple" `isPrefixOf` spec = readTuple n_rows spec
  | "Nullable" `isPrefixOf` spec = readNullable n_rows spec
  | "LowCardinality" `isPrefixOf` spec = readLowCadinality n_rows spec
  | "Decimal" `isPrefixOf` spec = readDecimal n_rows spec
  | "Enum" `isPrefixOf` spec = readEnum n_rows spec
  | "Int" `isPrefixOf` spec = readIntColumn n_rows spec
  | "UInt" `isPrefixOf` spec = readIntColumn n_rows spec
  | "IPv4" `isPrefixOf` spec = readIPv4 n_rows
  | "IPv6" `isPrefixOf` spec = readIPv6 n_rows
  | "SimpleAggregateFunction" `isPrefixOf` spec = readSimpleAggregateFunction n_rows spec
  | "UUID" `isPrefixOf` spec = readUUID n_rows
  | otherwise = error ("Unknown Type: " Prelude.++ C8.unpack spec)

writeColumn :: Context
             -- ^ context
             ->ByteString
             -- ^ column name
             ->ByteString
             -- ^ column type
             ->Vector ClickhouseType
             -- ^ items
             ->IOWriter Builder
writeColumn ctx col_name cktype items
  | "String" `isPrefixOf` cktype = writeStringColumn col_name items
  | "FixedString(" `isPrefixOf` cktype = do
    let l = BS.length cktype
    let Just (len, _) = readInt $ BS.take(l - 13) (BS.drop 12 cktype)
    writeFixedLengthString col_name (fromIntegral len) items
  | "Int" `isPrefixOf` cktype || "UInt" `isPrefixOf` cktype =  do
    let Just (indicator, _) = readInt $ BS.drop 3 cktype
    writeIntColumn indicator col_name items
  | "Nullable(" `isPrefixOf` cktype = do
    let l = BS.length cktype
    let inner = BS.take (l - 10) (BS.drop 9 cktype)
    writeNullsMap items
    writeColumn ctx col_name inner items
  | "Tuple" `isPrefixOf` cktype = writeTuple ctx col_name cktype items
  | "Enum" `isPrefixOf` cktype = writeEnum col_name cktype items
  | "Array" `isPrefixOf` cktype = writeArray ctx col_name cktype items
  | "UUID" `isPrefixOf` cktype = writeUUID col_name items
  | "IPv4" `isPrefixOf` cktype = writeIPv4 col_name items
  | "IPv6" `isPrefixOf` cktype = writeIPv6 col_name items
  | "Date" `isPrefixOf` cktype = writeDate col_name items
  | "LowCardinality" `isPrefixOf` cktype = writeLowCardinality ctx col_name cktype items
---------------------------------------------------------------------------------------------
readFixed :: Int -> ByteString -> Reader (Vector ClickhouseType)
readFixed n_rows spec = do
  let l = BS.length spec
  let strnumber = BS.take (l - 13) (BS.drop 12 spec)
  let number = case readInt strnumber of
        Nothing -> 0 -- This can't happen
        Just (x, _) -> x
  result <- V.replicateM n_rows (readFixedLengthString number)
  return result

readFixedLengthString :: Int -> Reader ClickhouseType
readFixedLengthString strlen = (CKString) <$> (readBinaryStrWithLength strlen)

writeStringColumn :: ByteString->Vector ClickhouseType->IOWriter Builder
writeStringColumn col_name = V.mapM_ 
  (\case CKString s -> writeBinaryStr s;
         CKNull-> writeVarUInt 0;
         _ -> error (typeMismatchError col_name))

writeFixedLengthString :: ByteString->Word->Vector ClickhouseType->IOWriter Builder
writeFixedLengthString col_name len items = do
  V.mapM_ (\case CKString s->writeBinaryFixedLengthStr len s
                 CKNull-> (\x->()) <$> V.replicateM (fromIntegral len) (writeVarUInt 0)
                 x -> error (typeMismatchError col_name ++ " got: " ++ show x)) items
---------------------------------------------------------------------------------------------
readIntColumn ::  Int -> ByteString -> Reader (Vector ClickhouseType)
readIntColumn n_rows "Int8" = V.replicateM n_rows (CKInt8 <$> readBinaryInt8)
readIntColumn n_rows "Int16" = V.replicateM n_rows (CKInt16 <$> readBinaryInt16)
readIntColumn n_rows "Int32" = V.replicateM n_rows (CKInt32 <$> readBinaryInt32)
readIntColumn n_rows "Int64" = V.replicateM n_rows (CKInt64 <$> readBinaryInt64)
readIntColumn n_rows "UInt8" = V.replicateM n_rows (CKUInt8 <$> readBinaryUInt8)
readIntColumn n_rows "UInt16" = V.replicateM n_rows (CKUInt16 <$> readBinaryUInt16)
readIntColumn n_rows "UInt32" = V.replicateM n_rows (CKUInt32 <$> readBinaryUInt32)
readIntColumn n_rows "UInt64" = V.replicateM n_rows (CKUInt64 <$> readBinaryUInt64)
readIntColumn _ _ = error "Not an integer type"

writeIntColumn :: Int -> ByteString -> Vector ClickhouseType -> IOWriter Builder
writeIntColumn indicator col_name =
  case indicator of
    8 ->
      V.mapM_
        ( \case
            CKInt8 x -> writeBinaryInt8 x
            CKNull -> writeBinaryInt8 0
            _ -> error (typeMismatchError col_name)
        )
    16 ->
      V.mapM_
        ( \case
            CKInt16 x -> writeBinaryInt16 x
            CKNull -> writeBinaryInt16 0
            _ -> error (typeMismatchError col_name)
        )
    32 ->
      V.mapM_
        ( \case
            CKInt32 x -> writeBinaryInt32 x
            CKNull -> writeBinaryInt32 0
            _ -> error (typeMismatchError col_name)
        )
    64 ->
      V.mapM_
        ( \case
            CKInt64 x -> writeBinaryInt64 x
            CKNull -> writeBinaryInt64 0
            _ -> error (typeMismatchError col_name)
        )

writeUIntColumn :: Int -> ByteString -> Vector ClickhouseType -> IOWriter Builder
writeUIntColumn indicator col_name =
  case indicator of
    8 ->
      V.mapM_
        ( \case
            CKUInt8 x -> writeBinaryUInt8 x
            CKNull -> writeBinaryUInt8 0
            _ -> error (typeMismatchError col_name)
        )
    16 ->
      V.mapM_
        ( \case
            CKUInt16 x -> writeBinaryInt16 $ fromIntegral x
            CKNull -> writeBinaryInt16 0
            _ -> error (typeMismatchError col_name)
        )
    32 ->
      V.mapM_
        ( \case
            CKUInt32 x -> writeBinaryInt32 $ fromIntegral x
            CKNull -> writeBinaryInt32 0
            _ -> error (typeMismatchError col_name)
        )
    64 ->
      V.mapM_
        ( \case
            CKUInt64 x -> writeBinaryInt64 $ fromIntegral x
            CKNull -> writeBinaryInt64 0
            _ -> error (typeMismatchError col_name)
        )
---------------------------------------------------------------------------------------------
readDateTime :: Int -> ByteString -> Reader (Vector ClickhouseType)
readDateTime n_rows spec = do
  let (scale, spc) = readTimeSpec spec
  case spc of
    Nothing -> error "Error : can't read localzone"
    Just tz_name -> readDateTimeWithSpec n_rows scale tz_name
  where
    readTimeSpec :: ByteString -> (Maybe Int, Maybe ByteString)
    readTimeSpec spec'
      | "DateTime64" `isPrefixOf` spec' = do
        let l = BS.length spec'
        let innerspecs = BS.take (l - 11) (BS.drop 10 spec')
        let splited = getSpecs innerspecs
        case splited of
          [] -> (Nothing, Nothing)
          [x] -> (Just $ fst $ fromJust $ readInt x, Just "")
          [x, y] -> (Just $ fst $ fromJust $ readInt x, Just y)
      | otherwise = do
        let l = BS.length spec'
        let innerspecs = BS.take (l - 9) (BS.drop 8 spec')
        (Nothing, Just innerspecs)
    readDateTimeWithSpec :: Int -> Maybe Int -> ByteString -> Reader (Vector ClickhouseType)
    readDateTimeWithSpec n_rows Nothing tz_name = do
      data32 <- readIntColumn n_rows "Int32"
      let toDateTimeString =
            V.map
              ( \(CKInt32 x) ->
                  formatUnixTimeGMT webDateFormat $
                    UnixTime (CTime $ fromIntegral x) 0
              )
              data32
      return $ V.map CKString toDateTimeString
    readDateTimeWithSpec n_rows (Just scl) tz_name = do
      data64 <- readIntColumn n_rows "Int64"
      let scale = 10 ^ fromIntegral scl
      let toDateTimeString =
            V.map
              ( \(CKInt64 x) ->
                  formatUnixTimeGMT webDateFormat $
                    UnixTime (CTime $ x `div` scale) 0
              )
              data64
      return $ V.map CKString toDateTimeString
------------------------------------------------------------------------------------------------
readLowCadinality :: Int -> ByteString -> Reader (Vector ClickhouseType)
readLowCadinality 0 _ = return (V.fromList [])
readLowCadinality n spec = do
  readBinaryUInt64 --state prefix
  let l = BS.length spec
  let inner = BS.take (l - 16) (BS.drop 15 spec)
  serialization_type <- readBinaryUInt64
  -- Lowest bytes contains info about key type.
  let key_type = serialization_type .&. 0xf
  index_size <- readBinaryUInt64
  -- Strip the 'Nullable' tag to avoid null map reading.
  index <- readColumn (fromIntegral index_size) (stripNullable inner)
  readBinaryUInt64 -- #keys
  keys <- case key_type of
    0 -> V.map fromIntegral <$> V.replicateM n readBinaryUInt8
    1 -> V.map fromIntegral <$> V.replicateM n readBinaryUInt16
    2 -> V.map fromIntegral <$> V.replicateM n readBinaryUInt32
    3 -> V.map fromIntegral <$> V.replicateM n readBinaryUInt64
  if "Nullable" `isPrefixOf` inner
    then do
      let nullable = fmap (\k -> if k == 0 then CKNull else index ! k) keys
      return nullable
    else return $ fmap (\k -> index ! k) keys
  where
    stripNullable :: ByteString -> ByteString
    stripNullable spec
      | "Nullable" `isPrefixOf` spec = BS.take (l - 10) (BS.drop 9 spec)
      | otherwise = spec
    l = BS.length spec

writeLowCardinality :: Context->ByteString->ByteString->Vector ClickhouseType->IOWriter Builder
writeLowCardinality ctx col_name spec items = do
  let inner = BS.take (BS.length spec - 16) (BS.drop 15 spec)
  (index, keys) <- if "Nullable" `isPrefixOf` inner
        then do
          let nullInner = BS.take (BS.length inner - 10) (BS.drop 9 spec)
          let hashedItem = hashItems True items
          let key_by_index_element = V.foldl' (\m x ->insertKeys m x) Map.empty hashedItem
          let keys = V.map (\k->key_by_index_element Map.! k + 1) hashedItem
          let index = V.fromList $  0 : (Map.keys $ key_by_index_element)
          return (keys, index)
        -- let index = 
        else do
          let hashedItem = hashItems False items
          let key_by_index_element = V.foldl' (\m x ->insertKeys m x) Map.empty hashedItem
          let keys = V.map (\k->key_by_index_element Map.! k) hashedItem
          let index = V.fromList $ Map.keys $ key_by_index_element
          return (keys, index)
  if V.length index == 0
    then return ()
    else do
      let int_type = 0 :: Int64
      let has_additional_keys_bit = 1 `shift` 9
      let need_update_dictionary = 1 `shift` 10
      let serialization_type = has_additional_keys_bit 
            .|. need_update_dictionary .|. int_type
      let nullsInner = 
            if "Nullable" `isPrefixOf` inner
              then BS.take (BS.length inner - 10) (BS.drop 9 spec)
              else inner
      writeBinaryUInt64 1 --state prefix
      writeBinaryInt64 serialization_type
      writeBinaryInt64 $ fromIntegral $ V.length index
      writeColumn ctx col_name nullsInner items
      writeBinaryInt64 $ fromIntegral $ V.length items
      case int_type of
        0 -> V.mapM_ (writeBinaryUInt8 . fromIntegral) keys
        1 -> V.mapM_ (writeBinaryUInt16 . fromIntegral) keys
        2 -> V.mapM_ (writeBinaryUInt32 . fromIntegral) keys
        3 -> V.mapM_ (writeBinaryUInt64 . fromIntegral) keys
  where
    insertKeys ::(Hashable a, Eq a)=> Map.HashMap a Int->a->Map.HashMap a Int
    insertKeys m a = if Map.member a m then m else Map.insert a (Map.size m) m

    hashItems :: Bool->Vector ClickhouseType->Vector Int
    hashItems isNullable items = V.map (
                 \case CKInt16 x-> hash x
                       CKInt8 x -> hash x
                       CKInt32 x -> hash x
                       CKInt64 x -> hash x
                       CKUInt8 x -> hash x
                       CKUInt16 x -> hash x
                       CKUInt32 x -> hash x
                       CKUInt64 x -> hash x
                       CKString str -> hash str
                       CKNull -> if isNullable
                         then hash (0 :: Int) 
                         else error $ typeMismatchError col_name 
                       _ -> error $ typeMismatchError col_name
                 ) items
---------------------------------------------------------------------------------------------------------------------------------
{-
          Informal description for this config:
          (\Null | \SOH)^{n_rows}
-}
readNullable :: Int->ByteString->Reader (Vector ClickhouseType)
readNullable n_rows spec = do
  let l = BS.length spec
  let cktype = BS.take (l - 10) (BS.drop 9 spec) -- Read Clickhouse type inside the bracket after the 'Nullable' spec.
  config <- readNullableConfig n_rows spec
  items <- readColumn n_rows cktype
  let result = V.generate n_rows (\i->if config ! i == 1 then CKNull else items ! i)
  return result
    where
      readNullableConfig :: Int->ByteString->Reader (Vector Word8)
      readNullableConfig n_rows spec = do
        config <- readBinaryStrWithLength n_rows
        (return . V.fromList . BS.unpack) config

writeNullsMap :: Vector ClickhouseType -> IOWriter Builder
writeNullsMap = V.mapM_ 
  (\case CKNull-> writeBinaryInt8 1
         _ -> writeBinaryInt8 0)
---------------------------------------------------------------------------------------------------------------------------------
{-
  Format:
  "
     One element of array of arrays can be represented as tree:
      (0 depth)          [[3, 4], [5, 6]]
                        |               |
      (1 depth)      [3, 4]           [5, 6]
                    |    |           |    |
      (leaf)        3     4          5     6
      Offsets (sizes) written in breadth-first search order. In example above
      following sequence of offset will be written: 4 -> 2 -> 4
      1) size of whole array: 4
      2) size of array 1 in depth=1: 2
      3) size of array 2 plus size of all array before in depth=1: 2 + 2 = 4
      After sizes info comes flatten data: 3 -> 4 -> 5 -> 6
  "
      Quoted from https://github.com/mymarilyn/clickhouse-driver/blob/master/clickhouse_driver/columns/arraycolumn.py
-}

readArray :: Int -> ByteString -> Reader (Vector ClickhouseType)
readArray n_rows spec = do
  (lastSpec, x : xs) <- genSpecs spec [V.fromList [fromIntegral n_rows]]
  let numElem = fromIntegral $ V.sum x
  elems <- readColumn numElem lastSpec
  let result' = foldl combine elems (x : xs)
  let result = case (result' ! 0) of
        CKArray arr -> arr
        _ -> error "wrong type. This cannot happen"
  return result
  where
    combine :: Vector ClickhouseType -> Vector Word64 -> Vector ClickhouseType
    combine elems config =
      let intervals = intervalize (fromIntegral <$> config)
          cut (a, b) = CKArray $ V.take b (V.drop a elems)
          embed = (\(l, r) -> cut (l, r - l + 1)) <$> intervals
       in embed
    intervalize :: Vector Int -> Vector (Int, Int)
    intervalize vec = V.drop 1 $ V.scanl' (\(a, b) v -> (b + 1, v + b)) (-1, -1) vec

readArraySpec :: Vector Word64 -> Reader (Vector Word64)
readArraySpec sizeArr = do
  let arrSum = (fromIntegral . V.sum) sizeArr
  offsets <- V.replicateM arrSum readBinaryUInt64
  let offsets' = V.cons 0 (V.take (arrSum - 1) offsets)
  let sizes = V.zipWith (-) offsets offsets'
  return sizes

genSpecs :: ByteString -> [Vector Word64] -> Reader (ByteString, [Vector Word64])
genSpecs spec rest@(x : xs) = do
  let l = BS.length spec
  let cktype = BS.take (l - 7) (BS.drop 6 spec)
  if "Array" `isPrefixOf` spec
    then do
      next <- readArraySpec x
      genSpecs cktype (next : rest)
    else return (spec, rest)

writeArray :: Context->ByteString -> ByteString -> Vector ClickhouseType -> IOWriter Builder
writeArray ctx col_name spec items = do
  let lens =
        V.scanl'
          ( \total ->
              ( \case
                  (CKArray xs) -> total + V.length xs
                  x ->
                    error $
                      "unexpected type in the column: "
                        ++ show col_name
                        ++ " with data"
                        ++ show x
              )
          )
          0
          items
  V.mapM_ (writeBinaryInt64 . fromIntegral) (V.drop 1 lens)
  let innerSpec = BS.take (BS.length spec - 7) (BS.drop 6 spec)
  let innerVector = V.map (\case CKArray xs -> xs) items
  let flattenVector = 
        innerVector >>= \v -> do w <- v; return w
  writeColumn ctx col_name innerSpec flattenVector
--------------------------------------------------------------------------------------
readTuple :: Int->ByteString->Reader (Vector ClickhouseType)
readTuple n_rows spec = do
  let l = BS.length spec
  let innerSpecString = BS.take(l - 7) (BS.drop 6 spec)
  let arr = V.fromList (getSpecs innerSpecString) 
  datas <- V.mapM (readColumn n_rows) arr
  let transposed = transpose datas
  return $ CKTuple <$> transposed

writeTuple :: Context -> ByteString -> ByteString -> Vector ClickhouseType -> IOWriter Builder
writeTuple ctx col_name spec items = do
  let inner = BS.take (BS.length spec - 7) (BS.drop 6 spec)
  let specarr = V.fromList $ getSpecs inner
  let transposed =
        transpose
          ( V.map
              ( \case
                  CKTuple tupleVec -> tupleVec
                  other ->
                    error
                      ( "expected type: " ++ show other
                          ++ "in the column:"
                          ++ show col_name
                      )
              )
              items
          )
  if V.length specarr /= V.length transposed
    then
      error $
        "length of the given array does not match, column name = "
          ++ show col_name
    else do
      V.zipWithM_ (writeColumn ctx col_name) specarr transposed
--------------------------------------------------------------------------------------
readEnum :: Int -> ByteString -> Reader (Vector ClickhouseType)
readEnum n_rows spec = do
  let l = BS.length spec
      innerSpec =
        if "Enum8" `isPrefixOf` spec
          then BS.take (l - 7) (BS.drop 6 spec)
          else BS.take (l - 8) (BS.drop 7 spec)
      prespecs = getSpecs innerSpec
      specs = (\(name, Just (n, _)) -> (n, name)) <$> 
        ((\[x, y]->(x, readInt y)) . BS.splitWith (== 61) <$> prespecs) --61 is '='
      specsMap = Map.fromList specs
  if "Enum8" `isPrefixOf` spec
    then do
      vals <- V.replicateM n_rows readBinaryInt8
      return $ (CKString . (specsMap Map.!) . fromIntegral) <$> vals
    else do
      vals <- V.replicateM n_rows readBinaryInt16
      return $ (CKString . (specsMap Map.!) . fromIntegral) <$> vals

writeEnum :: ByteString -> ByteString -> Vector ClickhouseType -> IOWriter Builder
writeEnum col_name spec items = do
  let l = BS.length spec
      innerSpec =
        if "Enum8" `isPrefixOf` spec
          then BS.take (l - 7) (BS.drop 6 spec)
          else BS.take (l - 8) (BS.drop 7 spec)
      prespecs = getSpecs innerSpec
      specs =
        (\(name, Just (n, _)) -> (name, n))
          <$> ((\[x, y] -> (x, readInt y)) . BS.splitWith (== 61) . BS.filter (/=39) <$> prespecs) --61 is '='
      specsMap = Map.fromList specs
  V.mapM_
    ( \case
        CKString str ->
          ( if "Enum8" `isPrefixOf` spec
              then writeBinaryInt8 $ fromIntegral $ specsMap Map.! str
              else writeBinaryInt16 $ fromIntegral $ specsMap Map.! str
          )
        CKNull ->
          if "Enum8" `isPrefixOf` spec
            then writeBinaryInt8 0
            else writeBinaryInt16 0
    )
    items
----------------------------------------------------------------------
readDate :: Int->Reader(Vector ClickhouseType)
readDate n_rows = do
  let epoch_start = fromGregorian 1970 1 1
  days <- V.replicateM n_rows readBinaryUInt16
  let dates = fmap (\x->addDays (fromIntegral x) epoch_start) days
      toTriple = fmap toGregorian dates
      toCK = fmap (\(y, m, d)->CKDate y m d) toTriple
  return toCK

writeDate :: ByteString -> Vector ClickhouseType -> IOWriter Builder
writeDate col_name items = do
  let epoch_start = fromGregorian 1970 1 1
  let serialize =
        V.map
          ( \case
              CKDate y m d -> diffDays (fromGregorian y m d) epoch_start
              _ ->
                error $
                  "unexpected type in the column: " ++ show col_name
                    ++ " whose type should be Date"
          )
          items
  V.mapM_ (writeBinaryInt16 . fromIntegral) serialize
--------------------------------------------------------------------------------------
readDecimal :: Int->ByteString->Reader(Vector ClickhouseType)
readDecimal n_rows spec = do
  let l = BS.length spec 
  let [precision', scale'] = getSpecs $ BS.take(l - 9) (BS.drop 8 spec)
  let (Just (precision,_), Just (scale,_)) = (readInt precision', readInt scale')
  let specific = 
        if precision <= 9
          then readDecimal32
          else if precision <= 18
            then readDecimal64
            else readDecimal128
  
  raw <- specific n_rows
  let final = fmap (trans scale) raw
  return final
  where
    readDecimal32 n_rows = readIntColumn n_rows "Int32"
    readDecimal64 n_rows = readIntColumn n_rows "Int64"
    readDecimal128 n_rows = undefined
    trans :: Int->ClickhouseType->ClickhouseType
    trans scale (CKInt32 x) = CKDecimal32 (fromIntegral x / fromIntegral scale)
    trans scale (CKInt64 x) = CKDecimal64 (fromIntegral x / fromIntegral scale)
----------------------------------------------------------------------------------------------
readIPv4 :: Int->Reader (Vector ClickhouseType)
readIPv4 n_rows = V.replicateM n_rows (CKIPv4 . IP4 <$> readBinaryUInt32)

readIPv6 :: Int->Reader (Vector ClickhouseType)
readIPv6 n_rows = V.replicateM n_rows (CKIPv6 . IP6  <$> readBinaryUInt128)

writeIPv4 :: ByteString->Vector ClickhouseType->IOWriter Builder
writeIPv4 col_name items = V.mapM_ (
          \case CKIPv4 ip4 -> writeBinaryUInt32 $ unIP4 ip4
                CKNull -> writeBinaryInt32 0
                x -> error $ typeMismatchError col_name
          ) items

writeIPv6 :: ByteString->Vector ClickhouseType->IOWriter Builder
writeIPv6 col_name items = V.mapM_ (
          \case CKIPv6 ip6 -> writeBinaryUInt128 $ unIP6 ip6
                CKNull -> writeBinaryUInt64 0
                x -> error $ typeMismatchError col_name
          ) items
----------------------------------------------------------------------------------------------
readSimpleAggregateFunction :: Int->ByteString->Reader (Vector ClickhouseType)
readSimpleAggregateFunction n_rows spec = do
   let l = BS.length spec
   let [func, cktype] = getSpecs $ BS.take(l - 25) (BS.drop 24 spec)
   readColumn n_rows cktype
----------------------------------------------------------------------------------------------
readUUID :: Int->Reader (Vector ClickhouseType)
readUUID n_rows = do
  V.replicateM n_rows $ do
    w2 <- readBinaryUInt32
    w1 <- readBinaryUInt32
    w3 <- readBinaryUInt32
    w4 <- readBinaryUInt32
    return $ CKString  $ C8.pack $
     UUID.toString $ UUID.fromWords w1 w2 w3 w4

writeUUID :: ByteString -> Vector ClickhouseType -> IOWriter Builder
writeUUID col_name items =
  V.mapM_
    ( \case CKString uuidstr -> do
              case UUID.fromString $ C8.unpack uuidstr of
                Nothing -> error $ "UUID parsing error in the column" 
                          ++ show col_name
                Just uuid -> do
                  let (w2, w1, w3, w4) = UUID.toWords uuid
                  writeBinaryUInt32 w1
                  writeBinaryUInt32 w2
                  writeBinaryUInt32 w3
                  writeBinaryUInt32 w4
            CKNull -> do
              writeBinaryUInt64 0
              writeBinaryUInt64 0
    )
    items
----------------------------------------------------------------------------------------------
---Helpers 

-- | Get rid of commas and spaces
getSpecs :: ByteString -> [ByteString]
getSpecs str = BS.splitWith (==44) (BS.filter ( /= 32) str) 

transpose :: Vector (Vector ClickhouseType) -> Vector (Vector ClickhouseType)
transpose cdata =
  rotate cdata
  where
    rotate matrix =
      let transposedList = List.transpose (V.toList <$> V.toList matrix)
          toVector = V.fromList <$> (V.fromList transposedList)
       in toVector

typeMismatchError :: ByteString->String
typeMismatchError col_name = "Type mismatch in the column " ++ (show col_name)

-- | print in putStrLn
putStrLn :: Vector (Vector ClickhouseType) -> IO ()
putStrLn v = C8.putStrLn $ BS.intercalate "\n" $ V.toList $ V.map tostr v
  where
    tostr :: Vector ClickhouseType -> ByteString
    tostr row = BS.intercalate "," $ V.toList $ V.map help row

    help :: ClickhouseType->ByteString
    help (CKString s) = s
    help (CKInt8 n) = C8.pack $ show n
    help (CKInt16 n) = C8.pack $ show n
    help (CKInt32 n) = C8.pack $ show n
    help (CKInt64 n) = C8.pack $ show n
    help (CKUInt8 n) = C8.pack $ show n
    help (CKUInt16 n) = C8.pack $ show n
    help (CKUInt32 n) = C8.pack $ show n
    help (CKUInt64 n) = C8.pack $ show n
    help (CKTuple xs) = "(" <> tostr xs <> ")"
    help (CKArray xs) = "[" <> tostr xs <> "]"
    help (CKNull) = "null"
    help (CKIPv4 ip4) = C8.pack $ show ip4
    help (CKIPv6 ip6) = C8.pack $ show ip6
    help (CKDate y m d) = (C8.pack $ show y) 
                        <> "-" <> (C8.pack $ show m) 
                        <> "-" <> (C8.pack $ show d)