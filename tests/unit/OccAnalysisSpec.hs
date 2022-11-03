-- Copyright 2022 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module OccAnalysisSpec (spec) where

import Prelude hiding (unlines)
import Data.Maybe (catMaybes)
import Data.Text
import Test.Hspec

import AbstractSyntax (parseUModule)
import Builder (ReconstructAtom(IdentityRecon))
import Err
import Inference (inferTopUExpr, synthTopBlock)
import Name
import OccAnalysis
import Occurrence
import Optimize (earlyOptimize)
import Simplify
import SourceRename (renameSourceNamesUExpr)
import Types.Core
import Types.Imp (Backend (..))
import Types.Primitives
import Types.Source
import TopLevel

sourceTextToBlocks :: (Topper m, Mut n) => Text -> m n [Block n]
sourceTextToBlocks source = do
  let (UModule _ deps sourceBlocks) = parseUModule Main source
  mapM_ ensureModuleLoaded deps
  catMaybes <$> mapM sourceBlockToBlock sourceBlocks

sourceBlockToBlock :: (Topper m, Mut n) => SourceBlock -> m n (Maybe (Block n))
sourceBlockToBlock block = case sbContents block of
  Misc (ImportModule moduleName)  -> importModule moduleName >> return Nothing
  Command (EvalExpr Printed) expr -> Just <$> uExprToBlock expr
  UnParseable _ s -> throw ParseErr s
  _ -> error $ "Unexpected SourceBlock " ++ pprint block ++ " in unit tests"

uExprToBlock :: (Topper m, Mut n) => UExpr 'VoidS -> m n (Block n)
uExprToBlock expr = do
  renamed <- renameSourceNamesUExpr expr
  typed <- inferTopUExpr renamed
  eopt <- earlyOptimize typed
  synthed <- synthTopBlock eopt
  (SimplifiedBlock block IdentityRecon) <- simplifyTopBlock synthed
  return block

findRunIOAnnotation :: Block n -> LetAnn
findRunIOAnnotation (Block _ decls _) = go decls where
  go :: Nest Decl n l -> LetAnn
  go (Nest (Let _ (DeclBinding ann _ (Hof (RunIO _)))) _) = ann
  go (Nest _ rest) = go rest
  go Empty = error "RunIO not found"

analyze :: EvalConfig -> TopStateEx -> [Text] -> IO LetAnn
analyze cfg env code = fst <$> runTopperM cfg env do
  [block] <- sourceTextToBlocks $ unlines code
  block' <- analyzeOccurrences block
  return $ findRunIOAnnotation block';

