{-# LANGUAGE OverloadedStrings #-}
module Mate.BasicBlocks(
  BlockID,
  BasicBlock (..),
  BBEnd (..),
  MapBB,
  printMapBB,
  parseMethod,
  test_main
  )where

import Data.Binary
import Data.Int
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as B

import JVM.ClassFile
import JVM.Converter
import JVM.Assembler

import Mate.Utilities


type BlockID = Int
-- Represents a CFG node
data BasicBlock = BasicBlock {
                     -- inputs  :: [Variable],
                     -- outputs :: [Variable],
                     code    :: [Instruction],
                     successor :: BBEnd }

-- describes (leaving) edges of a CFG node
data BBEnd = Return | OneTarget BlockID | TwoTarget BlockID BlockID deriving Show

type MapBB = M.Map BlockID BasicBlock

-- for immediate representation for determine BBs
type Offset = (Int, Maybe BBEnd) -- (offset in bytecode, offset to jump target)
type OffIns = (Offset, Instruction)


printMapBB :: Maybe MapBB -> IO ()
printMapBB Nothing = putStrLn "No BasicBlock"
printMapBB (Just hmap) = do
                     putStr "BlockIDs: "
                     let keys = fst $ unzip $ M.toList hmap
                     mapM_ (putStr . (flip (++)) ", " . show) keys
                     putStrLn "\n\nBasicBlocks:"
                     printMapBB' keys hmap
  where
  printMapBB' :: [BlockID] -> MapBB -> IO ()
  printMapBB' [] _ = return ()
  printMapBB' (i:is) hmap' = case M.lookup i hmap' of
                  Just bb -> do
                             putStrLn $ "Block " ++ (show i)
                             mapM_ putStrLn (map ((++) "\t" . show) $ code bb)
                             case successor bb of
                               Return -> putStrLn ""
                               OneTarget t1 -> putStrLn $ "Sucessor: " ++ (show t1) ++ "\n"
                               TwoTarget t1 t2 -> putStrLn $ "Sucessor: " ++ (show t1) ++ ", " ++ (show t2) ++ "\n"
                             printMapBB' is hmap
                  Nothing -> error $ "BlockID " ++ show i ++ " not found."

testInstance :: String -> B.ByteString -> IO ()
testInstance cf method = do
                      cls <- parseClassFile cf
                      hmap <- parseMethod cls method
                      printMapBB hmap

test_main :: IO ()
test_main = do
  test_01
  test_02
  test_03

test_01, test_02, test_03 :: IO ()
test_01 = testInstance "./tests/Fib.class" "fib"
test_02 = testInstance "./tests/While.class" "f"
test_03 = testInstance "./tests/While.class" "g"


parseMethod :: Class Resolved -> B.ByteString -> IO (Maybe MapBB)
parseMethod cls method = do
                     -- TODO(bernhard): remove me! just playing around with
                     --                 hs-java interface.
                     -- we get that index at the INVOKESTATIC insn
                     putStrLn "via constpool @2:"
                     let cp = constsPool cls
                     let (CMethod rc nt) = cp M.! (2 :: Word16)
                     -- rc :: Link stage B.ByteString
                     -- nt :: Link stage (NameType Method)
                     B.putStrLn $ "rc: " `B.append` rc
                     B.putStrLn $ "nt: " `B.append` (encode $ ntSignature nt)

                     putStrLn "via methods:"
                     let msig = methodSignature $ (classMethods cls) !! 1
                     B.putStrLn (method `B.append` ": " `B.append` (encode msig))

                     return $ testCFG $ lookupMethod method cls


testCFG :: Maybe (Method Resolved) -> Maybe MapBB
testCFG (Just m) = case attrByName m "Code" of
       Nothing -> Nothing
       Just bytecode -> Just $ buildCFG $ codeInstructions $ decodeMethod bytecode
testCFG _ = Nothing


buildCFG :: [Instruction] -> MapBB
buildCFG xs = buildCFG' M.empty xs' xs'
  where
  xs' :: [OffIns]
  xs' = calculateInstructionOffset xs

buildCFG' :: MapBB -> [OffIns] -> [OffIns] -> MapBB
buildCFG' hmap [] _ = hmap
buildCFG' hmap (((off, entry), _):xs) insns = buildCFG' (insertlist entryi hmap) xs insns
  where
  insertlist :: [BlockID] -> MapBB -> MapBB
  insertlist [] hmap' = hmap'
  insertlist (y:ys) hmap' = insertlist ys newhmap
    where
    newhmap = if M.member y hmap' then hmap' else M.insert y value hmap'
    value = parseBasicBlock y insns

  entryi :: [BlockID]
  entryi = (if off == 0 then [0] else []) ++ -- also consider the entrypoint
        case entry of
        Just (TwoTarget t1 t2) -> [t1, t2]
        Just (OneTarget t) -> [t]
        Just (Return) -> []
        Nothing -> []


parseBasicBlock :: Int -> [OffIns] -> BasicBlock
parseBasicBlock i insns = BasicBlock insonly endblock
  where
  startlist = dropWhile (\((x,_),_) -> x < i) insns
  (Just ((_,(Just endblock)),_), is) = takeWhilePlusOne validins startlist
  insonly = snd $ unzip is

  -- also take last (non-matched) element and return it
  takeWhilePlusOne :: (a -> Bool) -> [a] -> (Maybe a,[a])
  takeWhilePlusOne _ [] = (Nothing,[])
  takeWhilePlusOne p (x:xs)
    | p x       =  let (lastins, list) = takeWhilePlusOne p xs in (lastins, (x:list))
    | otherwise =  (Just x,[x])

  validins :: ((Int, Maybe BBEnd), Instruction) -> Bool
  validins ((_,x),_) = case x of Just _ -> False; Nothing -> True


calculateInstructionOffset :: [Instruction] -> [OffIns]
calculateInstructionOffset = cio' (0, Nothing)
  where
  newoffset :: Instruction -> Int -> Offset
  newoffset x off = (off + (fromIntegral $ B.length $ encodeInstructions [x]), Nothing)

  addW16Signed :: Int -> Word16 -> Int
  addW16Signed i w16 = i + (fromIntegral s16)
    where s16 = (fromIntegral w16) :: Int16

  cio' :: Offset -> [Instruction] -> [OffIns]
  cio' _ [] = []
  -- TODO(bernhard): add more instruction with offset (IF_ACMP, JSR, ...)
  cio' (off,_) (x:xs) = case x of
      IF _ w16 -> twotargets w16
      IF_ICMP _ w16 -> twotargets w16
      GOTO w16 -> onetarget w16
      IRETURN -> notarget
      RETURN -> notarget
      _ -> ((off, Nothing), x):next
    where
    notarget = ((off, Just Return), x):next
    onetarget w16 = ((off, Just $ OneTarget $ (off `addW16Signed` w16)), x):next
    twotargets w16 = ((off, Just $ TwoTarget (off + 3) (off `addW16Signed` w16)), x):next
    next = cio' (newoffset x off) xs