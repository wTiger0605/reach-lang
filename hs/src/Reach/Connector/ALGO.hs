{-# LANGUAGE CPP #-}

module Reach.Connector.ALGO (connect_algo, AlgoError (..)) where

import Control.Monad.Extra
import Control.Monad.Reader
import Control.Monad.Trans.Except
import Crypto.Hash
import Data.Aeson ((.:), (.=), (.:?))
import qualified Data.Aeson as AS
import Data.Bits (shiftL, shiftR, (.|.))
import qualified Data.ByteArray as BA
import qualified Data.ByteString as BS
import Data.ByteString.Base64 (encodeBase64', decodeBase64)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Internal as BI
import Data.Char
import qualified Data.DList as DL
import Data.Function
import Data.IORef
import Data.List (intercalate, foldl')
import qualified Data.List as List
import Data.List.Extra (enumerate, mconcatMap)
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.IO as LTIO
import qualified Data.Vector as Vector
import Data.Word
import Generics.Deriving (Generic)
import Reach.AST.Base
import Reach.AST.DLBase
import Reach.AST.CL
import Reach.Connector
import Reach.Counter
import Reach.Dotty
import Reach.FixedPoint
import Reach.OutputUtil
import qualified Reach.Texty as T
import Reach.Texty (pretty)
import Reach.UnsafeUtil
import Reach.Util
import Reach.Warning
import Safe (atMay)
import Safe.Foldable (maximumMay)
import System.Exit
import System.FilePath
import System.Process.ByteString
import Text.Read
import qualified Reach.Connector.ALGO_Verify as Verify

-- Errors for ALGO

data AlgoError
  = Err_TransferNewToken
  | Err_PayNewToken
  deriving (Eq, ErrorMessageForJson, ErrorSuggestions, Generic)

instance HasErrorCode AlgoError where
  errPrefix = const "RA"
  errIndex = \case
    Err_TransferNewToken {} -> 0
    Err_PayNewToken {} -> 1

instance Show AlgoError where
  show = \case
    Err_TransferNewToken ->
      "Token cannot be transferred within the same consensus step it was created in on Algorand"
    Err_PayNewToken ->
      "Token cannot be paid within the same consensus step it was shared with the contract on Algorand"

type NotifyFm m = LT.Text -> m ()
type NotifyF = LT.Text -> IO ()
type Notify = Bool -> NotifyF

-- General tools that could be elsewhere

count :: (a -> Bool) -> [a] -> Int
count f l = length $ filter f l

type LPGraph1 a b = M.Map a b
type LPEdge a b = ([a], b)
type LPChildren a b = LPGraph1 a (S.Set (LPEdge a b))
type LPGraph a b = M.Map a (LPChildren a b)

longestPathBetween :: forall b . LPGraph String b -> String -> String -> (b -> Integer) -> IO Integer
longestPathBetween g f d getc = do
  a2d <- fixedPoint $ \_ (i :: LPGraph1 String Integer) -> do
    flip mapM g $ \(tom :: (LPChildren String b)) -> do
      let ext :: String -> LPEdge String b -> Integer
          ext to (cs, r) = getc r + chase to + sum (map chase cs)
          chase :: String -> Integer
          chase to =
            case to == d of
              True -> 0
              False ->
                case M.lookup to i of
                  Nothing -> 0
                  Just c' -> c'
      let ext' :: String -> S.Set (LPEdge String b) -> Integer
          ext' to es = foldl' max 0 $ map (ext to) $ S.toAscList es
      let tom' :: [Integer]
          tom' = map (uncurry ext') $ M.toAscList tom
      return $ foldl' max 0 tom'
  let r2d x = fromMaybe 0 $ M.lookup x a2d
  let pc = r2d f
  let getMaxPath' x =
        case x == d of
          True -> []
          False -> getMaxPath $ List.maximumBy (compare `on` r2d) $ M.keys $ fromMaybe mempty $ M.lookup x g
      getMaxPath x = x : getMaxPath' x
  let _p = getMaxPath f
  return $ pc

budgetAnalyze :: LPGraph String ResourceCost -> String -> String -> (ResourceCost -> Resource -> Integer) -> IO (Bool, Integer, Integer)
budgetAnalyze g s e getc = do
  let from c b l = do
        case l == e of
          True -> return $ (False, c, b)
          False -> froms l c b $ M.toAscList $ fromMaybe mempty $ M.lookup l g
      froms l c b = \case
        [] -> impossible $ "ba null: " <> show l
        [x] -> from1 c b x
        x : xs -> cbas (from1 c b x) (froms l c b xs)
      cbas m1 m2 = do
          m1 >>= \case
            r@(True, _, _) -> return r
            r1@(False, c1, b1) ->
              m2 >>= \case
                r@(True, _, _) -> return r
                r2@(False, c2, b2) -> do
                  case b1 > b2 of
                    True -> return r1
                    False ->
                      case c1 > c2 of
                        True -> return r1
                        False -> return r2
      from1 c b (l, es) = from1l c b l $ S.toAscList es
      from1l c b l = \case
        [] -> impossible "ba lnull"
        [x] -> from1e c b l x
        x : xs -> cbas (from1e c b l x) (from1l c b l xs)
      from1e c b l (cs, r) = do
        let gr = getc r
        let c' = c + gr R_Cost
        let b' = b + gr R_Budget
        case c' > b' of
          True -> return (True, c', b')
          False -> fromcs c' b' l cs
      fromcs c b k = \case
        [] -> from c b k
        x : xs ->
          from c b x >>= \case
            r@(True, _, _) -> return r
            (False, c', b') ->
              fromcs c' b' k xs
  from 0 0 s

restrictGraph :: forall a b . (Ord a, Ord b) => LPGraph a b -> a -> IO (LPGraph a b)
restrictGraph g n = do
  -- putStrLn $ "restrict " <> show n
  (from, to) <- fixedPoint $ \_ ((from :: S.Set a), (to_ :: S.Set a)) -> do
    let to = S.insert n to_
    -- putStrLn $ "  FROM " <> show from
    -- putStrLn $ "    TO " <> show to
    -- putStrLn $ ""
    let incl1 x cs = x == n || S.member x cs
    let esls :: LPEdge a b -> S.Set a
        esls = S.fromList . fst
    let csls :: LPChildren a b -> S.Set a
        csls cs = M.keysSet cs <> mconcatMap esls (S.toAscList $ mconcat $ M.elems cs)
    let inclFrom (x, cs) =
          case incl1 x from of
            True -> S.insert x $ csls cs
            False -> mempty
    let inclTo (x, cs) =
          case S.null $ S.intersection (csls cs) to of
            False -> S.singleton x
            True -> mempty
    let from' = mconcatMap inclFrom $ M.toAscList g
    let to' = mconcatMap inclTo $ M.toAscList g
    return (from', to')
  let cs = S.union from to
  let isConnected = flip S.member cs
  let onlyConnected x _ = isConnected x
  let removeDisconnected = M.filterWithKey onlyConnected
  return $ M.map removeDisconnected $ removeDisconnected g

ensureAllPaths :: (Show a, Ord a) => String -> LPGraph a b -> a -> a -> (b -> Integer) -> IO (Maybe [a])
ensureAllPaths rlab g s e getc = checkFrom 0 mempty s
  where
    checkFrom t p l = do
      loud $ rlab <> " " <> show l
      when (elem l p) $ do
        impossible "loop"
      case l == e of
        True ->
          case t == 1 of
            True -> return $ Nothing
            False -> return $ Just p
        False ->
          checkChildren t (l : p) $ M.toAscList $ fromMaybe mempty $ M.lookup l g
    checkChildren t p = \case
      [] -> return $ Nothing
      (d, x) : xs -> checkEdges t p d (S.toAscList x) `cmb` checkChildren t p xs
    checkEdges t p d = \case
      [] -> return $ Nothing
      x : xs -> checkEdge t p d x `cmb` checkEdges t p d xs
    checkEdge t p d (_cs, r) =
      checkFrom (t + getc r) p d
    cmb mx my = do
      mx >>= \case
        Just x -> return $ Just x
        Nothing -> my

aarray :: [AS.Value] -> AS.Value
aarray = AS.Array . Vector.fromList

aobject :: M.Map T.Text AS.Value -> AS.Value
aobject = aesonObject . M.toAscList

mergeIORef :: IORef a -> (a -> a -> a) -> IORef a -> IO ()
mergeIORef dst f src = do
  srca <- readIORef src
  modifyIORef dst $ f srca

type ErrorSet = S.Set LT.Text
type ErrorSetRef = IORef ErrorSet
bad_io :: ErrorSetRef -> NotifyF
bad_io x = modifyIORef x . S.insert
newErrorSetRef :: IO (ErrorSetRef, NotifyF)
newErrorSetRef = do
  r <- newIORef mempty
  return (r, bad_io r)

-- Algorand constants

conName' :: T.Text
conName' = "ALGO"

conCons' :: DLConstant -> DLLiteral
conCons' = \case
  DLC_UInt_max  -> DLL_Int sb UI_Word $ 2 ^ (64 :: Integer) - 1
  DLC_Token_zero -> DLL_Int sb UI_Word $ 0

appLocalStateNumUInt :: Integer
appLocalStateNumUInt = 0

appLocalStateNumBytes :: Integer
appLocalStateNumBytes = 0

appGlobalStateNumUInt :: Integer
appGlobalStateNumUInt = 0

appGlobalStateNumBytes :: Integer
appGlobalStateNumBytes = 1

algoMaxStringSize :: Integer
algoMaxStringSize = 4096

algoMaxLocalSchemaEntries :: Integer
algoMaxLocalSchemaEntries = 16

algoMaxLocalSchemaEntries_usable :: Integer
algoMaxLocalSchemaEntries_usable = algoMaxLocalSchemaEntries - appLocalStateNumBytes

algoMaxGlobalSchemaEntries :: Integer
algoMaxGlobalSchemaEntries = 64

algoMaxGlobalSchemaEntries_usable :: Integer
algoMaxGlobalSchemaEntries_usable = algoMaxGlobalSchemaEntries - appGlobalStateNumBytes

algoMaxAppBytesValueLen :: Integer
algoMaxAppBytesValueLen = 128

algoMaxAppBytesValueLen_usable :: Integer
algoMaxAppBytesValueLen_usable =
  -- We guarantee that every key is exactly one byte, so all the rest of the
  -- space goes to the value
  algoMaxAppBytesValueLen - 1

algoMaxAppTotalArgLen :: Integer
algoMaxAppTotalArgLen = 2048

algoMinimumBalance :: Integer
algoMinimumBalance = 100000

algoMaxTxGroupSize :: Integer
algoMaxTxGroupSize = 16

-- not actually the limit, but this is the name of the variable in the
-- consensus configuration
algoMaxInnerTransactions :: Integer
algoMaxInnerTransactions = 16

algoMaxAppTxnAccounts :: Integer
algoMaxAppTxnAccounts = 4

algoMaxAppTxnForeignAssets :: Integer
algoMaxAppTxnForeignAssets = 8
algoMaxAppTxnForeignApps :: Integer
algoMaxAppTxnForeignApps = 8
algoMaxAppTotalTxnReferences :: Integer
algoMaxAppTotalTxnReferences = 8

algoMaxAppProgramCost :: Integer
algoMaxAppProgramCost = 700

-- We're making up this name. It is not in consensus.go, but only in the docs
algoMaxLogLen :: Integer
algoMaxLogLen = 1024

algoMaxLogCalls :: Integer
algoMaxLogCalls = 32

algoMaxAppProgramLen :: Integer
algoMaxAppProgramLen = 2048

algoMaxExtraAppProgramPages :: Integer
algoMaxExtraAppProgramPages = 3

algoMaxAppProgramLen_really :: Integer
algoMaxAppProgramLen_really = (1 + algoMaxExtraAppProgramPages) * algoMaxAppProgramLen

minimumBalance_l :: DLLiteral
minimumBalance_l = DLL_Int sb UI_Word algoMinimumBalance

tealVersionPragma :: LT.Text
tealVersionPragma = "#pragma version 8"

-- Algo specific stuff

extraPages :: Integral a => a -> Integer
extraPages totalLen = ceiling ((fromIntegral totalLen :: Double) / fromIntegral algoMaxAppProgramLen) - 1

data AppInfo = AppInfo
  { ai_GlobalNumUint :: Integer
  , ai_GlobalNumByteSlice :: Integer
  , ai_LocalNumUint :: Integer
  , ai_LocalNumByteSlice :: Integer
  , ai_ExtraProgramPages :: Integer
  }

data ApplTxnType
  = ApplTxn_Create
  | ApplTxn_OptIn

minimumBalance_app :: AppInfo -> ApplTxnType -> Integer
minimumBalance_app (AppInfo {..}) = \case
  ApplTxn_Create ->
    100000*(1+ai_ExtraProgramPages) + (25000+3500)*ai_GlobalNumUint + (25000+25000)*ai_GlobalNumByteSlice
  ApplTxn_OptIn ->
    100000 + (25000+3500)*ai_LocalNumUint + (25000+25000)*ai_LocalNumByteSlice

maxTypeSize_ :: M.Map a DLType -> Maybe Integer
maxTypeSize_ m = do
  ts <- mapM typeSizeOf_ $ M.elems m
  return $ fromMaybe 0 $ maximumMay ts

typeSig_ :: Bool -> Bool -> DLType -> App String
typeSig_ addr2acc isRet = \case
  -- XXX hack until algosdk is fixed
  T_Null -> r $ if isRet then "void" else "byte[0]"
  T_Bool -> r "byte" -- "bool"
  T_UInt UI_Word -> r "uint64"
  T_UInt UI_256 -> r "uint256"
  T_Bytes sz -> r $ "byte" <> array sz
  T_BytesDyn -> r "bytes"
  T_StringDyn -> r "string"
  T_Digest -> r "digest"
  T_Address -> r $ if addr2acc then "account" else "address"
  T_Contract -> typeSig $ T_UInt UI_Word
  T_Token -> typeSig $ T_UInt UI_Word
  T_Array t sz -> do
    s <- typeSig t
    r $ s <> array sz
  T_Tuple ts -> do
    s <- mapM typeSig ts
    r $ "(" <> intercalate "," s <> ")"
  T_Object m -> typeSig $ T_Tuple $ M.elems m
  T_Data m -> do
    m' <- maxTypeSize m
    r $ "(byte,byte" <> array m' <> ")"
  T_Struct ts -> typeSig $ T_Tuple $ map snd ts
  where
    r = return
    -- The ABI allows us to do this, but we don't know how to do in the remote
    -- call generator
    -- rec = typeSig_ addr2acc False
    array sz = "[" <> show sz <> "]"

typeSig :: DLType -> App String
typeSig = typeSig_ False False

typeSizeOf_ :: DLType -> Maybe Integer
typeSizeOf_ = \case
  T_Null -> r 0
  T_Bool -> r 1
  T_UInt UI_Word -> r word
  T_UInt UI_256 -> r 32
  T_Bytes sz -> r sz
  T_BytesDyn -> Nothing
  T_StringDyn -> Nothing
  T_Digest -> r 32
  T_Address -> r 32
  T_Contract -> typeSizeOf_ $ T_UInt UI_Word
  T_Token -> typeSizeOf_ $ T_UInt UI_Word
  T_Array t sz -> (*) sz <$> typeSizeOf_ t
  T_Tuple ts -> sum <$> mapM typeSizeOf_ ts
  T_Object m -> sum <$> (mapM typeSizeOf_ $ M.elems m)
  T_Data m -> (+) 1 <$> maxTypeSize_ m
  T_Struct ts -> sum <$> mapM (typeSizeOf_ . snd) ts
  where
    r = return
    word = 8

maybeOrDynType :: Monad m => NotifyFm m -> a -> Maybe a -> m a
maybeOrDynType notify d mx =
  case mx of
    Just x -> return x
    Nothing -> do
      notify $ "Uses a dynamically sized type, like BytesDyn or StringDyn."
      return d

typeSizeOf__ :: Monad m => NotifyFm m -> DLType -> m Integer
typeSizeOf__ notify t = maybeOrDynType notify 32 (typeSizeOf_ t)

typeSizeOf :: DLType -> App Integer
typeSizeOf = typeSizeOf__ bad_nc

maxTypeSize :: M.Map a DLType -> App Integer
maxTypeSize m = maybeOrDynType bad_nc 0 (maxTypeSize_ m)

encodeBase64 :: B.ByteString -> LT.Text
encodeBase64 bs = LT.pack $ B.unpack $ encodeBase64' bs

texty :: Show a => a -> LT.Text
texty x = LT.pack $ show x

textyt :: Show a => a -> DLType -> LT.Text
textyt x ty = texty x <> " :: " <> texty ty

textyv :: DLVar -> LT.Text
textyv v = textyt v (varType v)

type ScratchSlot = Word8

type TealOp = LT.Text

type TealArg = LT.Text

type Label = LT.Text

data IndentDir
  = INo
  | IUp
  | IDo

data TEAL
  = TCode TealOp [TealArg]
  | Titob Bool
  | TInt Integer
  | TConst LT.Text
  | TBytes B.ByteString
  | TExtract Word8 Word8
  | TReplace2 Word8
  | TSubstring Word8 Word8
  | TComment IndentDir LT.Text
  | TLabel Label
  | TFor_top Integer
  | TFor_bnz Label Integer Label
  | TLog Integer
  | TStore ScratchSlot LT.Text
  | TLoad ScratchSlot LT.Text
  | TResource Resource
  | TCostCredit Integer
  | TCheckOnCompletion

type TEALt = [LT.Text]

type TEALs = DL.DList TEAL

builtin :: S.Set TealOp
builtin = S.fromList ["byte", "int", "substring", "extract", "log", "store", "load", "itob"]

base64d :: BS.ByteString -> LT.Text
base64d bs = "base64(" <> encodeBase64 bs <> ")"

render :: IORef Int -> TEAL -> IO TEALt
render ilvlr = \case
  TInt x -> r ["int", texty x]
  TConst x -> r ["int", x]
  TBytes bs -> r ["byte", base64d bs]
  TExtract x y -> r ["extract", texty x, texty y]
  TReplace2 x -> r ["replace2", texty x]
  TSubstring x y -> r ["substring", texty x, texty y]
  Titob _ -> r ["itob"]
  TCode f args ->
    case S.member f builtin of
      True -> impossible $ show $ "cannot use " <> f <> " directly"
      False -> r $ f : args
  TComment il t -> do
    case il of
      INo -> return ()
      IUp -> modifyIORef ilvlr $ \x -> x + 1
      IDo -> modifyIORef ilvlr $ \x -> x - 1
    case t of
      "" -> return []
      _ -> r ["//", t]
  TLabel lab -> r [lab <> ":"]
  TFor_top maxi ->
    r [("// for runs " <> texty maxi <> " times")]
  TFor_bnz top_lab maxi _ ->
    r ["bnz", top_lab, ("// for runs " <> texty maxi <> " times")]
  TLog sz ->
    r ["log", ("// up to " <> texty sz <> " bytes")]
  TStore sl lab -> r ["store", texty sl, ("// " <> lab)]
  TLoad sl lab -> r ["load", texty sl, ("// " <> lab)]
  TResource rs -> r [("// resource: " <> texty rs)]
  TCostCredit i -> r [("// cost credit: " <> texty i)]
  TCheckOnCompletion -> r [("// checked on completion")]
  where
    r l = do
      i <- readIORef ilvlr
      let i' = replicate i " "
      return $ i' <> l

renderOut :: [TEAL] -> IO T.Text
renderOut tscl' = do
  ilvlr <- newIORef $ 0
  tsl' <- mapM (render ilvlr) tscl'
  let lts = tealVersionPragma : (map LT.unwords tsl')
  let lt = LT.unlines lts
  let t = LT.toStrict lt
  return t

optimize :: [TEAL] -> [TEAL]
optimize ts0 = tsN
  where
    ts1 = opt_b ts0
    ts2 = opt_bs ts1
    tsN = ts2

opt_bs :: [TEAL] -> [TEAL]
opt_bs = \case
  [] -> []
  x@(TBytes bs) : l | B.all (== '\0') bs ->
    case B.length bs of
      len | len < 3 -> x : opt_bs l
      32 -> opt_bs $ (TCode "global" ["ZeroAddress"]) : l
      -- Space is more important than cost?
      len ->
        let spaceMoreThanCost = True in
        case spaceMoreThanCost of
          True -> opt_bs $ (TInt $ fromIntegral len) : (TCode "bzero" []) : l
          False -> x : opt_bs l
  x : l -> x : opt_bs l

opt_b :: [TEAL] -> [TEAL]
opt_b = foldr (\a b -> opt_b1 $ a : b) mempty

data TType
  = TT_UInt
  | TT_Bytes
  | TT_Unknown

opType :: TEAL -> Maybe ([TType], [TType])
opType = \case
  Titob {} -> u2b
  TInt {} -> _2u
  TConst {} -> _2u
  TBytes {} -> _2b
  TExtract {} -> b2b
  TReplace2 {} -> b2b
  TSubstring {} -> b2b
  TComment {} -> Nothing
  TLabel {} -> Nothing
  TFor_top {} -> Nothing
  TFor_bnz {} -> Nothing
  TLog {} -> eff
  TStore {} -> eff
  TLoad {} -> j [] [k]
  TResource {} -> eff
  TCostCredit {} -> eff
  TCheckOnCompletion -> Nothing
  TCode o _ ->
    -- XXX Fill in this table
    case o of
      "err" -> eff
      "sha256" -> b2b
      "keccak256" -> b2b
      -- ....
      "global" -> j [] [k]
      -- ....
      _ -> Nothing
  where
    _2b = j [] [b]
    _2u = j [] [u]
    u2b = j [u] [b]
    b2b = j [b] [b]
    eff = Nothing
    k = TT_Unknown
    u = TT_UInt
    b = TT_Bytes
    j x y = Just (x, y)

opArity :: TEAL -> Maybe (Int, Int)
opArity = fmap f . opType
  where
    f (x, y) = (length x, length y)

opt_b1 :: [TEAL] -> [TEAL]
opt_b1 = \case
  [] -> []
  [(TCode "return" [])] -> []
  -- This relies on knowing what "done" is
  (TCode "assert" []) : (TCode "b" ["done"]) : x -> (TCode "return" []) : x
  x@(TBytes _) : y@(TBytes _) : (TCode "swap" []) : l ->
    opt_b1 $ y : x : l
  (TBytes "") : (TCode "concat" []) : l -> l
  (TBytes "") : b@(TLoad {}) : (TCode "concat" []) : l -> opt_b1 $ b : l
  (TBytes x) : (TBytes y) : (TCode "concat" []) : l ->
    opt_b1 $ (TBytes $ x <> y) : l
  -- XXX generalize this optimization and make it so we don't do it to things
  -- with effects
  -- If x doesn't consume anything and we pop it, just pop it
  x : (TCode "pop" []) : l | opArity x == Just (0, 1) -> l
  -- If x consumes something and we pop it, then pop the argument too
  x : y@(TCode "pop" []) : l | opArity x == Just (1, 1) -> y : l
  -- If x consumes 2 things and we pop it, then pop the arguments too
  x : y@(TCode "pop" []) : l | opArity x == Just (2, 1) -> y : y : l
  (TCode "b" [x]) : b@(TLabel y) : l | x == y -> b : l
  (TCode "btoi" []) : (Titob True) : (TSubstring 7 8) : l -> l
  (TCode "btoi" []) : (Titob _) : l -> l
  (TInt 0) : (TCode "-" []) : l -> l
  (TInt 0) : (TCode "+" []) : l -> l
  (Titob _) : (TCode "btoi" []) : l -> l
  (TCode "==" []) : (TCode "!" []) : l -> (TCode "!=" []) : l
  (TCode "b==" []) : (TCode "!" []) : l -> (TCode "b!=" []) : l
  (TInt 0) : (TCode "!=" []) : (TCode "assert" []) : l ->
    (TCode "assert" []) : l
  (TCode "*" []) : (TInt x) : (TCode "/" []) : (TInt y) : l | x == y ->
    l
  (TExtract x 8) : (TCode "btoi" []) : l ->
    (TInt $ fromIntegral x) : (TCode "extract_uint64" []) : l
  x@(TInt _) : (TInt 8) : (TCode "extract3" []) : (TCode "btoi" []) : l ->
    x : (TCode "extract_uint64" []) : l
  a@(TLoad x _) : (TLoad y _) : l
    | x == y ->
      -- This misses if there is ANOTHER load of the same thing
      a : (TCode "dup" []) : l
  a@(TStore x _) : (TLoad y _) : l
    | x == y ->
      (TCode "dup" []) : a : l
  a@(TSubstring s0w _) : b@(TInt xn) : c@(TCode "getbyte" []) : l ->
    case xn < 256 && s0xnp1 < 256 of
      True -> opt_b1 $ (TSubstring (fromIntegral s0xn) (fromIntegral s0xnp1)) : (TCode "btoi" []) : l
      False -> a : b : c : l
    where
      s0xn :: Integer
      s0xn = (fromIntegral s0w) + xn
      s0xnp1 :: Integer
      s0xnp1 = s0xn + 1
  a@(TSubstring s0w _) : b@(TSubstring s1w e1w) : l ->
    case s2n < 256 && e2n < 256 of
      True -> opt_b1 $ (TSubstring (fromIntegral s2n) (fromIntegral e2n)) : l
      False -> a : b : l
    where
      s0n = fromIntegral s0w
      s2n :: Integer
      s2n = s0n + (fromIntegral s1w)
      e2n :: Integer
      e2n = s0n + (fromIntegral e1w)
  (TInt x) : (Titob _) : l ->
    opt_b1 $ (TBytes $ itob 8 x) : l
  (TBytes xbs) : (TCode "btoi" []) : l ->
    opt_b1 $ (TInt $ btoi xbs) : l
  (TBytes xbs) : (TCode "sha256" []) : l ->
    opt_b1 $ (TBytes $ sha256bs xbs) : l
  (TBytes xbs) : (TCode "sha512_256" []) : l ->
    opt_b1 $ (TBytes $ sha512_256bs xbs) : l
  (TBytes xbs) : (TSubstring s e) : l ->
    opt_b1 $ (TBytes $ bsSubstring xbs (fromIntegral s) (fromIntegral e)) : l
  (TBytes xbs) : (TExtract s len) : l | len /= 0 ->
    opt_b1 $ (TBytes $ bsSubstring xbs (fromIntegral s) (fromIntegral $ s + len)) : l
  x : l -> x : l

sha256bs :: BS.ByteString -> BS.ByteString
sha256bs = BA.convert . hashWith SHA256
sha512_256bs :: BS.ByteString -> BS.ByteString
sha512_256bs = BA.convert . hashWith SHA512t_256

bsSubstring :: BS.ByteString -> Int -> Int -> BS.ByteString
bsSubstring bs s e = BS.take e $ BS.drop s bs

padTo :: Int -> a -> [a] -> [a]
padTo p d l = replicate (p - length l) d <> l

itob :: Int -> Integer -> BS.ByteString
itob howMany = BS.pack . padTo howMany 0 . reverse . unroll

btoi :: BS.ByteString -> Integer
btoi = roll . reverse . BS.unpack

unroll :: Integer -> [Word8]
unroll = List.unfoldr go
  where
    go 0 = Nothing
    go i = Just (fromIntegral i, i `shiftR` 8)

roll :: [Word8] -> Integer
roll = foldr unstep 0
  where
    unstep b a = a `shiftL` 8 .|. fromIntegral b

type RestrictCFG = Label -> IO (DotGraph, AnalyzeCFG, BudgetCFG)
type BudgetCFG = IO (Bool, Integer, Integer)
type AnalyzeCFG = Resource -> IO Integer
type ResourceCost = M.Map Resource Integer

buildCFG :: String -> [TEAL] -> IO (DotGraph, RestrictCFG)
buildCFG rlab ts = do
  res_gr :: IORef (LPGraph String ResourceCost) <- newIORef mempty
  let lTop = "TOP"
  let lBot = "BOT"
  (labr :: IORef String) <- newIORef $ lTop
  (k_r :: IORef Integer) <- newIORef $ 1
  (res_r :: IORef ResourceCost) <- newIORef $ mempty
  (calls_r :: IORef [String]) <- newIORef $ mempty
  let modK = modifyIORef k_r
  let l2s = LT.unpack
  let recResource rs c = do
        k <- readIORef k_r
        let f old = Just $ (k * c) + fromMaybe 0 old
        modifyIORef res_r $ M.alter f rs
  let recCost = recResource R_Cost
  let incBudget = recResource R_Budget algoMaxAppProgramCost
  let jump_ :: String -> IO ()
      jump_ t = do
        lab <- readIORef labr
        calls <- readIORef calls_r
        c <- readIORef res_r
        let ff = S.insert (calls, c)
        let fg = Just . ff . fromMaybe mempty
        let f = M.alter fg t
        let g = Just . f . fromMaybe mempty
        modifyIORef res_gr $ M.alter g lab
  let switch t = do
        writeIORef labr t
        writeIORef res_r mempty
        writeIORef calls_r mempty
  let call t = modifyIORef calls_r $ (:) (l2s t)
  let jump t = recCost 1 >> jump_ (l2s t)
  let fswitch ls = recCost 1 >> (mapM_ jump_ $ map l2s ls)
  incBudget -- initial budget
  forM_ ts $ \case
    TFor_top cnt -> do
      modK (\x -> x * cnt)
    TFor_bnz _ cnt lab' -> do
      recCost 1
      modK (\x -> x `div` cnt)
      jump lab'
    TCode "match" labs -> fswitch labs
    TCode "switch" labs -> fswitch labs
    TCode "bnz" [lab'] -> jump lab'
    TCode "bz" [lab'] -> jump lab'
    TCode "b" [lab'] -> do
      jump lab'
      switch ""
    TCode "return" [] -> do
      jump lBot
      switch ""
    TCode "callsub" [lab'] -> do
      call lab'
      recCost 1
    TCode "retsub" [] -> do
      recCost 1
      jump lBot
      switch ""
    TLog len -> do
      recResource R_Log len
      recResource R_LogCalls 1
      recCost 1
    TComment {} -> return ()
    TLabel lab' -> do
      let lab'' = l2s lab'
      jump_ lab''
      switch lab''
    TBytes _ -> recCost 1
    TConst _ -> recCost 1
    TStore {} -> recCost 1
    TLoad {} -> recCost 1
    TInt _ -> recCost 1
    TExtract {} -> recCost 1
    TReplace2 {} -> recCost 1
    TSubstring {} -> recCost 1
    Titob {} -> recCost 1
    TResource r -> recResource r 1
    TCostCredit i -> do
      incBudget
      recCost i
    TCheckOnCompletion -> do
      recResource R_CheckedCompletion 1
      recCost 0
    TCode f _ ->
      case f of
        "sha256" -> recCost 35
        "sha3_256" -> recCost 130
        "keccak256" -> recCost 130
        "sha512_256" -> recCost 45
        "ed25519verify" -> recCost 1900
        "ed25519verify_bare" -> recCost 1900
        "ecdsa_verify" -> recCost 1700
        "ecdsa_pk_decompress" -> recCost 650
        "ecdsa_pk_recover" -> recCost 2000
        "divmodw" -> recCost 20
        "sqrt" -> recCost 4
        "expw" -> recCost 10
        "b+" -> recCost 10
        "b-" -> recCost 10
        "b/" -> recCost 20
        "b*" -> recCost 20
        "b%" -> recCost 20
        "b|" -> recCost 6
        "b&" -> recCost 6
        "b^" -> recCost 6
        "b~" -> recCost 4
        "bsqrt" -> recCost 40
        "bn256_add" -> recCost 70
        "bn256_scalar_mul" -> recCost 970
        "bn256_pairing" -> recCost 8700
        "itxn_begin" -> do
          recResource R_ITxn 1
          recCost 1
        "itxn_next" -> do
          recResource R_ITxn 1
          recCost 1
        _ -> recCost 1
  let renderRc m = intercalate "/" $ map f allResources
        where f r = show $ fromMaybe 0 $ M.lookup r m
  let renderCalls = \case
        [] -> ""
        cls -> show cls <> "/"
  let gs :: LPGraph String ResourceCost -> DotGraph
      gs g =
        flip concatMap (M.toAscList g) $ \(from, cs) ->
          case (from == mempty) of
            True -> []
            False ->
              flip concatMap (M.toAscList cs) $ \(to, es) ->
                flip concatMap (S.toAscList es) $ \(cls, c) ->
                  [(from, to, (M.fromList $ [("label", renderCalls cls <> renderRc c)]))]
  g <- readIORef res_gr
  let getc rs c = fromMaybe 0 $ M.lookup rs c
  let lBots = l2s lBot
  let restrict mustLab = do
        g' <- restrictGraph g $ l2s mustLab
        let analyzeCFG = longestPathBetween g' lTop lBots . getc
        let budgetCFG = budgetAnalyze g' lTop lBots (flip getc)
        return $ (gs g', analyzeCFG, budgetCFG)
  loud $ rlab <> " OnCompletion"
  ensureAllPaths (rlab <> ".OnC") g lTop lBots (getc R_CheckedCompletion) >>= \case
    Nothing -> return ()
    Just p ->
      impossible $ "found a path where OnCompletion was not checked: " <> show p
  return (gs g, restrict)

data LabelRec = LabelRec
  { lr_lab :: Label
  , lr_at :: SrcLoc
  , lr_what :: String
  }
  deriving (Show)

type CompanionCalls = M.Map Label Integer
type CompanionInfo = Maybe CompanionCalls
data CompanionAdds
  = CA_AddCompanion
  | CA_IncrementCalls Label
  deriving (Eq, Ord)
data CompanionRec = CompanionRec
  { cr_ro :: DLArg
  , cr_approval :: B.ByteString
  , cr_clearstate :: B.ByteString
  , cr_ctor :: Integer
  , cr_call :: Integer
  , cr_del :: Integer
  }

checkCost :: String -> Notify -> Outputer -> [LabelRec] -> CompanionInfo -> [TEAL] -> IO (Either String CompanionInfo)
checkCost rlab notify disp ls ci ts = do
  msgR <- newIORef mempty
  let addMsg x = modifyIORef msgR $ flip (<>) $ x <> "\n"
  caR <- newIORef (mempty :: S.Set CompanionAdds)
  let rgs lab gs = do
        mayOutput (disp False ("." <> lab <> "dot")) $
          flip LTIO.writeFile (T.render $ dotty gs)
  loud $ rlab <> " buildCFG"
  (gs, restrictCFG) <- buildCFG rlab ts
  rgs "" gs
  addMsg $ "Conservative analysis on Algorand found:"
  forM_ ls $ \LabelRec {..} -> do
    let starts_at = " starts at " <> show lr_at <> "."
    addMsg $ " * " <> lr_what <> ", which" <> starts_at
    loud $ rlab <> " restrictCFG " <> show lr_lab
    (gs', analyzeCFG, budgetCFG) <- restrictCFG lr_lab
    when True $
      rgs (T.pack $ LT.unpack lr_lab <> ".") gs'
    let doReport precise tooMuch msg_ = do
          let msg = msg_ <> "."
          when tooMuch $ do
            notify precise $ LT.pack $ lr_what <> " " <> msg <> " " <> lr_what <> starts_at
          addMsg $ "   + " <> msg
    let reportCost precise ler algoMax c = do
          let units = ler $ c /= 1
          let uses = if precise then "uses" else "may use up to"
          let pre = uses <> " " <> show c <> " " <> units
          let tooMuch = c > algoMax
          let post = if tooMuch then ", but the limit is " <> show algoMax else ""
          unless (c == 0) $
            doReport precise tooMuch $ pre <> post
    let allResourcesM' = M.withoutKeys allResourcesM $ S.fromList [ R_Cost, R_Budget ]
    costM <- flip mapWithKeyM allResourcesM' $ \rs _ -> do
      let am = maxOf rs
      c <- analyzeCFG rs
      let pe = rPrecise rs
      let ler = flip rLabel rs
      reportCost pe ler am c
      return c
    let sums = foldr (+) 0 . M.elems . M.restrictKeys costM . S.fromList
    let refs = sums [R_App, R_Asset, R_Account]
    void $ reportCost False (flip plural "transaction reference") algoMaxAppTotalTxnReferences refs
    do
      (over, cost, budget) <- budgetCFG
      let residue = budget - cost
      let doReport' = doReport True
      let uses = "uses " <> show cost
      let budget' x = "its budget " <> x <> " " <> show budget
      case over of
        False -> doReport' False $
          uses <> " of " <> budget' "of" <> " (" <> show residue <> " is left over)"
        True -> do
          modifyIORef caR $ S.insert $
            case ci of
              Nothing -> CA_AddCompanion
              Just _ -> CA_IncrementCalls lr_lab
          doReport' True $
            uses <> ", but " <> budget' "is"
    let fees = sums [R_Txn, R_ITxn]
    addMsg $ "   + costs " <> show fees <> " " <> plural (fees /= 1) "fee" <> "."
  msg <- readIORef msgR
  cas <- S.toAscList <$> readIORef caR
  --let cr = Left msg
  cr <- case cas of
    [] ->
      return $ Left msg
    [ CA_AddCompanion ] ->
      return $ Right $ Just mempty
    as ->
      case ci of
        Nothing -> impossible "inc nothing"
        Just cim -> do
          let f = \case
                CA_AddCompanion -> impossible "add just"
                CA_IncrementCalls lab -> M.insertWith (+) lab 1
          let cim' = foldr f cim as
          return $ Right $ Just cim'
  return $ cr

type Lets = M.Map DLVar (App ())

data Pre = Pre
  { pMaps :: DLMapInfos
  }

data Env = Env
  { ePre :: Pre
  , eApiLs :: IORef [LabelRec]
  , eProgLs :: IORef (Maybe [LabelRec])
  , eMaxApiRetSize :: IORef Integer
  , eMapDataSize :: Integer
  , eMapDataTy :: DLType
  , eMapKeysl :: [Word8]
  , eFailuresR :: ErrorSetRef
  , eWarningsR :: ErrorSetRef
  , eCounter :: Counter
  , eStateSizeR :: IORef Integer
  , eWhich :: Maybe Int
  , eLabel :: Counter
  , eOutputR :: IORef TEALs
  , eHP :: ScratchSlot
  , eSP :: ScratchSlot
  , eVars :: M.Map DLVar ScratchSlot
  , eLets :: Lets
  , eLetSmalls :: M.Map DLVar Bool
  , eResources :: ResourceSets
  , eNewToks :: IORef (S.Set DLArg)
  , eInitToks :: IORef (S.Set DLArg)
  , eCompanion :: CompanionInfo
  , eCompanionRec :: CompanionRec
  , eLibrary :: IORef (M.Map LibFun (Label, App ()))
  , eGetStateKeys :: IO Int
  , eABI :: IORef (M.Map String ABInfo)
  , eRes :: IORef (M.Map T.Text AS.Value)
  }

data ABInfo = ABInfo
  { abiPure :: Bool
  }

instance HasCounter Env where
  getCounter = eCounter

insertResult :: T.Text -> AS.Value -> App ()
insertResult k v = do
  r <- asks eRes
  liftIO $ modifyIORef r $ M.insert k v

type App = ReaderT Env IO

class CompileK a where
  cpk :: App b -> a -> App b

class Compile a where
  cp :: a -> App ()

data LibFun
  = LF_cMapLoad
  | LF_checkTxn_net
  | LF_checkTxn_tok
  | LF_checkUInt256ResultLen
  deriving (Eq, Ord, Show)

libDefns :: App ()
libDefns = do
  libr <- asks eLibrary
  lib <- liftIO $ readIORef libr
  forM_ lib $ \(_, impl) -> impl

libCall :: LibFun -> App () -> App ()
libCall lf impl = do
  libr <- asks eLibrary
  lib <- liftIO $ readIORef libr
  lab <-
    case M.lookup lf lib of
      Nothing -> do
        lab <- freshLabel $ show lf
        let impl' = label lab >> impl
        liftIO $ modifyIORef libr $ M.insert lf (lab, impl')
        return $ lab
      Just (lab, _) -> return lab
  code "callsub" [ lab ]

separateResources :: App a -> App a
separateResources = dupeResources . resetToks

recordWhich :: Maybe Int -> App a -> App a
recordWhich mn = local (\e -> e {eWhich = mn}) . separateResources

data Resource
  = R_Asset
  | R_App
  | R_Account
  | R_Log
  | R_LogCalls
  | R_Budget
  | R_Cost
  | R_ITxn
  | R_Txn
  | R_CheckedCompletion
  deriving (Eq, Ord, Enum, Bounded, Show)

allResources :: [Resource]
allResources = enumerate List.\\ [ R_CheckedCompletion ]

allResourcesM :: M.Map Resource ()
allResourcesM = M.fromList $ map (flip (,) ()) allResources

useResource :: Resource -> App ()
useResource = output . TResource

type ResourceSet = S.Set DLArg

type ResourceSets = IORef (M.Map Resource ResourceSet)

plural :: Bool -> String -> String
plural ph x = x <> if ph then "s" else ""

rLabel :: Bool -> Resource -> String
rLabel ph = \case
  R_Txn -> "input " <> p "transaction"
  R_ITxn -> "inner " <> p "transaction"
  R_Asset -> p "asset"
  R_App -> "foreign " <> p "application"
  R_Account -> p "account"
  R_Budget -> p "unit" <> " of budget"
  R_Cost -> p "unit" <> " of cost"
  R_Log -> p "byte" <> " of logs"
  R_LogCalls -> "log " <> p "call"
  R_CheckedCompletion -> p "completion" <> " checked"
  where
    p = plural ph

rPrecise :: Resource -> Bool
rPrecise = \case
  R_Txn -> True
  R_ITxn -> True
  R_App -> False
  R_Asset -> False
  R_Account -> False
  R_Budget -> True
  R_Cost -> True
  R_Log -> True
  R_LogCalls -> True
  R_CheckedCompletion -> True

maxOf :: Resource -> Integer
maxOf = \case
  R_App -> algoMaxAppTxnForeignApps
  R_Asset -> algoMaxAppTxnForeignAssets
  R_Account -> algoMaxAppTxnAccounts
  R_Txn -> algoMaxTxGroupSize
  R_ITxn -> algoMaxInnerTransactions * algoMaxTxGroupSize
  R_Budget -> impossible "budget"
  R_Cost -> impossible "cost"
  R_Log -> algoMaxLogLen
  R_LogCalls -> algoMaxLogCalls
  R_CheckedCompletion -> 1

newResources :: IO ResourceSets
newResources = newIORef $ mempty

dupeResources :: App a -> App a
dupeResources m = do
  c' <- (liftIO . dupeIORef) =<< asks eResources
  local (\e -> e {eResources = c'}) m

readResource :: Resource -> App ResourceSet
readResource r = do
  rsr <- asks eResources
  m <- liftIO $ readIORef rsr
  return $ fromMaybe mempty $ M.lookup r m

freeResource :: Resource -> DLArg -> App ()
freeResource r a = do
  vs <- readResource r
  let vs' = S.insert a vs
  rsr <- asks eResources
  liftIO $ modifyIORef rsr $ M.insert r vs'

incResource :: Resource -> DLArg -> App ()
incResource r a = do
  vs <- readResource r
  case S.member a vs of
    True -> return ()
    False -> do
      useResource r
      freeResource r a

resetToks :: App a -> App a
resetToks m = do
  ntoks <- liftIO $ newIORef mempty
  itoks <- liftIO $ newIORef mempty
  local (\e -> e {eNewToks = ntoks, eInitToks = itoks}) m

addTok :: (Env -> IORef (S.Set DLArg)) -> DLArg -> App ()
addTok ef tok = do
  r <- asks ef
  liftIO $ modifyIORef r (S.insert tok)

addNewTok :: DLArg -> App ()
addNewTok = addTok eNewToks

addInitTok :: DLArg -> App ()
addInitTok = addTok eInitToks

isTok :: (Env -> IORef (S.Set DLArg)) -> DLArg -> App Bool
isTok ef tok = do
  ts <- (liftIO . readIORef) =<< asks ef
  return $ tok `S.member` ts

isNewTok :: DLArg -> App Bool
isNewTok = isTok eNewToks

isInitTok :: DLArg -> App Bool
isInitTok = isTok eInitToks

output :: TEAL -> App ()
output t = do
  Env {..} <- ask
  liftIO $ modifyIORef eOutputR (flip DL.snoc t)

code :: LT.Text -> [LT.Text] -> App ()
code f args = output $ TCode f args

label :: LT.Text -> App ()
label = output . TLabel

comment :: LT.Text -> App ()
comment = output . TComment INo

block_ :: LT.Text -> App a -> App a
block_ lab m = do
  output $ TComment IUp $ ""
  output $ TComment INo $ "{ " <> lab
  x <- m
  output $ TComment INo $ lab <> " }"
  output $ TComment IDo $ ""
  return x

block :: Label -> App a -> App a
block lab m = block_ lab $ label lab >> m

dupn :: Int -> App ()
dupn = \case
  0 -> nop
  1 -> op "dup"
  k -> code "dupn" [ texty k ]

assert :: App ()
assert = op "assert"

asserteq :: App ()
asserteq = op "==" >> assert

op :: TealOp -> App ()
op = flip code []

nop :: App ()
nop = return ()

dont_concat_first :: [App ()]
dont_concat_first = nop : repeat (op "concat")

padding :: Integer -> App ()
padding = cp . bytesZeroLit

badlike :: (Env -> ErrorSetRef) -> LT.Text -> App ()
badlike eGet lab = do
  r <- asks eGet
  liftIO $ bad_io r lab

bad_nc :: LT.Text -> App ()
bad_nc = badlike eFailuresR

bad :: LT.Text -> App ()
bad lab = do
  bad_nc lab
  mapM_ comment $ LT.lines $ "BAD " <> lab

warn :: LT.Text -> App ()
warn = badlike eWarningsR

freshLabel :: String -> App LT.Text
freshLabel d = do
  i <- (liftIO . incCounter) =<< (eLabel <$> ask)
  return $ "l" <> LT.pack (show i) <> "_" <> LT.pack d

store_let :: DLVar -> Bool -> App () -> App a -> App a
store_let dv small cgen m = do
  Env {..} <- ask
  local
    (\e ->
       e
         { eLets = M.insert dv cgen eLets
         , eLetSmalls = M.insert dv small eLetSmalls
         })
    $ m

letSmall :: DLVar -> App Bool
letSmall dv = do
  Env {..} <- ask
  return $ fromMaybe False (M.lookup dv eLetSmalls)

lookup_let :: DLVar -> App ()
lookup_let dv = do
  Env {..} <- ask
  case M.lookup dv eLets of
    Just m -> m
    Nothing -> bad $ LT.pack $ show eWhich <> "lookup_let " <> show (pretty dv) <> " not in " <> (List.intercalate ", " $ map (show . pretty) $ M.keys eLets)

store_var :: DLVar -> ScratchSlot -> App a -> App a
store_var dv ss m = do
  Env {..} <- ask
  local (\e -> e {eVars = M.insert dv ss eVars}) $
    m

lookup_var :: DLVar -> App ScratchSlot
lookup_var dv = do
  Env {..} <- ask
  case M.lookup dv eVars of
    Just x -> return $ x
    Nothing -> impossible $ "lookup_var " <> show dv

salloc :: (ScratchSlot -> App a) -> App a
salloc fm = do
  Env {..} <- ask
  let eSP' = eSP - 1
  when (eSP' == eHP) $ do
    bad "Too many scratch slots"
  local (\e -> e {eSP = eSP'}) $
    fm eSP

salloc_ :: LT.Text -> (App () -> App () -> App a) -> App a
salloc_ lab fm =
  salloc $ \loc -> do
    fm (output $ TStore loc lab) (output $ TLoad loc lab)

sallocLet :: DLVar -> App () -> App a -> App a
sallocLet dv cgen km = do
  salloc_ (textyv dv) $ \cstore cload -> do
    cgen
    cstore
    store_let dv True cload km

sallocVarLet :: DLVarLet -> Bool -> App () -> App a -> App a
sallocVarLet (DLVarLet mvc dv) sm cgen km = do
  let once = store_let dv sm cgen km
  case mvc of
    Nothing -> km
    Just DVC_Once -> once
    Just DVC_Many ->
      case sm of
        True -> once
        False -> sallocLet dv cgen km

ctobs :: DLType -> App ()
ctobs = \case
  T_UInt UI_Word -> output (Titob False)
  T_UInt UI_256 -> nop
  T_Bool -> output (Titob True) >> output (TSubstring 7 8)
  T_Null -> nop
  T_Bytes _ -> nop
  T_BytesDyn -> nop
  T_StringDyn -> nop
  T_Digest -> nop
  T_Address -> nop
  T_Contract -> ctobs $ T_UInt UI_Word
  T_Token -> ctobs $ T_UInt UI_Word
  T_Array {} -> nop
  T_Tuple {} -> nop
  T_Object {} -> nop
  T_Data {} -> nop
  T_Struct {} -> nop

cfrombs :: DLType -> App ()
cfrombs = \case
  T_UInt UI_Word -> op "btoi"
  T_UInt UI_256 -> nop
  T_Bool -> op "btoi"
  T_Null -> nop
  T_Bytes _ -> nop
  T_BytesDyn -> nop
  T_StringDyn -> nop
  T_Digest -> nop
  T_Address -> nop
  T_Contract -> cfrombs $ T_UInt UI_Word
  T_Token -> cfrombs $ T_UInt UI_Word
  T_Array {} -> nop
  T_Tuple {} -> nop
  T_Object {} -> nop
  T_Data {} -> nop
  T_Struct {} -> nop

ctzero :: DLType -> App ()
ctzero = \case
  T_UInt UI_Word -> cint_ sb 0
  t -> do
    padding =<< typeSizeOf t
    cfrombs t

chkint :: SrcLoc -> Integer -> Integer
chkint at = checkIntLiteralC at conName' conCons'

cint_ :: SrcLoc -> Integer -> App ()
cint_ at i = output $ TInt $ chkint at i

instance Compile Integer where
  cp = cint_ sb

instance Compile Int where
  cp x = cp y
    where
      y :: Integer = fromIntegral x

cint :: Integer -> App ()
cint = cp

instance Compile DLLiteral where
  cp = \case
    DLL_Null -> cbs ""
    DLL_Bool b -> cint $ (if b then 1 else 0)
    DLL_Int at UI_Word i -> cint_ at i
    DLL_Int at UI_256 i ->
      cp $ itob 32 $ checkIntLiteral at "UInt256" 0 uint256_Max i
    DLL_TokenZero -> cint 0

instance Compile Bool where
  cp = cp . DLL_Bool

ca_boolb :: DLArg -> Maybe B.ByteString
ca_boolb = \case
  DLA_Literal (DLL_Bool b) ->
    Just $ B.singleton $ toEnum $ if b then 1 else 0
  _ -> Nothing

cas_boolbs :: [DLArg] -> Maybe B.ByteString
cas_boolbs = mconcat . map ca_boolb

instance Compile DLVar where
  cp = lookup_let

instance Compile DLArg where
  cp = \case
    DLA_Var v -> cp v
    DLA_Constant c -> cp $ conCons' c
    DLA_Literal c -> cp c
    DLA_Interact {} -> impossible "consensus interact"

argSmall :: DLArg -> App Bool
argSmall = \case
  DLA_Var v -> letSmall v
  DLA_Constant {} -> return True
  DLA_Literal {} -> return True
  DLA_Interact {} -> impossible "consensus interact"

exprSmall :: DLExpr -> App Bool
exprSmall = \case
  DLE_Arg _ a -> argSmall a
  _ -> return False

czpad :: Integer -> App ()
czpad 0 = return ()
czpad xtra = do
  padding xtra
  op "concat"

cprim :: PrimOp -> [DLArg] -> App ()
cprim = \case
  SELF_ADDRESS {} -> impossible "self address"
  ADD t _ -> bcallz t "+"
  SUB t _ -> bcallz t "-"
  MUL t _ -> bcallz t "*"
  DIV t _ -> bcallz t "/"
  MOD t _ -> bcallz t "%"
  PLT t -> bcall t "<"
  PLE t -> bcall t "<="
  PEQ t -> bcall t "=="
  PGT t -> bcall t ">"
  PGE t -> bcall t ">="
  SQRT t -> bcallz t "sqrt"
  UCAST from to trunc pv -> \case
    [v] -> do
      case (from, to) of
        (UI_Word, UI_256) -> do
          padding $ 3 * 8
          cp v
          output $ Titob False
          op "concat"
        (UI_256, UI_Word) -> do
          cp v
          -- [ v ]
          let ext i = cint (8 * i) >> op "extract_uint64"
          unless (trunc || pv == PV_Veri) $ do
            comment "Truncation check"
            op "dup"
            op "bitlen"
            cint 64
            op "<="
            assert
          ext 3
        x -> impossible $ "ucast " <> show x
    _ -> impossible "cprim: UCAST args"
  MUL_DIV _ -> \case
    [x, y, z] -> do
      cp x
      cp y
      op "mulw"
      cp z
      op "divw"
    _ -> impossible "cprim: MUL_DIV args"
  LSH -> call "<<"
  RSH -> call ">>"
  BAND t -> bcallz t "&"
  BIOR t -> bcallz t "|"
  BXOR t -> bcallz t "^"
  DIGEST_XOR -> call "b^"
  BYTES_XOR -> call "b^"
  DIGEST_EQ -> call "=="
  ADDRESS_EQ -> call "=="
  TOKEN_EQ -> call "=="
  BTOI_LAST8 {} -> \case
    [x] -> do
      bl <- fromIntegral <$> (typeSizeOf $ argTypeOf x)
      let (start, len) = if bl > 8 then (bl - 8, 8) else (0, 0)
      cp x
      output $ TExtract start len
      op "btoi"
    _ -> impossible "btoiLast8"
  BYTES_ZPAD xtra -> \case
    [x] -> do
      cp x
      czpad xtra
    _ -> impossible $ "zpad"
  IF_THEN_ELSE -> \case
    [be, DLA_Literal (DLL_Bool True), DLA_Literal (DLL_Bool False)] -> do
      cp be
    [be, DLA_Literal (DLL_Bool False), DLA_Literal (DLL_Bool True)] -> do
      cp be
      op "!"
    [be, DLA_Literal (DLL_Bool True), fe] -> do
      cp be
      cp fe
      op "||"
    [be, DLA_Literal (DLL_Bool False), fe] -> do
      -- be \ fe |  T  | F
      --    T    |  F  | F
      --    F    |  T  | F
      cp be
      op "!"
      cp fe
      op "&&"
    [be, te, DLA_Literal (DLL_Bool False)] -> do
      cp be
      cp te
      op "&&"
    [be, te, DLA_Literal (DLL_Bool True)] -> do
      -- be \ te |  T  | F
      --    T    |  T  | F
      --    F    |  T  | T
      cp be
      op "!"
      cp te
      op "||"
    [be, te, fe] -> do
      cp fe
      cp te
      cp be
      op "select"
    _ -> impossible "ite args"
  CTC_ADDR_EQ -> \case
    [ ctca, aa ] -> do
      cContractToAddr ctca
      cp aa
      op "=="
    _ -> impossible "ctcAddrEq args"
  GET_CONTRACT -> const $ do
    code "txn" ["ApplicationID"]
  GET_ADDRESS -> const $ cContractAddr
  GET_COMPANION -> const $ callCompanion sb CompanionGet
  STRINGDYN_CONCAT -> call "concat" -- assumes two-args/type safe
  UINT_TO_STRINGDYN ui -> \case
    [i] -> do
      cp i
      case ui of
        UI_256 -> return ()
        UI_Word -> output $ Titob False
      bad "Uses UInt.toStringDyn"
    _ -> impossible "UInt.toStringDyn"
  where
    call o = \args -> do
      forM_ args cp
      op o
    bcall t o = call $ (if t == UI_256 then "b" else "") <> o
    bcallz t o args = do
      bcall t o args
      when (t == UI_256) $ do
        libCall LF_checkUInt256ResultLen $ do
          op "dup"
          op "len"
          cp =<< (typeSizeOf $ T_UInt UI_256)
          op "swap"
          op "-"
          -- This traps on purpose when the result is longer than 256
          op "bzero"
          op "swap"
          op "concat"
          op "retsub"

cContractToAddr :: DLArg -> App ()
cContractToAddr ctca = do
  cbs "appID"
  cp ctca
  ctobs $ T_UInt UI_Word
  op "concat"
  op "sha512_256"

cconcatbs_ :: (DLType -> App ()) -> [(DLType, App ())] -> App ()
cconcatbs_ f l = do
  totlen <- typeSizeOf $ T_Tuple $ map fst l
  check_concat_len totlen
  case l of
    [] -> padding 0
    _ -> do
      forM_ (zip l dont_concat_first) $ \((t, m), a) ->
        m >> f t >> a

cconcatbs :: [(DLType, App ())] -> App ()
cconcatbs = cconcatbs_ ctobs

check_concat_len :: Integer -> App ()
check_concat_len totlen =
  unless (totlen <= algoMaxStringSize) $ do
    bad $
      "Cannot `concat` " <> texty totlen
        <> " bytes; the resulting byte array must be <= 4096 bytes."
        <> " This is caused by a Reach data type being too large."

cdigest :: [(DLType, App ())] -> App ()
cdigest l = cconcatbs l >> op "sha256"

cextract :: Integer -> Integer -> App ()
cextract _s 0 = do
  op "pop"
  padding 0
cextract s l =
  case s < 256 && l < 256 && l /= 0 of
    True -> do
      output $ TExtract (fromIntegral s) (fromIntegral l)
    False -> do
      cp s
      cp l
      op "extract3"

creplace :: Integer -> App () -> App ()
creplace s cnew = do
  case s < 256 of
    True -> do
      cnew
      output $ TReplace2 (fromIntegral s)
    False -> do
      cp s
      cnew
      op "replace3"

cArraySet :: SrcLoc -> DLType -> Maybe (App ()) -> Either Integer (App ()) -> App () -> App ()
cArraySet _at t mcbig eidx cnew = do
  --- []
  case mcbig of
    Nothing -> return ()
    Just cbig -> cbig
  --- [ big ]
  tsz <- typeSizeOf t
  case eidx of
    -- Static index
    Left ii -> do
      --- [ big ]
      creplace (ii * tsz) cnew
    Right cidx -> do
      --- [ big ]
      cidx
      cp tsz
      op "*"
      --- [ big, start ]
      cnew
      op "replace3"

computeExtract :: [DLType] -> Integer -> App (DLType, Integer, Integer)
computeExtract ts idx = do
  szs <- mapM typeSizeOf ts
  let starts = scanl (+) 0 szs
  let idx' = fromIntegral idx
  let tsz = zip3 ts starts szs
  case atMay tsz idx' of
    Nothing -> impossible "bad idx"
    Just x -> return x

cfor :: Integer -> (App () -> App ()) -> App ()
cfor 0 _ = return ()
cfor 1 body = body (cint 0)
cfor maxi body = do
  when (maxi < 2) $ impossible "cfor maxi=0"
  top_lab <- freshLabel "forTop"
  end_lab <- freshLabel "forEnd"
  block_ top_lab $ do
    salloc_ (top_lab <> "Idx") $ \store_idx load_idx -> do
      cint 0
      store_idx
      label top_lab
      output $ TFor_top maxi
      body load_idx
      load_idx
      cint 1
      op "+"
      op "dup"
      store_idx
      cp maxi
      op "<"
      output $ TFor_bnz top_lab maxi end_lab
    label end_lab
    return ()

doArrayRef :: SrcLoc -> DLArg -> Bool -> Either DLArg (App ()) -> App ()
doArrayRef at aa frombs ie = do
  let (t, _) = argArrTypeLen aa
  cp aa
  cArrayRef at t frombs ie

cArrayRef :: SrcLoc -> DLType -> Bool -> Either DLArg (App ()) -> App ()
cArrayRef _at t frombs ie = do
  tsz <- typeSizeOf t
  let ie' =
        case ie of
          Left ia -> cp ia
          Right x -> x
  case t of
    T_Bool -> do
      ie'
      op "getbyte"
      case frombs of
        True -> nop
        False -> ctobs T_Bool
    _ -> do
      case ie of
        Left (DLA_Literal (DLL_Int _ UI_Word ii)) -> do
          let start = ii * tsz
          cextract start tsz
        _ -> do
          cp tsz
          ie'
          op "*"
          cp tsz
          op "extract3"
      case frombs of
        True -> cfrombs t
        False -> nop

instance Compile DLLargeArg where
  cp = \case
    DLLA_Array t as ->
      case t of
        T_Bool ->
          case cas_boolbs as of
            Nothing -> normal
            Just x -> cp x
        _ -> normal
      where
        normal = cconcatbs $ map (\a -> (t, cp a)) as
    DLLA_Tuple as ->
      cconcatbs $ map (\a -> (argTypeOf a, cp a)) as
    DLLA_Obj m -> cp $ DLLA_Struct $ M.toAscList m
    DLLA_Data tm vn va -> do
      let h ((k, v), i) = (k, (i, v))
      let tm' = M.fromList $ map h $ zip (M.toAscList tm) [0 ..]
      let (vi, vt) = fromMaybe (impossible $ "dla_data") $ M.lookup vn tm'
      cp $ B.singleton $ BI.w2c vi
      cp va
      ctobs vt
      vlen <- (+) 1 <$> typeSizeOf (argTypeOf va)
      op "concat"
      dlen <- typeSizeOf $ T_Data tm
      czpad $ fromIntegral $ dlen - vlen
      check_concat_len dlen
    DLLA_Struct kvs ->
      cconcatbs $ map (\a -> (argTypeOf a, cp a)) $ map snd kvs
    DLLA_Bytes bs -> cp bs
    DLLA_BytesDyn bs -> cp bs
    DLLA_StringDyn t -> cp $ bpack $ T.unpack t

instance Compile B.ByteString where
  cp bs = do
    when (B.length bs > fromIntegral algoMaxStringSize) $
      bad $ "Cannot create raw bytes of length greater than " <> texty algoMaxStringSize <> "."
    output $ TBytes bs

cbs :: B.ByteString -> App ()
cbs = cp

cTupleRef :: DLType -> Integer -> App ()
cTupleRef tt idx = do
  -- [ Tuple ]
  let ts = tupleTypes tt
  (t, start, sz) <- computeExtract ts idx
  case (ts, idx) of
    ([_], 0) ->
      return ()
    _ -> do
      cextract start sz
  -- [ ValueBs ]
  cfrombs t
  -- [ Value ]
  return ()

cTupleSet :: SrcLoc -> App () -> DLType -> Integer -> App ()
cTupleSet _at cnew tt idx = do
  -- [ Tuple ]
  let ts = tupleTypes tt
  (t, start, _) <- computeExtract ts idx
  creplace start $ cnew >> ctobs t

cMapLoad :: App ()
cMapLoad = libCall LF_cMapLoad $ do
  Env {..} <- ask
  labReal <- freshLabel "mapLoadDo"
  labDef <- freshLabel "mapLoadDef"
  op "dup"
  code "txn" ["ApplicationID"]
  op "app_opted_in"
  code "bnz" [labReal]
  label labDef
  op "pop"
  padding eMapDataSize
  op "retsub"
  label labReal
  let getOne mi = do
        -- [ Address ]
        cp $ keyVary mi
        -- [ Address, Key ]
        op "app_local_get"
        -- [ MapData ]
        return ()
  case eMapKeysl of
    -- Special case one key:
    [0] -> getOne 0
    _ -> do
      -- [ Address ]
      -- [ Address, MapData_0? ]
      forM_ (zip eMapKeysl $ False : repeat True) $ \(mi, doConcat) -> do
        -- [ Address, MapData_N? ]
        case doConcat of
          True -> code "dig" ["1"]
          False -> op "dup"
        -- [ Address, MapData_N?, Address ]
        getOne mi
        -- [ Address, MapData_N?, NewPiece ]
        case doConcat of
          True -> op "concat"
          False -> nop
        -- [ Address, MapData_N+1 ]
        return ()
      -- [ Address, MapData_k ]
      op "swap"
      op "pop"
      -- [ MapData ]
      return ()
  op "retsub"

cMapStore :: App () -> App ()
cMapStore cnew = do
  Env {..} <- ask
  -- [ Address ]
  case eMapKeysl of
    -- Special case one key:
    [0] -> do
      -- [ Address ]
      cp $ keyVary 0
      -- [ Address, Key ]
      cnew
      -- [ Address, Key, Value ]
      op "app_local_put"
    _ -> do
      cnew
      forM_ eMapKeysl $ \mi -> do
        -- [ Address, MapData' ]
        code "dig" ["1"]
        -- [ Address, MapData', Address ]
        cp $ keyVary mi
        -- [ Address, MapData', Address, Key ]
        code "dig" ["2"]
        -- [ Address, MapData', Address, Key, MapData' ]
        cStateSlice eMapDataSize mi
        -- [ Address, MapData', Address, Key, Value ]
        op "app_local_put"
        -- [ Address, MapData' ]
        return ()
      -- [ Address, MapData' ]
      op "pop"
      op "pop"
      -- [ ]
      return ()

divup :: Integer -> Integer -> Integer
divup x y = ceiling $ (fromIntegral x :: Double) / (fromIntegral y)

computeStateSizeAndKeys :: Monad m => NotifyFm m -> LT.Text -> Integer -> Integer -> m (Integer, [Word8])
computeStateSizeAndKeys badx prefix size limit = do
  let keys = size `divup` algoMaxAppBytesValueLen_usable
  when (keys > limit) $ do
    badx $ "Too many " <> prefix <> " keys, " <> texty keys <> ", but limit is " <> texty limit
  let keysl = take (fromIntegral keys) [0 ..]
  return (keys, keysl)

cSvsLoad :: Integer -> App ()
cSvsLoad size = do
  (_, keysl) <- computeStateSizeAndKeys bad "svs" size algoMaxGlobalSchemaEntries_usable
  unless (null keysl) $ do
    -- [ SvsData_0? ]
    forM_ (zip keysl $ False : repeat True) $ \(mi, doConcat) -> do
      -- [ SvsData_N? ]
      cp $ keyVary mi
      -- [ SvsData_N?, Key ]
      op "app_global_get"
      -- [ SvsData_N?, NewPiece ]
      case doConcat of
        True -> op "concat"
        False -> nop
      -- [ SvsData_N+1 ]
      return ()
    -- [ SvsData_k ]
    gvStore GV_svs

cSvsSave :: SrcLoc -> [DLArg] -> App ()
cSvsSave _at svs = do
  let la = DLLA_Tuple svs
  let lat = largeArgTypeOf la
  size <- typeSizeOf lat
  cp la
  ctobs lat
  (_, keysl) <- computeStateSizeAndKeys bad "svs" size algoMaxGlobalSchemaEntries_usable
  ssr <- asks eStateSizeR
  liftIO $ modifyIORef ssr $ max size
  -- [ SvsData ]
  forM_ keysl $ \vi -> do
    -- [ SvsData ]
    cp $ keyVary vi
    -- [ SvsData, Key ]
    code "dig" ["1"]
    -- [ SvsData, Key, SvsData ]
    cStateSlice size vi
    -- [ SvsData, Key, ViewData' ]
    op "app_global_put"
    -- [ SvsData ]
    return ()
  -- [ SvsData ]
  op "pop"
  -- [ ]
  return ()

cGetBalance :: SrcLoc -> Maybe (App ()) -> Maybe DLArg -> App ()
cGetBalance _at mmin = \case
  Nothing -> do
    -- []
    cContractAddr
    op "balance"
    -- [ bal ]
    case mmin of
      Nothing -> do
        cContractAddr
        op "min_balance"
      Just m -> m
    -- [ bal, min_bal ]
    op "-"
  Just tok -> do
    cContractAddr
    incResource R_Asset tok
    cp tok
    code "asset_holding_get" [ "AssetBalance" ]
    op "pop"

instance Compile DLExpr where
  cp = \case
    DLE_Arg _ a -> cp a
    DLE_LArg _ a -> cp a
    DLE_Impossible at _ (Err_Impossible_Case s) ->
      impossible $ "ce: impossible case `" <> s <> "` encountered at: " <> show at
    DLE_Impossible at _ err -> expect_thrown at err
    DLE_VerifyMuldiv at _ _ _ err ->
      expect_thrown at err
    DLE_PrimOp _ p args -> cprim p args
    DLE_ArrayRef at aa ia -> doArrayRef at aa True (Left ia)
    DLE_ArraySet at aa ia va -> do
      let (t, _) = argArrTypeLen aa
      case t of
        T_Bool -> do
          cp aa
          cp ia
          cp va
          op "setbyte"
        _ -> do
          let cnew = cp va >> ctobs t
          mcbig <-
            argSmall aa >>= \case
              False -> do
                cp aa
                return $ Nothing
              True -> do
                return $ Just $ cp aa
          let eidx =
                case ia of
                  DLA_Literal (DLL_Int _ UI_Word ii) -> Left ii
                  _ -> Right $ cp ia
          cArraySet at t mcbig eidx cnew
    DLE_ArrayConcat _ x y -> do
      let (xt, xlen) = argArrTypeLen x
      let (_, ylen) = argArrTypeLen y
      cp x
      cp y
      xtz <- typeSizeOf xt
      check_concat_len $ (xlen + ylen) * xtz
      op "concat"
    DLE_BytesDynCast _ v -> do
      cp v
    DLE_TupleRef _ ta idx -> do
      cp ta
      cTupleRef (argTypeOf ta) idx
    DLE_TupleSet at tup_a index val_a -> do
      cp tup_a
      cTupleSet at (cp val_a) (argTypeOf tup_a) index
    DLE_ObjectRef _ obj_a fieldName -> do
      cp obj_a
      uncurry cTupleRef $ objectRefAsTupleRef obj_a fieldName
    DLE_ObjectSet at obj_a fieldName val_a -> do
      cp obj_a
      uncurry (cTupleSet at (cp val_a)) $ objectRefAsTupleRef obj_a fieldName
    DLE_Interact {} -> impossible "consensus interact"
    DLE_Digest _ args -> cdigest $ map go args
      where
        go a = (argTypeOf a, cp a)
    DLE_Transfer mt_at who mt_amt mt_mtok -> do
      let mt_always = False
      let mt_mrecv = Just $ Left who
      let mt_mcclose = Nothing
      let mt_next = False
      let mt_submit = True
      void $ makeTxn $ MakeTxn {..}
    DLE_TokenInit mt_at tok -> do
      block_ "TokenInit" $ do
        let mt_always = True
        let mt_mtok = Just tok
        let mt_amt = DLA_Literal $ DLL_Int sb UI_Word 0
        let mt_mrecv = Nothing
        let mt_next = False
        let mt_submit = True
        let mt_mcclose = Nothing
        let ct_at = mt_at
        let ct_mtok = Nothing
        let ct_amt = DLA_Literal $ minimumBalance_l
        addInitTok tok
        void $ checkTxn $ CheckTxn {..}
        void $ makeTxn $ MakeTxn {..}
    DLE_TokenAccepted _ addr tok -> do
      cp addr
      cp tok
      incResource R_Account addr
      incResource R_Asset tok
      code "asset_holding_get" [ "AssetBalance" ]
      op "swap"
      op "pop"
    DLE_CheckPay ct_at fs ct_amt ct_mtok -> do
      void $ checkTxn $ CheckTxn {..}
      show_stack "CheckPay" Nothing ct_at fs
    DLE_Claim at fs t a mmsg -> do
      let check = cp a >> assert
      case t of
        CT_Assert -> impossible "assert"
        CT_Assume -> check
        CT_Enforce -> check
        CT_Require -> check
        CT_Possible -> impossible "possible"
        CT_Unknowable {} -> impossible "unknowable"
      show_stack "Claim" mmsg at fs
    DLE_Wait {} -> nop
    DLE_PartSet _ _ a -> cp a
    DLE_MapRef _ (DLMVar i) fa -> do
      incResource R_Account fa
      cp fa
      cMapLoad
      mdt <- getMapDataTy
      cTupleRef mdt $ fromIntegral i
    DLE_MapSet at mpv@(DLMVar i) fa mva -> do
      incResource R_Account fa
      Env {..} <- ask
      let Pre {..} = ePre
      mdt <- getMapDataTy
      mt <- getMapTy mpv
      case (length eMapKeysl) == 1 && (M.size pMaps) == 1 of
        -- Special case one key and one map
        True -> do
          cp fa
          cMapStore $ cp $ mdaToMaybeLA mt mva
        _ -> do
          cp fa
          cMapStore $ do
            cp fa
            cMapLoad
            let cnew = cp $ mdaToMaybeLA mt mva
            cTupleSet at cnew mdt $ fromIntegral i
    DLE_Remote at fs ro rng_ty (DLRemote rm' (DLPayAmt pay_net pay_ks) as (DLWithBill _nRecv nnRecv _nnZero) malgo) -> do
      let DLRemoteALGO _fees r_accounts r_assets r_addr2acc r_apps r_oc r_strictPay r_rawCall _ _ _ = malgo
      warn_lab <- asks eWhich >>= \case
        Just which -> return $ "Step " <> show which
        Nothing -> return $ "This program"
      warn $ LT.pack $
        warn_lab <> " calls a remote object at " <> show at <> ". This means that Reach's conservative analysis of resource utilization and fees is incorrect, because we cannot take into account the needs of the remote object. Furthermore, the remote object may require special transaction parameters which are not expressed in the Reach API or the Algorand ABI standards."
      let ts = map argTypeOf as
      let rm = fromMaybe (impossible "XXX") rm'
      sig <- signatureStr r_addr2acc rm ts (Just rng_ty)
      remoteTxns <- liftIO $ newCounter 0
      let mayIncTxn m = do
            b <- m
            when b $
              void $ liftIO $ incCounter remoteTxns
            return b
      -- Figure out what we're calling
      salloc_ "remote address" $ \storeAddr loadAddr -> do
        cContractToAddr ro
        storeAddr
        salloc_ "minb" $ \storeMinB loadMinB -> do
          cContractAddr
          op "min_balance"
          storeMinB
          -- XXX We are caching the minimum balance because if we are deleting an
          -- application we made, then our minimum balance will decrease. The
          -- alternative is to track how much exactly it will go down by.
          let mmin = Just loadMinB
          salloc_ "pre balances" $ \storeBals loadBals -> do
            let mtoksBill = Nothing : map Just nnRecv
            let mtoksiAll = zip [0..] mtoksBill
            let (mtoksiBill, mtoksiZero) = splitAt (length mtoksBill) mtoksiAll
            let paid = M.fromList $ (Nothing, pay_net) : (map (\(x, y) -> (Just y, x)) pay_ks)
            let balsT = T_Tuple $ map (const $ T_UInt UI_Word) mtoksiAll
            let gb_pre _ mtok = do
                  cGetBalance at mmin mtok
                  case M.lookup mtok paid of
                    Nothing -> return ()
                    Just amt -> do
                      cp amt
                      op "-"
            cconcatbs $ map (\(i, mtok) -> (T_UInt UI_Word, gb_pre i mtok)) mtoksiAll
            storeBals
            -- Start the call
            let mt_at = at
            let mt_mcclose = Nothing
            let mt_mrecv = Just $ Right loadAddr
            let mt_always = r_strictPay
            hadNet <- (do
              let mt_amt = pay_net
              let mt_mtok = Nothing
              let mt_next = False
              let mt_submit = False
              mayIncTxn $ makeTxn $ MakeTxn {..})
            let foldMy a l f = foldM f a l
            hadSome <- foldMy hadNet pay_ks $ \mt_next (mt_amt, tok) -> do
              let mt_mtok = Just tok
              let mt_submit = False
              x <- mayIncTxn $ makeTxn $ MakeTxn {..}
              return $ mt_next || x
            itxnNextOrBegin hadSome
            output $ TConst "appl"
            makeTxn1 "TypeEnum"
            cp ro
            incResource R_App ro
            makeTxn1 "ApplicationID"
            unless r_rawCall $ do
              cp $ sigStrToBytes sig
              makeTxn1 "ApplicationArgs"
            accountsR <- liftIO $ newCounter 1
            let processArg a = do
                  cp a
                  let t = argTypeOf a
                  ctobs t
                  case t of
                    -- XXX This is bad and will not work in most cases
                    T_Address -> do
                      incResource R_Account a
                      let m = makeTxn1 "Accounts"
                      case r_addr2acc of
                        False -> do
                          op "dup"
                          m
                        True -> do
                          i <- liftIO $ incCounter accountsR
                          m
                          cp i
                          ctobs $ T_UInt UI_Word
                    _ -> return ()
            let processArg' a = do
                  processArg a
                  makeTxn1 "ApplicationArgs"
            let processArgTuple tas = do
                  cconcatbs_ (const $ return ()) $
                    map (\a -> (argTypeOf a, processArg a)) tas
                  makeTxn1 "ApplicationArgs"
            case splitArgs as of
              (_, Nothing) -> do
                forM_ as processArg'
              (as14, Just asMore) -> do
                forM_ as14 processArg'
                processArgTuple asMore
            -- XXX If we can "inherit" resources, then this needs to be removed and
            -- we need to check that nnZeros actually stay 0
            forM_ (r_assets <> map snd pay_ks <> nnRecv) $ \a -> do
              incResource R_Asset a
              cp a
              makeTxn1 "Assets"
            forM_ r_accounts $ \a -> do
              incResource R_Account a
              cp a
              makeTxn1 "Accounts"
            forM_ r_apps $ \a -> do
              incResource R_App a
              cp a
              makeTxn1 "Applications"
            let oc f = do
                  output $ TConst f
                  makeTxn1 "OnCompletion"
            case r_oc of
              RA_NoOp -> return ()
              RA_OptIn -> oc "OptIn"
              RA_CloseOut -> oc "CloseOut"
              RA_ClearState -> oc "ClearState"
              RA_UpdateApplication -> oc "UpdateApplication"
              RA_DeleteApplication -> oc "DeleteApplication"
            op "itxn_submit"
            show_stack ("Remote: " <> sig) Nothing at fs
            appl_idx <- liftIO $ readCounter remoteTxns
            let gb_post idx mtok = do
                  cGetBalance at mmin mtok
                  loadBals
                  cTupleRef balsT idx
                  op "-"
            cconcatbs $ map (\(i, mtok) -> (T_UInt UI_Word, gb_post i mtok)) mtoksiBill
            forM_ mtoksiZero $ \(idx, mtok) -> do
              cGetBalance at mmin mtok
              loadBals
              cTupleRef balsT idx
              asserteq
            code "gitxn" [ texty appl_idx, "LastLog" ]
            output $ TExtract 4 0 -- (0 = to the end)
            op "concat"
    DLE_TokenNew at (DLTokenNew {..}) -> do
      block_ "TokenNew" $ do
        let ct_at = at
        let ct_mtok = Nothing
        let ct_amt = DLA_Literal $ minimumBalance_l
        void $ checkTxn $ CheckTxn {..}
        itxnNextOrBegin False
        let vTypeEnum = "acfg"
        output $ TConst vTypeEnum
        makeTxn1 "TypeEnum"
        cp dtn_supply >> makeTxn1 "ConfigAssetTotal"
        maybe (cint_ at 6) cp dtn_decimals >> makeTxn1 "ConfigAssetDecimals"
        cp dtn_sym >> makeTxn1 "ConfigAssetUnitName"
        cp dtn_name >> makeTxn1 "ConfigAssetName"
        cp dtn_url >> makeTxn1 "ConfigAssetURL"
        cp dtn_metadata >> makeTxn1 "ConfigAssetMetadataHash"
        cContractAddr >> makeTxn1 "ConfigAssetManager"
        op "itxn_submit"
        code "itxn" ["CreatedAssetID"]
    DLE_TokenBurn {} ->
      -- Burning does nothing on Algorand, because we already own it and we're
      -- the creator, and that's the rule for being able to destroy
      return ()
    DLE_TokenDestroy _at aida -> do
      itxnNextOrBegin False
      let vTypeEnum = "acfg"
      output $ TConst vTypeEnum
      makeTxn1 "TypeEnum"
      incResource R_Asset aida
      cp aida
      makeTxn1 "ConfigAsset"
      op "itxn_submit"
      -- XXX We could give the minimum balance back to the creator
      return ()
    DLE_TimeOrder {} -> impossible "timeorder"
    DLE_EmitLog at k vs -> do
      let internal = do
            (v, n) <- case vs of
              [v'@(DLVar _ _ _ n')] -> return (v', n')
              _ -> impossible "algo ce: Expected one value"
            clog $
              [ DLA_Literal (DLL_Int at UI_Word $ fromIntegral n)
              , DLA_Var v
              ]
            cp v
            return $ v
      case k of
        L_Internal -> void $ internal
        L_Api {} -> do
          v <- internal
          -- `internal` just pushed the value of v onto the stack.
          -- We know it is not going to be used, so we can consume it.
          -- We know that CLMemorySet will consume it and doesn't do stack
          -- manipulation, so we say that to compile it, you do a nop op, thus
          -- it will be consumed.
          store_let v True nop $
            cpk nop $ CLMemorySet at "api" (DLA_Var v)
        L_Event ml en -> do
          let name = maybe en (\l -> bunpack l <> "_" <> en) ml
          clogEvent name vs
          -- Event log values are never used, so we don't push anything
          return ()
    DLE_setApiDetails at p _ _ _ -> do
      Env {..} <- ask
      let which = fromMaybe (impossible "setApiDetails no which") eWhich
      let p' = LT.pack $ adjustApiName (LT.unpack $ apiLabel p) which True
      let lr_at = at
      let lr_lab = p'
      let lr_what = bunpack $ "API " <> p
      liftIO $ modifyIORef eApiLs $ (<>) [LabelRec {..}]
      callCompanion at $ CompanionLabel True p'
    DLE_GetUntrackedFunds at mtok tb -> do
      after_lab <- freshLabel "getActualBalance"
      cGetBalance at Nothing mtok
      -- [ bal ]
      cp tb
      -- [ bal, rsh_bal ]
      case mtok of
        Nothing -> do
          -- [ bal, rsh_bal ]
          op "-"
          -- [ extra ]
          return ()
        Just _ -> do
          cb_lab <- freshLabel $ "getUntrackedFunds" <> "_z"
          -- [ bal, rsh_bal ]
          op "dup2"
          -- [ bal, rsh_bal, bal, rsh_bal ]
          op "<"
          -- [ bal, rsh_bal, {0, 1} ]
          -- Branch IF the bal < rsh_bal
          code "bnz" [ cb_lab ]
          -- [ bal, rsh_bal ]
          op "-"
          code "b" [ after_lab ]
          -- This happens because of clawback
          label cb_lab
          -- [ bal, rsh_bal ]
          op "pop"
          -- [ bal ]
          op "pop"
          -- [  ]
          cint 0
          -- [ extra ]
          return ()
      label after_lab
    DLE_DataTag _ d -> do
      cp d
      cint 0
      op "getbyte"
    DLE_FromSome _ mo da -> do
      cp da
      cp mo
      salloc_ "fromSome object" $ \cstore cload -> do
        cstore
        cextractDataOf cload da
        cload
        cint 0
        op "getbyte"
      -- [ Default, Object, Tag ]
      -- [ False, True, Cond ]
      op "select"
    DLE_ContractFromAddress _at _addr -> do
      cp $ mdaToMaybeLA T_Contract Nothing
    DLE_ContractNew at cns dr -> do
      block_ "ContractNew" $ do
        let DLContractNew {..} = cns M.! conName'
        let ALGOCodeOut {..} = either impossible id $ aesonParse dcn_code
        let ALGOCodeOpts {..} = either impossible id $ aesonParse dcn_opts
        let ai_GlobalNumUint = aco_globalUints
        let ai_GlobalNumByteSlice = aco_globalBytes
        let ai_LocalNumUint = aco_localUints
        let ai_LocalNumByteSlice = aco_localBytes
        let ai_ExtraProgramPages =
              extraPages $ length aco_approval + length aco_clearState
        let appInfo = AppInfo {..}
        let ct_at = at
        let ct_mtok = Nothing
        let ct_amt = DLA_Literal $ DLL_Int at UI_Word $ minimumBalance_app appInfo ApplTxn_Create
        void $ checkTxn $ CheckTxn {..}
        itxnNextOrBegin False
        let vTypeEnum = "appl"
        output $ TConst vTypeEnum
        makeTxn1 "TypeEnum"
        let cbss f bs = do
              let (before, after) = B.splitAt (fromIntegral algoMaxStringSize) bs
              cp before
              makeTxn1 f
              unless (B.null after) $
                cbss f after
        cbss "ApprovalProgramPages" $ B.pack aco_approval
        cbss "ClearStateProgramPages" $ B.pack aco_clearState
        let unz f n = unless (n == 0) $ cp n >> makeTxn1 f
        unz "GlobalNumUint" $ ai_GlobalNumUint
        unz "GlobalNumByteSlice" $ ai_GlobalNumByteSlice
        unz "LocalNumUint" $ ai_LocalNumUint
        unz "LocalNumByteSlice" $ ai_LocalNumByteSlice
        unz "ExtraProgramPages" $ ai_ExtraProgramPages
        -- XXX support all of the DLRemote options
        let DLRemote _ _ as _ _ = dr
        forM_ as $ \a -> do
          cp a
          let t = argTypeOf a
          ctobs t
          makeTxn1 "ApplicationArgs"
        op "itxn_submit"
        code "itxn" ["CreatedApplicationID"]
    where
      -- On ALGO, objects are represented identically to tuples of their fields in ascending order.
      -- Consequently, we can pretend objects are tuples and use tuple functions as a shortcut.
      objectRefAsTupleRef :: DLArg -> String -> (DLType, Integer)
      objectRefAsTupleRef obj_a fieldName = (objAsTup_t, fieldIndex)
        where
          fieldIndex = objstrFieldIndex obj_t fieldName
          objAsTup_t = T_Tuple $ map snd $ objstrTypes obj_t
          obj_t = argTypeOf obj_a
      show_stack :: String -> Maybe BS.ByteString -> SrcLoc -> [SLCtxtFrame] -> App ()
      show_stack what msg at fs = do
        let msg' =
              case msg of
                Nothing -> ""
                Just x -> ": " <> x
        comment $ LT.pack $ "^ " <> what <> (bunpack msg')
        comment $ LT.pack $ "at " <> (unsafeRedactAbsStr $ show at)
        forM_ fs $ \f ->
          comment $ LT.pack $ unsafeRedactAbsStr $ show f

splitArgs :: [a] -> ([a], Maybe [a])
splitArgs l =
  -- If there are more than 15 args to an API on ALGO,
  -- args 15+ are packed as a tuple in arg 15.
  case 15 < (length l) of
    False -> (l, Nothing)
    True -> (before, Just after) where (before, after) = splitAt 14 l

signatureStr :: Bool -> String -> [DLType] -> Maybe DLType -> App String
signatureStr addr2acc f args mret = do
  args' <- mapM (typeSig_ addr2acc False) args
  rets <- fromMaybe "" <$> traverse (typeSig_ False True) mret
  return $ f <> "(" <> intercalate "," args' <> ")" <> rets

sigStrToBytes :: String -> BS.ByteString
sigStrToBytes sig = shabs
  where
    sha = hashWith SHA512t_256 $ bpack sig
    shabs = BS.take 4 $ BA.convert sha

clogEvent :: String -> [DLVar] -> App ()
clogEvent eventName vs = do
  sigStr <- signatureStr False eventName (map varType vs) Nothing
  let as = map DLA_Var vs
  let cheader = cp (bpack sigStr) >> op "sha512_256" >> output (TSubstring 0 4)
  cconcatbs $ (T_Bytes 4, cheader) : map (\a -> (argTypeOf a, cp a)) as
  sz <- typeSizeOf $ largeArgTypeOf $ DLLA_Tuple as
  clog_ $ 4 + sz
  comment $ LT.pack $ "^ log: " <> show eventName <> " " <> show vs <> " " <> show sigStr

clog_ :: Integer -> App ()
clog_ = output . TLog

clog :: [DLArg] -> App ()
clog as = do
  let la = DLLA_Tuple as
  cp la
  sz <- typeSizeOf $ largeArgTypeOf la
  clog_ sz

data CheckTxn = CheckTxn
  { ct_at :: SrcLoc
  , ct_amt :: DLArg
  , ct_mtok :: Maybe DLArg
  }

data MakeTxn = MakeTxn
  { mt_at :: SrcLoc
  , mt_mrecv :: Maybe (Either DLArg (App ()))
  , mt_mcclose :: Maybe (App ())
  , mt_amt :: DLArg
  , mt_always :: Bool
  , mt_mtok :: Maybe DLArg
  , mt_next :: Bool
  , mt_submit :: Bool
  }

makeTxn1 :: LT.Text -> App ()
makeTxn1 f = code "itxn_field" [f]

checkTxnUsage_ :: (DLArg -> App Bool) -> AlgoError -> SrcLoc -> Maybe DLArg -> App ()
checkTxnUsage_ isXTok err at mtok = do
  case mtok of
    Just tok -> do
      x <- isXTok tok
      when x $ do
        bad $ LT.pack $ getErrorMessage [] at True err
    Nothing -> return ()

makeTxnUsage :: SrcLoc -> Maybe DLArg -> App ()
makeTxnUsage = checkTxnUsage_ isNewTok Err_TransferNewToken

checkTxnUsage :: SrcLoc -> Maybe DLArg -> App ()
checkTxnUsage = checkTxnUsage_ isInitTok Err_PayNewToken

ntokFields :: (LT.Text, LT.Text, LT.Text, LT.Text)
ntokFields = ("pay", "Receiver", "Amount", "CloseRemainderTo")

tokFields :: (LT.Text, LT.Text, LT.Text, LT.Text)
tokFields = ("axfer", "AssetReceiver", "AssetAmount", "AssetCloseTo")

checkTxn_lib :: Bool -> App ()
checkTxn_lib tok = do
  let lf = if tok then LF_checkTxn_tok else LF_checkTxn_net
  libCall lf $ do
    let get1 f = code "gtxns" [f]
    let (vTypeEnum, fReceiver, fAmount, _fCloseTo) =
          if tok then tokFields else ntokFields
    -- init: False: [ amt ]
    -- init:  True: [ amt, tok ]
    useResource R_Txn
    gvLoad GV_txnCounter
    dupn $ 3 + (if tok then 1 else 0)
    cint 1
    op "+"
    gvStore GV_txnCounter
    -- init <> [ id, id, id, id? ]
    get1 fReceiver
    cContractAddr
    cfrombs T_Address
    asserteq
    get1 "TypeEnum"
    output $ TConst vTypeEnum
    asserteq
    -- init <> [ id, id? ]
    when tok $ do
      get1 "XferAsset"
      code "uncover" [ "2" ]
      asserteq
    get1 fAmount
    asserteq
    op "retsub"

checkTxn :: CheckTxn -> App Bool
checkTxn (CheckTxn {..}) =
  case staticZero ct_amt of
    True -> return False
    False -> block_ "checkTxn" $ do
      checkTxnUsage ct_at ct_mtok
      cp ct_amt
      case ct_mtok of
        Nothing -> do
          checkTxn_lib False
        Just tok -> do
          cp tok
          checkTxn_lib True
      return True

itxnNextOrBegin :: Bool -> App ()
itxnNextOrBegin isNext = do
  op (if isNext then "itxn_next" else "itxn_begin")
  -- We do this because by default it will inspect the remaining fee and only
  -- set it to zero if there is a surplus, which means that sometimes it means
  -- 0 and sometimes it means "take money from the escrow", which is dangerous,
  -- so we force it to be 0 here. The alternative would be to check that other
  -- fees were set correctly, but I believe that would be more annoying to
  -- track, so I don't.
  cint 0
  makeTxn1 "Fee"

makeTxn :: MakeTxn -> App Bool
makeTxn (MakeTxn {..}) =
  case (mt_always || not (staticZero mt_amt)) of
    False -> return False
    True -> block_ "makeTxn" $ do
      let ((vTypeEnum, fReceiver, fAmount, fCloseTo), extra) =
            case mt_mtok of
              Nothing ->
                (ntokFields, return ())
              Just tok ->
                (tokFields, textra)
                where
                  textra = do
                    incResource R_Asset tok
                    cp tok
                    makeTxn1 "XferAsset"
      makeTxnUsage mt_at mt_mtok
      itxnNextOrBegin mt_next
      cp mt_amt
      makeTxn1 fAmount
      output $ TConst vTypeEnum
      makeTxn1 "TypeEnum"
      whenJust mt_mcclose $ \cclose -> do
        cclose
        cfrombs T_Address
        makeTxn1 fCloseTo
      case mt_mrecv of
        Nothing -> cContractAddr
        Just (Left a) -> do
          incResource R_Account a
          cp a
        Just (Right cr) -> cr
      cfrombs T_Address
      makeTxn1 fReceiver
      extra
      when mt_submit $ op "itxn_submit"
      return True

cextractDataOf :: App () -> DLArg -> App ()
cextractDataOf cd va = do
  let vt = argTypeOf va
  sz <- typeSizeOf vt
  case sz == 0 of
    True -> padding 0
    False -> do
      cd
      cextract 1 sz
      cfrombs vt

cmatch :: (Compile a) => App () -> [(BS.ByteString, a)] -> App ()
cmatch ca es = do
  code "pushbytess" $ map (base64d . fst) es
  ca
  cswatchTail "match" (map snd es) cp

cswatchTail :: TealOp -> [a] -> (a -> App ()) -> App ()
cswatchTail w es ce = do
  els <- forM es $ \e -> do
    l <- freshLabel "swatch"
    return (e, l)
  code w $ map snd els
  op "err"
  forM_ els $ \(e, l) -> label l >> ce e

doSwitch :: String -> (a -> App ()) -> DLVar -> SwitchCases a -> App ()
doSwitch lab ck dv csm = do
  let go cload = do
        cload
        cint 0
        op "getbyte"
        cswatchTail "switch" (M.toAscList csm) $ \(vn, (vv, vu, k)) -> do
          l <- freshLabel $ lab <> "_" <> vn
          block l $
            case vu of
              False -> ck k
              True -> do
                flip (sallocLet vv) (ck k) $ do
                  cextractDataOf cload (DLA_Var vv)
  letSmall dv >>= \case
    True -> go (cp dv)
    False -> do
      salloc_ (textyv dv <> " for switch") $ \cstore cload -> do
        cp dv
        cstore
        go cload

instance CompileK DLStmt where
  cpk km = \case
    DL_Nop _ -> km
    DL_Let _ DLV_Eff de ->
      -- XXX this could leave something on the stack
      cp de >> km
    DL_Let _ (DLV_Let vc dv) de -> do
      sm <- exprSmall de
      recordNew <-
        case de of
          DLE_TokenNew {} -> do
            return True
          DLE_EmitLog _ _ [dv'] -> do
            isNewTok $ DLA_Var dv'
          _ -> do
            return False
      when recordNew $
        addNewTok $ DLA_Var dv
      sallocVarLet (DLVarLet (Just vc) dv) sm (cp de) km
    DL_ArrayMap at ansv as xs iv (DLBlock _ _ body ra) -> do
      anssz <- typeSizeOf $ argTypeOf $ DLA_Var ansv
      let xlen = arraysLength as
      let rt = argTypeOf ra
      check_concat_len anssz
      salloc_ (textyv ansv) $ \store_ans load_ans -> do
        cbs ""
        store_ans
        cfor xlen $ \load_idx -> do
          load_ans
          let finalK = cpk (cp ra >> ctobs rt) body
          let bodyF (x, a) k = do
               doArrayRef at a True $ Right load_idx
               sallocLet x (return ()) $
                 store_let iv True load_idx $
                 k
          foldr bodyF finalK $ zip xs as
          op "concat"
          store_ans
        store_let ansv True load_ans km
    DL_ArrayReduce at ansv as za av xs iv (DLBlock _ _ body ra) -> do
      let xlen = arraysLength as
      salloc_ (textyv ansv) $ \store_ans load_ans -> do
        cp za
        store_ans
        store_let av True load_ans $ do
          cfor xlen $ \load_idx -> do
            let finalK = cpk (cp ra) body
            let bodyF (x, a) k = do
                 doArrayRef at a True $ Right load_idx
                 sallocLet x (return ()) $
                   store_let iv True load_idx $
                   k
            foldr bodyF finalK $ zip xs as
            store_ans
          store_let ansv True load_ans km
    DL_Var _ dv ->
      salloc $ \loc -> do
        store_var dv loc $
          store_let dv True (output $ TLoad loc (textyv dv)) $
            km
    DL_Set _ dv da -> do
      loc <- lookup_var dv
      cp da
      output $ TStore loc (textyv dv)
      km
    DL_LocalIf _ _ a tp fp -> do
      cp a
      false_lab <- freshLabel "localIfF"
      join_lab <- freshLabel "localIfK"
      code "bz" [false_lab]
      let j = code "b" [join_lab]
      cpk j tp
      label false_lab
      cpk j fp
      label join_lab
      km
    DL_LocalSwitch _ dv csm -> do
      end_lab <- freshLabel $ "LocalSwitchK"
      doSwitch "LocalSwitch" (cpk (code "b" [end_lab])) dv csm
      label end_lab
      km
    DL_MapReduce {} ->
      impossible $ "cannot inspect maps at runtime"
    DL_Only {} ->
      impossible $ "only in CP"
    DL_LocalDo _ _ t -> cpk km t

instance CompileK DLTail where
  cpk km = \case
    DT_Return _ -> km
    DT_Com m k -> cpk (cpk km k) m

-- Reach Constants
reachAlgoBackendVersion :: Int
reachAlgoBackendVersion = 12

-- State:
keyState :: B.ByteString
keyState = ""

keyVary :: Word8 -> B.ByteString
keyVary = B.singleton . BI.w2c

cContractAddr :: App ()
cContractAddr = code "global" ["CurrentApplicationAddress"]

cDeployer :: App ()
cDeployer = code "global" ["CreatorAddress"]

data GlobalVar
  = GV_txnCounter
  | GV_currentStep
  | GV_currentTime
  | GV_svs
  | GV_wasMeth
  | GV_apiRet
  | GV_companion
  deriving (Eq, Ord, Show, Enum, Bounded)

gvSlot :: GlobalVar -> ScratchSlot
gvSlot ai = fromIntegral $ fromEnum ai

gvOutput :: (ScratchSlot -> LT.Text -> TEAL) -> GlobalVar -> App ()
gvOutput f gv = output $ f (gvSlot gv) (textyt gv (gvType gv))

gvStore :: GlobalVar -> App ()
gvStore = gvOutput TStore

gvLoad :: GlobalVar -> App ()
gvLoad = gvOutput TLoad

gvType :: GlobalVar -> DLType
gvType = \case
  GV_txnCounter -> T_UInt UI_Word
  GV_currentStep -> T_UInt UI_Word
  GV_currentTime -> T_UInt UI_Word
  GV_companion -> T_Contract
  GV_svs -> T_Null
  GV_wasMeth -> T_Bool
  GV_apiRet -> T_Null

defn_fixed :: Label -> Bool -> App ()
defn_fixed l b = do
  label l
  cp b
  op "return"

defn_done :: App ()
defn_done = defn_fixed "done" True

cRound :: App ()
cRound = code "global" ["Round"]

apiLabel :: SLPart -> Label
apiLabel w = "api_" <> (LT.pack $ bunpack w)

bindFromSvs :: SrcLoc -> [DLVarLet] -> App a -> App a
bindFromSvs at svs m = do
  sz <- typeSizeOf $ T_Tuple $ map varLetType svs
  let ensure = cSvsLoad $ sz
  bindFromGV GV_svs ensure at svs m

bindFromGV :: GlobalVar -> App () -> SrcLoc -> [DLVarLet] -> App a -> App a
bindFromGV gv ensure at vls m = do
  let notNothing = \case
        DLVarLet (Just _) _ -> True
        _ -> False
  case any notNothing vls of
    False -> m
    True -> do
      av <- allocVar at $ T_Tuple $ map varLetType vls
      av_dup <- allocVar at $ T_Tuple $ map varLetType vls
      ensure
      -- This relies on knowing what sallocVarLet will do
      let shouldDup (DLVarLet mvc _) =
            case mvc of
              Nothing -> False
              Just DVC_Once -> False
              Just DVC_Many -> True
      let howManyDups = count shouldDup vls
      when (howManyDups > 0) $ do
        gvLoad gv
        -- we just did the load, that's one
        dupn $ howManyDups - 1
      let go = \case
            [] -> m
            (dv, i) : more -> sallocVarLet dv False cgen $ go more
              where
                which_av = if shouldDup dv then av_dup else av
                cgen = cp $ DLE_TupleRef at (DLA_Var which_av) i
      store_let av True (gvLoad gv) $
        store_let av_dup True (return ()) $
          go $ zip vls [0 ..]

data CompanionCall
  = CompanionCreate
  | CompanionLabel Bool Label
  | CompanionDelete
  | CompanionDeletePre
  | CompanionGet
  deriving (Eq, Show)
callCompanion :: SrcLoc -> CompanionCall -> App ()
callCompanion at cc = do
  mcr <- asks eCompanion
  CompanionRec {..} <- asks eCompanionRec
  let credit = output . TCostCredit
  let startCall ctor del = do
        itxnNextOrBegin False
        output $ TConst "appl"
        makeTxn1 "TypeEnum"
        case ctor of
          True -> do
            cint_ at 0
            incResource R_App $ DLA_Literal $ DLL_Int at UI_Word 0
            freeResource R_App $ cr_ro
          False -> do
            cp cr_ro
            unless del $ do
              incResource R_App cr_ro
        makeTxn1 "ApplicationID"
  comment $ texty cc
  case cc of
    CompanionGet -> do
      let t = T_Contract
      let go = cp . mdaToMaybeLA t
      case mcr of
        Nothing -> go Nothing
        Just _ -> do
          dv <- allocVar at t
          sallocLet dv (gvLoad GV_companion) $
            go $ Just $ DLA_Var dv
    CompanionCreate -> do
      let mpay pc = cp $ DLE_CheckPay at [] (DLA_Literal $ DLL_Int at UI_Word $ pc * algoMinimumBalance) Nothing
      case mcr of
        Nothing -> do
          mpay 1
        Just _ -> do
          mpay 2
          startCall True False
          cp cr_approval
          makeTxn1 "ApprovalProgram"
          cp cr_clearstate
          makeTxn1 "ClearStateProgram"
          op "itxn_submit"
          credit cr_ctor
          code "itxn" ["CreatedApplicationID"]
          gvStore GV_companion
          return ()
    CompanionLabel mk l -> do
      when mk $ label l
      whenJust mcr $ \cim -> do
        let howManyCalls = fromMaybe 0 $ M.lookup l cim
        -- XXX bunch into groups of 16, slightly less cost
        cfor howManyCalls $ const $ do
          startCall False False
          op "itxn_submit"
          credit cr_call
        return ()
    CompanionDelete ->
      whenJust mcr $ \_ -> do
        startCall False True
        output $ TConst $ "DeleteApplication"
        makeTxn1 "OnCompletion"
        op "itxn_submit"
        credit cr_del
        return ()
    CompanionDeletePre ->
      whenJust mcr $ \_ -> do
        incResource R_App cr_ro

getMapTy :: DLMVar -> App DLType
getMapTy mpv = do
  ms <- pMaps <$> asks ePre
  return $
    case M.lookup mpv ms of
      Nothing -> impossible "getMapTy"
      Just mi -> dlmi_ty mi

mapDataTy :: DLMapInfos -> DLType
mapDataTy m = T_Tuple $ map (dlmi_tym . snd) $ M.toAscList m

getMapDataTy :: App DLType
getMapDataTy = asks eMapDataTy

cStateSlice :: Integer -> Word8 -> App ()
cStateSlice size iw = do
  let i = fromIntegral iw
  let k = algoMaxAppBytesValueLen_usable
  let s = k * i
  let e = min size $ k * (i + 1)
  cextract s (e - s)

compileTEAL_ :: String -> IO (Either BS.ByteString BS.ByteString)
compileTEAL_ tealf = do
  (ec, stdout, stderr) <- readProcessWithExitCode "goal" ["clerk", "compile", tealf, "-o", "-"] mempty
  case ec of
    ExitFailure _ -> return $ Left stderr
    ExitSuccess -> return $ Right stdout

compileTEAL :: String -> IO BS.ByteString
compileTEAL tealf = compileTEAL_ tealf >>= \case
  Left stderr -> do
    let failed = impossible $ "The TEAL compiler failed with the message:\n" <> show stderr
    let tooBig = bpack tealf <> ": app program size too large: "
    case BS.isPrefixOf tooBig stderr of
      True -> do
        let notSpace = (32 /=)
        let sz_bs = BS.takeWhile notSpace $ BS.drop (BS.length tooBig) stderr
        let mlen :: Maybe Int = readMaybe $ bunpack sz_bs
        case mlen of
          Nothing -> failed
          Just sz -> return $ BS.replicate sz 0
      False -> failed
  Right stdout -> return stdout

class HasPre a where
  getPre :: a -> Pre

-- CL Case
instance CompileK CLStmt where
  cpk k = \case
    CLDL m -> cpk k m
    CLTxnBind _ from timev secsv -> do
      freeResource R_Account $ DLA_Var from
      store_let from True (code "txn" ["Sender"]) $
        store_let timev True cRound $
          store_let secsv True (code "global" ["LatestTimestamp"]) $
            k
    CLTimeCheck _ given -> do
      cp given
      op "dup"
      cint 0
      op "=="
      op "swap"
      gvLoad GV_currentTime
      op "=="
      op "||"
      assert
      k
    CLEmitPublish _ which vars -> do
      clogEvent ("_reach_e" <> show which) vars >> k
    CLStateRead _ v -> do
      store_let v True (gvLoad GV_currentStep) k
    CLStateBind at isSafe svs_vl prev -> do
      unless isSafe $ do
        cp prev
        gvLoad GV_currentStep
        asserteq
      bindFromSvs at svs_vl k
    CLIntervalCheck _ timev secsv (CBetween ifrom ito) -> do
      let checkTime1 :: LT.Text -> App () -> DLArg -> App ()
          checkTime1 cmp clhs rhsa = do
            clhs
            cp rhsa
            op cmp
            assert
      let checkFrom_ = checkTime1 ">="
      let checkTo_ = checkTime1 "<"
      let makeCheck check_ = \case
            Left x -> check_ (cp timev) x
            Right x -> check_ (cp secsv) x
      let checkFrom = makeCheck checkFrom_
      let checkTo = makeCheck checkTo_
      let checkBoth v xx yy = do
            cp v
            checkFrom_ (op "dup") xx
            checkTo_ (return ()) yy
      case (ifrom, ito) of
        (Nothing, Nothing) -> return ()
        (Just x, Nothing) -> checkFrom x
        (Nothing, Just y) -> checkTo y
        (Just x, Just y) ->
          case (x, y) of
            (Left xx, Left yy) -> checkBoth timev xx yy
            (Right xx, Right yy) -> checkBoth secsv xx yy
            (_, _) -> checkFrom x >> checkFrom y
      k
    CLStateSet at which svs -> do
      cSvsSave at $ map snd svs
      cp which
      gvStore GV_currentStep
      cRound
      gvStore GV_currentTime
      k
    CLTokenUntrack at tok -> do
      let mt_at = at
      let mt_always = True
      let mt_mrecv = Nothing
      let mt_submit = True
      let mt_next = False
      let mt_mcclose = Just $ cDeployer
      let mt_amt = DLA_Literal $ DLL_Int at UI_Word 0
      let mt_mtok = Just tok
      void $ makeTxn $ MakeTxn {..}
      k
    CLMemorySet _ _ a -> do
      cp a
      ctobs $ argTypeOf a
      gvStore GV_apiRet
      k

instance Compile CLTail where
  cp = \case
    CL_Com m k -> cpk (cp k) m
    CL_If _ a tt ft -> do
      cp a
      false_lab <- freshLabel "ifF"
      code "bz" [false_lab]
      nct tt
      label false_lab
      nct ft
    CL_Switch _ dv csm ->
      doSwitch "Switch" nct dv csm
    CL_Jump _at f args isApi _mmret -> do
      case isApi of
        True -> cp $ DLLA_Tuple $ map DLA_Var args
        False -> mapM_ cp args
      code "b" [ LT.pack $ bunpack f]
    CL_Halt at ht ->
      case ht of
        HM_Pure -> code "b" ["apiReturn_check"]
        HM_Impure -> code "b" ["updateStateNoOp"]
        HM_Forever -> do
          callCompanion at $ CompanionDeletePre
          code "b" ["updateStateHalt"]
    where
      nct = dupeResources . cp

symToSig :: CLSym -> App String
symToSig (CLSym f d r) = signatureStr False (bunpack f) d (Just r)

sigToLab :: String -> CLExtKind -> LT.Text
sigToLab x = \case
  CE_Publish n -> LT.pack $ "_reachp_" <> show n
  _ -> LT.pack $ map go final
    where
      final = take 16 x <> hashed
      hashed = B.unpack $ encodeBase64' $ sha256bs $ B.pack x
      go :: Char -> Char
      go c =
        case isAlphaNum c of
          True -> c
          False -> '_'

data CLFX = CLFX LT.Text (Maybe Int) CLFun
data CLEX = CLEX String CLExtFun
data CLIX = CLIX CLVar CLIntFun

instance Compile CLFX where
  cp (CLFX lab mwhich (CLFun {..})) = recordWhich mwhich $ do
    let at = clf_at
    callCompanion at $ CompanionLabel False lab
    cp clf_tail

instance Compile CLIX where
  cp (CLIX n (CLIntFun {..})) = do
    let CLFun {..} = cif_fun
    let lab = LT.pack $ bunpack n
    block_ lab $ do
      label lab
      bindFromStack clf_dom $
        cp $ CLFX lab cif_mwhich cif_fun

bindFromStack :: [DLVarLet] -> App a -> App a
bindFromStack vsl m = do
  -- STACK: [ ...vs ] TOP on right
  let go m' v = sallocLet v (return ()) m'
  -- The 'l' is important here because it means we're nesting the computation
  -- from the left, so the bindings match the (reverse) push order
  foldl' go m $ map varLetVar vsl

checkArgSize :: String -> SrcLoc -> [DLVarLet] -> App ()
checkArgSize lab at msg = do
  -- The extra 4 bytes are the selector
  argSize <- (+) 4 <$> (typeSizeOf $ T_Tuple $ map (varType . varLetVar) msg)
  when (argSize > algoMaxAppTotalArgLen) $
    bad $ LT.pack $
      lab <> "'s argument length is " <> show argSize
      <> ", but the limit is " <> show algoMaxAppTotalArgLen
      <> ". " <> lab <> " starts at " <> show at <> "."

bindFromArgs :: [DLVarLet] -> App a -> App a
bindFromArgs vs m = do
  let goSingle (v, i) = sallocVarLet v False (code "txna" ["ApplicationArgs", texty i] >> cfrombs (varLetType v))
  let goSingles singles k = foldl' (flip goSingle) k (zip singles [(1 :: Integer) ..])
  case splitArgs vs of
    (vs', Nothing) -> do
      goSingles vs' m
    (vs14, Just vsMore) -> do
      let tupleTy = T_Tuple $ map varLetType vsMore
      let goTuple (v, i) = sallocVarLet v False
            (code "txna" ["ApplicationArgs", texty (15 :: Integer)]
             >> cTupleRef tupleTy i)
      goSingles vs14 (foldl' (flip goTuple) m (zip vsMore [(0 :: Integer) ..]))

instance Compile CLEX where
  cp (CLEX sig (CLExtFun {..})) = do
    let CLFun {..} = cef_fun
    let at = clf_at
    let lab = sigToLab sig cef_kind
    checkArgSize (show $ pretty cef_kind) at $ clf_dom
    let mwhich = case cef_kind of
                   CE_Publish n -> Just n
                   _ -> Nothing
    let isMeth = cp True >> gvStore GV_wasMeth
    block_ lab $ do
      label lab
      case cef_kind of
        CE_Publish 0 -> callCompanion at $ CompanionCreate
        CE_Publish _ -> return ()
        CE_View {} -> isMeth
        CE_API {} -> isMeth
      bindFromArgs clf_dom $
        cp $ CLFX lab mwhich cef_fun

instance HasPre CLProg where
  getPre (CLProg {..}) = Pre {..}
    where
      pMaps = clp_maps

instance Compile CLProg where
  cp (CLProg {..}) = do
    Env {..} <- ask
    let sig_go (sym, f) = do
          sig <- symToSig sym
          return (sig, (CLEX sig f))
    sig_api <- M.fromList <$> (mapM sig_go $ M.toAscList clp_api)
    let mkABI (CLEX _ (CLExtFun {..})) = ABInfo {..}
          where
            abiPure = clf_view cef_fun
    liftIO $ writeIORef eABI $ M.map mkABI sig_api
    let apiret_go (CLEX _ (CLExtFun {..})) = cef_rng
    maxApiRetSize <- maxTypeSize $ M.map apiret_go sig_api
    liftIO $ writeIORef eMaxApiRetSize maxApiRetSize
    liftIO $ writeIORef eApiLs $ []
    -- This is where the actual code starts
    -- We branch on the method
    label "preamble"
    let getMeth = code "txna" ["ApplicationArgs", "0"]
    cmatch getMeth $ M.toAscList $ M.mapKeys sigStrToBytes sig_api
    -- Now we dump the implementation of internal functions
    mapM_ (cp . uncurry CLIX) $ M.toAscList clp_funs
    -- After looking at the code, we learned about the APIs
    let mkRec :: CLEX -> LabelRec
        mkRec (CLEX sig (CLExtFun {..})) = LabelRec {..}
          where
            CLFun {..} = cef_fun
            lr_at = clf_at
            lr_lab = sigToLab sig cef_kind
            lr_what = show $ pretty cef_kind
    apiLs <- liftIO $ readIORef eApiLs
    let pub_go e@(CLEX _ (CLExtFun {..})) =
          case cef_kind of
            CE_Publish {} -> Just $ mkRec e
            _ -> Nothing
    let pubLs = mapMaybe pub_go $ M.elems sig_api
    liftIO $ writeIORef eProgLs $ Just $ pubLs <> apiLs

-- General Shell
cp_shell :: (Compile a) => a -> App ()
cp_shell x = do
  Env {..} <- ask
  let mGV_companion =
        case eCompanion of
          Nothing -> []
          Just _ -> [GV_companion]
  let keyState_gvs :: [GlobalVar]
      keyState_gvs = [GV_currentStep, GV_currentTime] <> mGV_companion
  let keyState_ty :: DLType
      keyState_ty = T_Tuple $ map gvType keyState_gvs
  useResource R_Txn
  cint 0
  gvStore GV_txnCounter
  code "txn" ["ApplicationID"]
  code "bz" ["alloc"]
  cp keyState
  op "app_global_get"
  let nats = [0 ..]
  let shouldDups = reverse $ zipWith (\_ i -> i /= 0) keyState_gvs nats
  forM_ (zip (zip keyState_gvs shouldDups) nats) $ \((gv, shouldDup), i) -> do
    when shouldDup $ op "dup"
    cTupleRef keyState_ty i
    gvStore gv
  unless (null eMapKeysl) $ do
    -- NOTE We could allow an OptIn if we are not going to halt
    code "txn" ["OnCompletion"]
    output $ TConst "OptIn"
    op "=="
    code "bz" ["normal"]
    output $ TCheckOnCompletion
    code "txn" ["Sender"]
    cMapStore $ padding eMapDataSize
    code "b" ["checkSize"]
    -- The NON-OptIn case:
    label "normal"
  cp x
  label "updateStateHalt"
  code "txn" ["OnCompletion"]
  output $ TConst $ "DeleteApplication"
  asserteq
  output $ TCheckOnCompletion
  callCompanion sb $ CompanionDelete
  do
    let mt_at = sb
    let mt_always = True
    let mt_mrecv = Nothing
    let mt_mtok = Nothing
    let mt_submit = True
    let mt_next = False
    let mt_mcclose = Just $ cDeployer
    let mt_amt = DLA_Literal $ DLL_Int sb UI_Word 0
    void $ makeTxn $ MakeTxn {..}
  code "b" ["updateState"]
  label "updateStateNoOp"
  code "txn" ["OnCompletion"]
  output $ TConst $ "NoOp"
  asserteq
  output $ TCheckOnCompletion
  code "b" ["updateState"]
  label "updateState"
  cp keyState
  forM_ keyState_gvs $ \gv -> do
    gvLoad gv
    ctobs $ gvType gv
  forM_ (tail keyState_gvs) $ const $ op "concat"
  op "app_global_put"
  gvLoad GV_wasMeth
  code "bz" ["checkSize"]
  label "apiReturn_noCheck"
  -- SHA-512/256("return")[0..4] = 0x151f7c75
  cp $ BS.pack [0x15, 0x1f, 0x7c, 0x75]
  gvLoad GV_apiRet
  op "concat"
  maxApiRetSize <- liftIO $ readIORef eMaxApiRetSize
  clog_ $ 4 + maxApiRetSize
  code "b" ["checkSize"]
  label "checkSize"
  gvLoad GV_txnCounter
  op "dup"
  -- The size is correct
  cint 1
  op "+"
  code "global" ["GroupSize"]
  asserteq
  -- We're last
  code "txn" ["GroupIndex"]
  asserteq
  code "b" ["done"]
  defn_done
  label "apiReturn_check"
  code "txn" ["OnCompletion"]
  -- XXX A remote Reach API could have an `OnCompletion` of `DeleteApplication` due to `updateStateHalt`.
  output $ TConst "NoOp"
  asserteq
  output $ TCheckOnCompletion
  code "b" [ "apiReturn_noCheck" ]
  label "alloc"
  let ctf f v = do
        insertResult (LT.toStrict f) $ AS.Number $ fromIntegral v
        cp v
        code "txn" [f]
        asserteq
  ctf "GlobalNumUint" $ appGlobalStateNumUInt
  stateKeys <- liftIO $ eGetStateKeys
  ctf "GlobalNumByteSlice" $ appGlobalStateNumBytes + fromIntegral stateKeys
  ctf "LocalNumUint" $ appLocalStateNumUInt
  let mapDataKeys = length eMapKeysl
  ctf "LocalNumByteSlice" $ appLocalStateNumBytes + fromIntegral mapDataKeys
  forM_ keyState_gvs $ \gv -> do
    ctzero $ gvType gv
    gvStore gv
  code "b" ["updateStateNoOp"]
  -- Library functions
  libDefns

compile_algo :: (HasUntrustworthyMaps a, HasCounter a, Compile a, HasPre a) => Outputer -> a -> IO ConnectorInfo
compile_algo disp x = do
  -- This is the final result
  eRes <- newIORef mempty
  totalLenR <- newIORef (0 :: Integer)
  let compileProg :: String -> [TEAL] -> IO BS.ByteString
      compileProg lab ts' = do
        t <- renderOut ts'
        tf <- mustOutput disp (T.pack lab <> ".teal") $ flip TIO.writeFile t
        bc <- compileTEAL tf
        Verify.run lab bc [gvSlot GV_svs, gvSlot GV_apiRet]
        return bc
  let addProg lab ts' = do
        tbs <- compileProg lab ts'
        modifyIORef totalLenR $ (+) (fromIntegral $ BS.length tbs)
        let tc = LT.toStrict $ encodeBase64 tbs
        modifyIORef eRes $ M.insert (T.pack lab) $ AS.String tc
        return tbs
  -- Clear state is never allowed
  cr_clearstate <- addProg "appClear" []
  -- Companion
  let makeCompanionMaker = do
        let ts =
              [ TCode "txn" [ "Sender" ]
              , TCode "global" [ "CreatorAddress" ]
              , TCode "==" []
              ]
        let cr_ctor = fromIntegral $ length ts
        let cr_call = cr_ctor
        let cr_del = cr_call
        cr_approval <- compileProg "appCompanion" ts
        return $ \cr_rv -> do
          let cr_ro = DLA_Var cr_rv
          return $ CompanionRec {..}
  companionCache <- newIORef $ Nothing
  let readCompanionCache = do
        c <- readIORef companionCache
        case c of
          Just y -> return y
          Nothing -> do
            y <- makeCompanionMaker
            writeIORef companionCache $ Just y
            return y
  -- We start doing real work
  (gFailuresR, gbad) <- newErrorSetRef
  (gWarningsR, gwarn) <- newErrorSetRef
  let ePre = getPre x
  let Pre {..} = ePre
  -- XXX remove this once we have boxes
  forM_ pMaps $ \DLMapInfo {..} -> do
    unless (dlmi_kt == T_Address) $ do
      gbad $ LT.pack $ "Cannot use '" <> show dlmi_kt <> "' as Map key. Only 'Address' keys are allowed."
  let eMapDataTy = mapDataTy pMaps
  eMapDataSize <- typeSizeOf__ gbad eMapDataTy
  let eSP = 255
  let eVars = mempty
  let eLets = mempty
  let eLetSmalls = mempty
  let eWhich = Nothing
  let recordSize prefix size = do
        modifyIORef eRes $
          M.insert (prefix <> "Size") $
            AS.Number $ fromIntegral size
  let recordSizeAndKeys :: NotifyF -> T.Text -> Integer -> Integer -> IO [Word8]
      recordSizeAndKeys badx prefix size limit = do
        (keys, keysl) <- computeStateSizeAndKeys badx (LT.fromStrict prefix) size limit
        recordSize prefix size
        modifyIORef eRes $
          M.insert (prefix <> "Keys") $
            AS.Number $ fromIntegral keys
        return $ keysl
  eMapKeysl <- recordSizeAndKeys gbad "mapData" eMapDataSize algoMaxLocalSchemaEntries_usable
  unless (getUntrustworthyMaps x || null eMapKeysl) $ do
    gwarn $ "This program was compiled with trustworthy maps, but maps are not trustworthy on Algorand, because they are represented with local state. A user can delete their local state at any time, by sending a ClearState transaction. The only way to use local state properly on Algorand is to ensure that a user doing this can only 'hurt' themselves and not the entire system."
  eABI <- newIORef mempty
  eProgLs <- newIORef mempty
  eApiLs <- newIORef mempty
  eMaxApiRetSize <- newIORef 0
  let run :: CompanionInfo -> App () -> IO (TEALs, Notify, IO ())
      run eCompanion m = do
        let eHP_ = fromIntegral $ fromEnum (maxBound :: GlobalVar)
        let eHP =
              case eCompanion of
                Nothing -> eHP_ - 1
                Just _ -> eHP_
        eCounter <- dupeCounter $ getCounter x
        eStateSizeR <- newIORef 0
        eLabel <- newCounter 0
        eOutputR <- newIORef mempty
        eNewToks <- newIORef mempty
        eInitToks <- newIORef mempty
        eResources <- newResources
        (eFailuresR, lbad) <- newErrorSetRef
        (eWarningsR, lwarn) <- newErrorSetRef
        let finalize = do
              mergeIORef gFailuresR S.union eFailuresR
              mergeIORef gWarningsR S.union eWarningsR
        companionMaker <- readCompanionCache
        cr_rv <- allocVar_ eCounter sb T_Contract
        eCompanionRec <- companionMaker cr_rv
        eLibrary <- newIORef mempty
        let eGetStateKeys = do
              stateSize <- readIORef eStateSizeR
              l <- recordSizeAndKeys lbad "state" stateSize algoMaxGlobalSchemaEntries_usable
              return $ length l
        flip runReaderT (Env {..}) $
          store_let cr_rv True (gvLoad GV_companion) $
            m
        void $ eGetStateKeys
        ts <- readIORef eOutputR
        let notify b = if b then lbad else lwarn
        return (ts, notify, finalize)
  let showCost = unsafeDebug
  do
    let lab = "appApproval"
    let rec r inclAll ci = do
          let r' = r + 1
          let rlab = "ALGO." <> show r
          loud $ rlab <> " run"
          (ts, notify, finalize) <- run ci $ cp_shell x
          loud $ rlab <> " optimize"
          let !ts' = optimize $ DL.toList ts
          progLs <- readIORef eProgLs
          apiLs <- readIORef eApiLs
          let mls = if inclAll then progLs else Just apiLs
          let ls = fromMaybe (impossible "prog labels") mls
          loud $ rlab <> " check"
          let disp' = wrapOutput (T.pack lab) disp
          checkCost rlab notify disp' ls ci ts' >>= \case
            Right ci' -> rec r' inclAll ci'
            Left msg ->
              case inclAll of
                False -> rec r' True ci
                True -> do
                  finalize
                  when showCost $ putStr msg
                  modifyIORef eRes $ M.insert "companionInfo" (AS.toJSON ci)
                  return ts'
    void $ addProg lab =<< rec (0::Integer) False Nothing
  totalLen <- readIORef totalLenR
  when showCost $
    putStrLn $ "The program is " <> show totalLen <> " bytes."
  unless (totalLen <= algoMaxAppProgramLen_really) $ do
    gbad $ LT.pack $ "The program is too long; its length is " <> show totalLen <> ", but the maximum possible length is " <> show algoMaxAppProgramLen_really
  modifyIORef eRes $
    M.insert "extraPages" $
      AS.Number $ fromIntegral $ extraPages totalLen
  gFailures <- readIORef gFailuresR
  gWarnings <- readIORef gWarningsR
  let wss w lab ss = do
        unless (null ss) $
          emitWarning Nothing $ w $ S.toAscList $ S.map LT.unpack ss
        modifyIORef eRes $ M.insert lab $
          aarray $ S.toAscList $ S.map (AS.String . LT.toStrict) ss
  wss W_ALGOConservative "warnings" gWarnings
  wss W_ALGOUnsupported "unsupported" gFailures
  abi <- readIORef eABI
  let apiEntry lab f = (lab, aarray $ map (AS.String . s2t) $ M.keys $ M.filter f abi)
  modifyIORef eRes $
    M.insert "ABI" $
      aobject $
        M.fromList $
          [ apiEntry "sigs" (const True)
          , apiEntry "impure" (not . abiPure)
          , apiEntry "pure" abiPure
          ]
  modifyIORef eRes $
    M.insert "version" $
      AS.Number $ fromIntegral $ reachAlgoBackendVersion
  res <- readIORef eRes
  return $ aobject res

data ALGOConnectorInfo = ALGOConnectorInfo
  { aci_appApproval :: String
  , aci_appClear :: String
  } deriving (Show)

instance AS.ToJSON ALGOConnectorInfo where
  toJSON (ALGOConnectorInfo {..}) = AS.object $
    [ "approvalB64" .= aci_appApproval
    , "clearStateB64" .= aci_appClear
    ]

instance AS.FromJSON ALGOConnectorInfo where
  parseJSON = AS.withObject "ALGOConnectorInfo" $ \obj -> do
    aci_appApproval <- obj .: "appApproval"
    aci_appClear <- obj .: "appClear"
    return $ ALGOConnectorInfo {..}

data ALGOCodeIn = ALGOCodeIn
  { aci_approval :: String
  , aci_clearState :: String
  }
  deriving (Show)

instance AS.ToJSON ALGOCodeIn where
  toJSON (ALGOCodeIn {..}) = AS.object $
    [ "approval" .= aci_approval
    , "clearState" .= aci_clearState
    ]

instance AS.FromJSON ALGOCodeIn where
  parseJSON = AS.withObject "ALGOCodeIn" $ \obj -> do
    aci_approval <- obj .: "approval"
    aci_clearState <- obj .: "clearState"
    return $ ALGOCodeIn {..}

data ALGOCodeOut = ALGOCodeOut
  { aco_approval :: String
  , aco_clearState :: String
  }
  deriving (Show)

instance AS.ToJSON ALGOCodeOut where
  toJSON (ALGOCodeOut {..}) = AS.object $
    [ "approvalB64" .= toBase64 aco_approval
    , "clearStateB64" .= toBase64 aco_clearState
    ]
    where
      toBase64 :: String -> String
      toBase64 = LT.unpack . encodeBase64 . B.pack

instance AS.FromJSON ALGOCodeOut where
  parseJSON = AS.withObject "ALGOCodeOut" $ \obj -> do
    let fromBase64 :: String -> String
        fromBase64 x =
          case decodeBase64 $ B.pack x of
           Left y -> impossible $ "bad base64: " <> show y
           Right y -> B.unpack y
    aco_approval <- fromBase64 <$> (obj .: "approvalB64")
    aco_clearState <- fromBase64 <$> (obj .: "clearStateB64")
    return $ ALGOCodeOut {..}

data ALGOCodeOpts = ALGOCodeOpts
  { aco_globalUints :: Integer
  , aco_globalBytes :: Integer
  , aco_localUints :: Integer
  , aco_localBytes :: Integer
  }
  deriving (Show)

instance AS.ToJSON ALGOCodeOpts where
  toJSON (ALGOCodeOpts {..}) = AS.object $
    [ "globalUints" .= aco_globalUints
    , "globalBytes" .= aco_globalBytes
    , "localUints" .= aco_localUints
    , "localBytes" .= aco_localBytes
    ]

instance AS.FromJSON ALGOCodeOpts where
  parseJSON = AS.withObject "ALGOCodeOpts" $ \obj -> do
    aco_globalUints <- fromMaybe 0 <$> firstJustM (obj .:?) [ "globalUints", "GlobalNumUint" ]
    aco_globalBytes <- fromMaybe 0 <$> firstJustM (obj .:?) [ "globalBytes", "GlobalNumByteSlice" ]
    aco_localUints  <- fromMaybe 0 <$> firstJustM (obj .:?) [ "localUints", "LocalNumUint" ]
    aco_localBytes  <- fromMaybe 0 <$> firstJustM (obj .:?) [ "localBytes", "LocalNumByteSlice" ]
    return $ ALGOCodeOpts {..}

ccTEAL :: String -> CCApp BS.ByteString
ccTEAL tealf = liftIO (compileTEAL_ tealf) >>= \case
  Right x -> return x
  Left x -> throwE $ B.unpack x

ccTok :: BS.ByteString -> String
ccTok = B.unpack

ccPath :: String -> CCApp String
ccPath fp =
  case takeExtension fp of
    ".tok" -> ccTok <$> ccRead fp
    ".teal" -> ccTok <$> ccTEAL fp
    x -> throwE $ "Invalid code path: " <> show x

connect_algo :: Connector
connect_algo = Connector {..}
  where
    conName = conName'
    conCons = conCons'
    conGen (ConGenConfig {..}) clp = compile_algo cgOutput clp
    conReserved = const False
    conCompileCode v = runExceptT $ do
      ALGOCodeIn {..} <- aesonParse' v
      a' <- ccPath aci_approval
      cs' <- ccPath aci_clearState
      return $ AS.toJSON $ ALGOCodeOut a' cs'
    conContractNewOpts :: Maybe AS.Value -> Either String AS.Value
    conContractNewOpts mv = do
      (aco :: ALGOCodeOpts) <- aesonParse $ fromMaybe (AS.object mempty) mv
      return $ AS.toJSON aco
    conCompileConnectorInfo :: Maybe AS.Value -> Either String AS.Value
    conCompileConnectorInfo v = do
      ALGOConnectorInfo {..} <- aesonParse $ fromMaybe (AS.object mempty) v
      return $ AS.toJSON $ ALGOConnectorInfo {..}