spec :: Spec
spec = do
  let cfg = EvalConfig LLVM [LibBuiltinPath] Nothing Nothing Nothing Optimize
  -- or just initTopState, to always compile the prelude during unit tests?
  init_env <- runIO loadCache
  (_, env) <- runIO $ runTopperM cfg init_env $ ensureModuleLoaded Prelude
  describe "Occurrence analysis" do
    it "counts a reference as a use" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  xs"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (0,Bounded 1))
    it "counts indexing in a for as one use" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  for i. xs.i"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    it "counts indexing depth in nested fors" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => (Fin 3) => Float = unreachable ()"
        , "  for i j. xs.i.j"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (2,Bounded 1))
    it "counts two array uses" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  (for i. xs.i, for j. xs.j)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Bounded 2))
    it "counts array and non-array uses" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  (for i. xs.i, xs)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Bounded 2))
    it "counts different case arms as static but not dynamic uses" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  if unreachable ()"
        , "    then for i. xs.i"
        , "    else for j. xs.j"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Bounded 1))
    it "understands one index injection" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : ((Fin 10) | (Fin 4)) => Float = unreachable ()"
        , "  for j. xs.(Left j)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    it "understands distinct index injections" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : ((Fin 10) | (Fin 4)) => Float = unreachable ()"
        , "  (for i. xs.(Left i), for j. xs.(Right j))"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Bounded 1))
    it "detects and eschews index arithmetic" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 4) => Float = unreachable ()"
        , "  for i:(Fin 3). xs.((ordinal i + 1)@_)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Unbounded))
    it "detects non-nested single-uses cases despite index arithmetic" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 4) => Float = unreachable ()"
        , "  xs.(1@_)"
        ]
      -- Arguably, should be able to prove that zero levels of exposed indexing
      -- (not one) suffice for inlining xs to be safe here, but doesn't prove it
      -- yet.
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    it "detects nested single-uses cases despite index arithmetic" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 4) => (Fin 3) => Float = unreachable ()"
        , "  for i:(Fin 3). xs.((ordinal i + 1)@_).i"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (2,Bounded 1))
    it "detects repeated access" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 4) => Float = unreachable ()"
        , "  for i j:(Fin 5). xs.i"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Unbounded))
    it "does not count the `trace` pattern as repeated access" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 4) => (Fin 4) => Float = unreachable ()"
        , "  for i. xs.i.i"
        ]
      -- Arguably, should be able to prove that only one level of exposed
      -- indexing (not two) suffice for inlining xs to be safe here, but doesn't
      -- prove it yet.
      ann `shouldBe` OccInfo (UsageInfo 1 (2,Bounded 1))
    it "solves safe sum-over-max" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : ((Fin 4 | Fin 4) | (Fin 4 | Fin 4)) => Float = unreachable ()"
        , "  ys = for i."
        , "    if unreachable ()"
        , "      then xs.(Left  (Left  i))"
        , "      else xs.(Left  (Right i))"
        , "  zs = for j."
        , "    if unreachable ()"
        , "      then xs.(Right (Left  j))"
        , "      else xs.(Right (Right j))"
        , "  (ys, zs)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 4 (1,Bounded 1))
    it "solves unsafe sum-over-max" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : ((Fin 4 | Fin 4) | (Fin 4 | Fin 4)) => Float = unreachable ()"
        , "  ys = for i."
        , "    if unreachable ()"
        , "      then xs.(Left  (Left  i))"
        , "      else xs.(Left  (Right i))"
        , "  zs = for j."
        , "    if unreachable ()"
        , "      then xs.(Right (Left  j))"
        , "      else xs.(Left  (Left  j))"
        , "  (ys, zs)"
        ]
      -- One of the code paths hits the same elements(s)
      ann `shouldBe` OccInfo (UsageInfo 4 (1,Bounded 2))
    it "does not penalize referring to indices in scope" do
      ann <- analyze cfg env
        [ ":p"
        , "  j = 1@(Fin 3)"
        , "  xs : (Fin 10) => (Fin 3) => Float = unreachable ()"
        , "  for i. xs.i.j"
        ]
      -- Arguably, should be able to prove that only one level of exposed
      -- indexing (not two) suffice for inlining xs to be safe here, but doesn't
      -- prove it yet.
      ann `shouldBe` OccInfo (UsageInfo 1 (2,Bounded 1))
    it "is conservative about potential collisions between indices in scope" do
      ann <- analyze cfg env
        [ ":p"
        , "  j = 1@(Fin 3)"
        , "  k = 1@(Fin 3)"
        , "  xs : (Fin 10) => (Fin 3) => Float = unreachable ()"
        , "  (for i. xs.i.j, for i. xs.i.k)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (2,Bounded 2))
    it "is not confused by potential collisions at an early indexing depth" do
      ann <- analyze cfg env
        [ ":p"
        , "  j = 1@(Fin 10)"
        , "  k = 1@(Fin 10)"
        , "  xs : (Fin 10) => (Fin 3) => Float = unreachable ()"
        , "  (for i. xs.j.i, for i. xs.k.i)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (2,Bounded 2))
    it "does not crash on indexing by case-bound binders" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  for i."
        , "    case i of"
        , "      (Left  j) -> xs.j"
        , "      (Right k) -> xs.k"
        ]
      -- TODO actually, it should be possible to get this to be Bounded 2 rather
      -- than Unbounded.  We get Unbounded because `occAlt` assumes that the
      -- binder of a case (in this case `j`) is an "unknown function" of the
      -- scrutinee.  That's conservative, but in reality the function is very
      -- well known, and even injective, but just not total (and not the same
      -- across arms of the `case`).  However, trying to fix that would unmask
      -- another bug, which is that mapping `case` to `max` is only correct if
      -- the scrutinee doesn't depend on any binders being iterated.  In fact,
      -- in this example it does, so both arms of the `case` end up being taken,
      -- albeit at different iterations of the `i` loop.  To analyze this
      -- correctly, we would need to know that `j` and `k` may collide across
      -- `case` arms, though not within an arm.
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Unbounded))
    it "does not crash on indexing by state-effect-bound binders" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  with_state (0 @ Fin 10) \\ref."
        , "    xs.(get ref)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    it "assumes state references touch everything" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  with_state (0 @ Fin 10) \\ref."
        , "    for i:(Fin 3)."
        , "      xs.(get ref)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Unbounded))
    it "assumes state references touch everything even if the initializer doesn't" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  for i:(Fin 10)."
        , "    with_state i \\ref."
        , "      xs.(get ref)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Unbounded))
    it "analyzes through accum effects" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  run_accum (AddMonoid Float) \\ref."
        , "    for i."
        , "      ref += xs.i"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    -- TODO Should probably construct an example of indexing with the ref of a
    -- run_accum (and, for that matter, with the handle of a run_state or
    -- run_accum), but I'm not sure how to make either of those well-typed.
    it "does not crash on indexing by reader-effect-bound binders" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        , "  with_reader (0 @ Fin 10) \\ref."
        , "    xs.(ask ref)"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    it "understands that while loops access repeatedly" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10) => Float = unreachable ()"
        -- with_state prevents the access from appearing dead
        , "  with_state 0 \\ref."
        , "    while \\_."
        , "      for i."
        , "        ref := (get ref) + xs.i"
        , "      False"
        ]
      -- TODO Why is this coming up as 0 indexing depth?  Should be 1.
      ann `shouldBe` OccInfo (UsageInfo 1 (0,Unbounded))
    it "understands index-defining bindings" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10 | Fin 3) => Float = unreachable ()"
        , "  for i."
        , "    j = Left i"
        , "    xs.j"
        ]
      ann `shouldBe` OccInfo (UsageInfo 1 (1,Bounded 1))
    it "understands indexing by literals" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10 | Fin 3) => Float = unreachable ()"
        , "  (xs.(0@_), xs.(0@_))"
        ]
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Bounded 2))
    it "is conservative about distict literal indices" do
      ann <- analyze cfg env
        [ ":p"
        , "  xs : (Fin 10 | Fin 3) => Float = unreachable ()"
        , "  (xs.(0@_), xs.(1@_))"
        ]
      -- TODO In this case, we should be able to detect non-collision of
      -- indexing by 0 and by 1; but assuming they may collide is safe.
      ann `shouldBe` OccInfo (UsageInfo 2 (1,Bounded 2))
