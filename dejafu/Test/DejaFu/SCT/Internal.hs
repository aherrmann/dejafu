{-# LANGUAGE CPP #-}

-- | Internal utilities and types for BPOR.
module Test.DejaFu.SCT.Internal where

import Control.DeepSeq (NFData(..))
import Data.IntMap.Strict (IntMap)
import Data.List (foldl', partition, maximumBy)
import Data.Maybe (mapMaybe, fromJust)
import Data.Ord (comparing)
import Data.Sequence (Seq, ViewL(..))
import Data.Set (Set)
import Test.DejaFu.Deterministic

import qualified Data.IntMap.Strict as I
import qualified Data.Sequence as Sq
import qualified Data.Set as S

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative ((<$>), (<*>))
#endif

-- * BPOR state

-- | One step of the execution, including information for backtracking
-- purposes. This backtracking information is used to generate new
-- schedules.
data BacktrackStep = BacktrackStep
  { _threadid  :: ThreadId
  -- ^ The thread running at this step
  , _decision  :: (Decision, ThreadAction)
  -- ^ What happened at this step.
  , _runnable  :: Set ThreadId
  -- ^ The threads runnable at this step
  , _backtrack :: IntMap Bool
  -- ^ The list of alternative threads to run, and whether those
  -- alternatives were added conservatively due to the bound.
  } deriving (Eq, Show)

instance NFData BacktrackStep where
  rnf b = rnf (_threadid b, _decision b, _runnable b, _backtrack b)

-- | BPOR execution is represented as a tree of states, characterised
-- by the decisions that lead to that state.
data BPOR = BPOR
  { _brunnable :: Set ThreadId
  -- ^ What threads are runnable at this step.
  , _btodo     :: IntMap Bool
  -- ^ Follow-on decisions still to make, and whether that decision
  -- was added conservatively due to the bound.
  , _bignore   :: Set ThreadId
  -- ^ Follow-on decisions never to make, because they will result in
  -- the chosen thread immediately blocking without achieving
  -- anything, which can't have any effect on the result of the
  -- program.
  , _bdone     :: IntMap BPOR
  -- ^ Follow-on decisions that have been made.
  , _bsleep    :: IntMap ThreadAction
  -- ^ Transitions to ignore (in this node and children) until a
  -- dependent transition happens.
  , _btaken    :: IntMap ThreadAction
  -- ^ Transitions which have been taken, excluding
  -- conservatively-added ones, in the (reverse) order that they were
  -- taken, as the 'Map' doesn't preserve insertion order. This is
  -- used in implementing sleep sets.
  }

-- | Initial BPOR state.
initialState :: BPOR
initialState = BPOR
  { _brunnable = S.singleton 0
  , _btodo     = I.singleton 0 False
  , _bignore   = S.empty
  , _bdone     = I.empty
  , _bsleep    = I.empty
  , _btaken    = I.empty
  }

-- | Produce a new schedule from a BPOR tree. If there are no new
-- schedules remaining, return 'Nothing'. Also returns whether the
-- decision made was added conservatively.
--
-- This returns the longest prefix, on the assumption that this will
-- lead to lots of backtracking points being identified before
-- higher-up decisions are reconsidered, so enlarging the sleep sets.
next :: BPOR -> Maybe ([ThreadId], Bool, BPOR)
next = go 0 where
  go tid bpor =
        -- All the possible prefix traces from this point, with
        -- updated BPOR subtrees if taken from the done list.
    let prefixes = mapMaybe go' (I.toList $ _bdone bpor) ++ [Left t | t <- I.toList $ _btodo bpor]
        -- Sort by number of preemptions, in descending order.
        cmp   = comparing $ preEmps tid bpor . either (\(a,_) -> [a]) (\(a,_,_) -> a)

    in if null prefixes
       then Nothing
       else case maximumBy cmp prefixes of
              -- If the prefix with the most preemptions is from the done list, update that.
              Right (ts@(t:_), c, b) -> Just (ts, c, bpor { _bdone = I.insert t b $ _bdone bpor })
              Right ([], _, _) -> error "Invariant failure in 'next': empty done prefix!"

              -- If from the todo list, remove it.
              Left (t,c) -> Just ([t], c, bpor { _btodo = I.delete t $ _btodo bpor })

  go' (tid, bpor) = (\(ts,c,b) -> Right (tid:ts, c, b)) <$> go tid bpor

  preEmps tid bpor (t:ts) =
    let rest = preEmps t (fromJust . I.lookup t $ _bdone bpor) ts
    in  if t > 0 && tid /= t && tid `S.member` _brunnable bpor then 1 + rest else rest
  preEmps _ _ [] = 0::Int

-- | Produce a list of new backtracking points from an execution
-- trace.
findBacktrack :: MemType
  -> ([BacktrackStep] -> Int -> ThreadId -> [BacktrackStep])
  -> Seq (NonEmpty (ThreadId, Lookahead), [ThreadId])
  -> Trace'
  -> [BacktrackStep]
findBacktrack memtype backtrack = go S.empty 0 [] . Sq.viewl where
  go allThreads tid bs ((e,i):<is) ((d,_,a):ts) =
    let tid' = tidOf tid d
        this        = BacktrackStep { _threadid  = tid'
                                    , _decision  = (d, a)
                                    , _runnable  = S.fromList . map fst . toList $ e
                                    , _backtrack = I.fromList $ map (\i' -> (i', False)) i
                                    }
        bs'         = doBacktrack allThreads (toList e) bs
        allThreads' = allThreads `S.union` _runnable this
    in go allThreads' tid' (bs' ++ [this]) (Sq.viewl is) ts
  go _ _ bs _ _ = bs

  doBacktrack allThreads enabledThreads bs =
    let tagged = reverse $ zip [0..] bs
        idxs   = [ (head is, u)
                 | (u, n) <- enabledThreads
                 , v <- S.toList allThreads
                 , u /= v
                 , let is = [ i
                            | (i, b) <- tagged
                            , _threadid b == v
                            , dependent' memtype (snd $ _decision b) (u, n)
                            ]
                 , not $ null is] :: [(Int, ThreadId)]
    in foldl' (\b (i, u) -> backtrack b i u) bs idxs

-- | Add a new trace to the tree, creating a new subtree.
grow :: MemType -> Bool -> Trace' -> BPOR -> BPOR
grow memtype conservative = grow' initialCVState 0 where
  grow' cvstate tid trc@((d, _, a):rest) bpor =
    let tid'     = tidOf tid d
        cvstate' = updateCVState cvstate a
    in  case I.lookup tid' $ _bdone bpor of
          Just bpor' -> bpor { _bdone  = I.insert tid' (grow' cvstate' tid' rest bpor') $ _bdone bpor }
          Nothing    -> bpor { _btaken = if conservative then _btaken bpor else I.insert tid' a $ _btaken bpor
                            , _bdone  = I.insert tid' (subtree cvstate' tid' (_bsleep bpor `I.union` _btaken bpor) trc) $ _bdone bpor }
  grow' _ _ [] bpor = bpor

  subtree cvstate tid sleep ((d, ts, a):rest) =
    let cvstate' = updateCVState cvstate a
        sleep'   = I.filterWithKey (\t a' -> not $ dependent memtype a (t,a')) sleep
    in BPOR
        { _brunnable = S.fromList $ tids tid d a ts
        , _btodo     = I.empty
        , _bignore   = S.fromList [tidOf tid d' | (d',as) <- ts, willBlockSafely cvstate' $ toList as]
        , _bdone     = I.fromList $ case rest of
          ((d', _, _):_) ->
            let tid' = tidOf tid d'
            in  [(tid', subtree cvstate' tid' sleep' rest)]
          [] -> []
        , _bsleep = sleep'
        , _btaken = case rest of
          ((d', _, a'):_) -> I.singleton (tidOf tid d') a'
          [] -> I.empty
        }
  subtree _ _ _ [] = error "Invariant failure in 'subtree': suffix empty!"

  tids tid d (Fork t)           ts = tidOf tid d : t : map (tidOf tid . fst) ts
  tids tid _ (BlockedPut _)     ts = map (tidOf tid . fst) ts
  tids tid _ (BlockedRead _)    ts = map (tidOf tid . fst) ts
  tids tid _ (BlockedTake _)    ts = map (tidOf tid . fst) ts
  tids tid _ BlockedSTM         ts = map (tidOf tid . fst) ts
  tids tid _ (BlockedThrowTo _) ts = map (tidOf tid . fst) ts
  tids tid _ Stop               ts = map (tidOf tid . fst) ts
  tids tid d _ ts = tidOf tid d : map (tidOf tid . fst) ts

-- | Add new backtracking points, if they have not already been
-- visited, fit into the bound, and aren't in the sleep set.
todo :: ([Decision] -> Bool) -> [BacktrackStep] -> BPOR -> BPOR
todo bv = step where
  step bs bpor =
    let (bpor', bs') = go 0 [] Nothing bs bpor
    in  if all (I.null . _backtrack) bs'
        then bpor'
        else step bs' bpor'

  go tid pref lastb (b:bs) bpor =
    let (bpor', blocked) = backtrack pref b bpor
        tid'   = tidOf tid . fst $ _decision b
        (child, blocked')  = go tid' (pref++[fst $ _decision b]) (Just b) bs . fromJust $ I.lookup tid' (_bdone bpor)
        bpor'' = bpor' { _bdone = I.insert tid' child $ _bdone bpor' }
    in  case lastb of
         Just b' -> (bpor'', b' { _backtrack = blocked } : blocked')
         Nothing -> (bpor'', blocked')

  go _ _ (Just b') _ bpor = (bpor, [b' { _backtrack = I.empty }])
  go _ _ Nothing   _ bpor = (bpor, [])

  backtrack pref b bpor =
    let todo' = [ x
                | x@(t,c) <- I.toList $ _backtrack b
                , bv $ pref ++ [decisionOf (Just $ activeTid pref) (_brunnable bpor) t]
                , t `notElem` I.keys (_bdone bpor)
                , c || I.notMember t (_bsleep bpor)
                ]
        (blocked, nxt) = partition (\(t,_) -> t `S.member` _bignore bpor) todo'
    in  (bpor { _btodo = _btodo bpor `I.union` I.fromList nxt }, I.fromList blocked)

-- * Utilities

-- | Get the resultant 'ThreadId' of a 'Decision', with a default case
-- for 'Continue'.
tidOf :: ThreadId -> Decision -> ThreadId
tidOf _ (Start t)    = t
tidOf _ (SwitchTo t) = t
tidOf tid _          = tid

-- | Get the 'Decision' that would have resulted in this 'ThreadId',
-- given a prior 'ThreadId' (if any) and list of runnable threads.
decisionOf :: Maybe ThreadId -> Set ThreadId -> ThreadId -> Decision
decisionOf prior runnable chosen
  | prior == Just chosen = Continue
  | prior `S.member` S.map Just runnable = SwitchTo chosen
  | otherwise = Start chosen

-- | Get the tid of the currently active thread after executing a
-- series of decisions. The list MUST begin with a 'Start'.
activeTid :: [Decision] -> ThreadId
activeTid = foldl' tidOf 0

-- | Count the number of pre-emptions in a schedule
preEmpCount :: [Decision] -> Int
preEmpCount (SwitchTo t:ds)
  | t >= 0 = 1 + preEmpCount ds
  | otherwise = preEmpCount ds
preEmpCount (_:ds) = preEmpCount ds
preEmpCount [] = 0

-- | Check if an action is dependent on another.
dependent :: MemType -> ThreadAction -> (ThreadId, ThreadAction) -> Bool
dependent _ Lift (_, Lift) = True
dependent _ (ThrowTo t) (t2, _) = t == t2
dependent memtype d1 (_, d2) = cref || cvar || ctvar where
  cref = case (d1, d2) of
    (ReadRef r1, ModRef      r2) -> r1 == r2
    (ReadRef r1, WriteRef    r2) -> r1 == r2 && memtype == SequentialConsistency
    (ReadRef r1, CommitRef _ r2) -> r1 == r2

    (ModRef r1, ReadRef     r2) -> r1 == r2
    (ModRef r1, ModRef      r2) -> r1 == r2
    (ModRef r1, WriteRef    r2) -> r1 == r2
    (ModRef r1, CommitRef _ r2) -> r1 == r2

    -- Writes would also conflict with commits under sequential
    -- consistency, but commits only get introduced for TSO and PSO.
    (WriteRef r1, ReadRef  r2) -> r1 == r2 && memtype == SequentialConsistency
    (WriteRef r1, ModRef   r2) -> r1 == r2
    (WriteRef r1, WriteRef r2) -> r1 == r2 && memtype == SequentialConsistency

    -- Similarly, commits would conflict with writes under SQ, but
    -- they don't get introduced.
    (CommitRef _ r1, ReadRef     r2) -> r1 == r2
    (CommitRef _ r1, ModRef      r2) -> r1 == r2
    (CommitRef _ r1, CommitRef _ r2) -> r1 == r2

    _ -> False

  cvar = Just True == ((==) <$> cvar' d1 <*> cvar' d2)
  cvar'  (TryPut  c _ _) = Just c
  cvar'  (TryTake c _ _) = Just c
  cvar'  (Put  c _) = Just c
  cvar'  (Read c)   = Just c
  cvar'  (Take c _) = Just c
  cvar'  _ = Nothing

  ctvar = ctvar' d1 && ctvar' d2
  ctvar' (STM _) = True
  ctvar' _ = False

-- | Variant of 'dependent' to handle 'ThreadAction''s
dependent' :: MemType -> ThreadAction -> (ThreadId, Lookahead) -> Bool
dependent' _ Lift (_, WillLift) = True
dependent' _ (ThrowTo t) (t2, _) = t == t2
dependent' memtype d1 (_, d2) = cref || cvar || ctvar where
  cref = case (d1, d2) of
    (ReadRef r1, WillModRef      r2) -> r1 == r2
    (ReadRef r1, WillWriteRef    r2) -> r1 == r2 && memtype == SequentialConsistency
    (ReadRef r1, WillCommitRef _ r2) -> r1 == r2

    (ModRef r1, WillReadRef     r2) -> r1 == r2
    (ModRef r1, WillModRef      r2) -> r1 == r2
    (ModRef r1, WillWriteRef    r2) -> r1 == r2
    (ModRef r1, WillCommitRef _ r2) -> r1 == r2

    -- Writes would also conflict with commits under sequential
    -- consistency, but commits only get introduced for TSO and PSO.
    (WriteRef r1, WillReadRef  r2) -> r1 == r2 && memtype == SequentialConsistency
    (WriteRef r1, WillModRef   r2) -> r1 == r2
    (WriteRef r1, WillWriteRef r2) -> r1 == r2 && memtype == SequentialConsistency

    -- Similarly, commits would conflict with writes under SQ, but
    -- they don't get introduced.
    (CommitRef _ r1, WillReadRef     r2) -> r1 == r2
    (CommitRef _ r1, WillModRef      r2) -> r1 == r2
    (CommitRef _ r1, WillCommitRef _ r2) -> r1 == r2

    _ -> False

  cvar = Just True == ((==) <$> cvar' d1 <*> cvar'' d2)
  cvar'  (TryPut  c _ _) = Just c
  cvar'  (TryTake c _ _) = Just c
  cvar'  (Put  c _) = Just c
  cvar'  (Read c)   = Just c
  cvar'  (Take c _) = Just c
  cvar'  _ = Nothing
  cvar'' (WillTryPut  c) = Just c
  cvar'' (WillTryTake c) = Just c
  cvar'' (WillPut  c) = Just c
  cvar'' (WillRead c) = Just c
  cvar'' (WillTake c) = Just c
  cvar'' _ = Nothing

  ctvar = ctvar' d1 && ctvar'' d2
  ctvar' (STM _) = True
  ctvar' _ = False
  ctvar'' WillSTM = True
  ctvar'' _ = False

-- * Keeping track of 'CVar' full/empty states

-- | Initial global 'CVar' state
initialCVState :: IntMap Bool
initialCVState = I.empty

-- | Update the 'CVar' state with the action that has just happened.
updateCVState :: IntMap Bool -> ThreadAction -> IntMap Bool
updateCVState cvstate (Put  c _) = I.insert c True  cvstate
updateCVState cvstate (Take c _) = I.insert c False cvstate
updateCVState cvstate (TryPut  c True _) = I.insert c True  cvstate
updateCVState cvstate (TryTake c True _) = I.insert c False cvstate
updateCVState cvstate _ = cvstate

-- | Check if an action will block.
willBlock :: IntMap Bool -> Lookahead -> Bool
willBlock cvstate (WillPut  c) = I.lookup c cvstate == Just True
willBlock cvstate (WillTake c) = I.lookup c cvstate == Just False
willBlock _ _ = False

-- | Check if a list of actions will block safely (without modifying
-- any global state). This allows further lookahead at, say, the
-- 'spawn' of a thread (which always starts with 'KnowsAbout').
willBlockSafely :: IntMap Bool -> [Lookahead] -> Bool
willBlockSafely cvstate (WillKnowsAbout:as) = willBlockSafely cvstate as
willBlockSafely cvstate (WillForgets:as)    = willBlockSafely cvstate as
willBlockSafely cvstate (WillAllKnown:as)   = willBlockSafely cvstate as
willBlockSafely cvstate (WillPut  c:_) = willBlock cvstate (WillPut  c)
willBlockSafely cvstate (WillTake c:_) = willBlock cvstate (WillTake c)
willBlockSafely _ _ = False