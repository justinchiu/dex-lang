-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}

module SaferNames.Simplify
  ( simplifyModule, splitSimpModule, applyDataResults) where

import Control.Category ((>>>))
import Control.Monad
import Control.Monad.Identity
import Control.Monad.Reader
import Data.Maybe
import Data.Foldable (toList)
import Data.Functor
import Data.List (partition, elemIndex)
import Data.Graph (graphFromEdges, topSort)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import GHC.Stack

import Err
import PPrint
import Util

import SaferNames.Name
import SaferNames.Builder
import SaferNames.Syntax
import SaferNames.Type

-- === simplification monad ===

class (Builder2 m, EnvReader AtomSubstVal m) => Simplifier m

newtype SimplifyM (i::S) (o::S) (a:: *) = SimplifyM
  { runSimplifyM' :: EnvReaderT AtomSubstVal (BuilderT HardFailM) i o a }
  deriving ( Functor, Applicative, Monad, ScopeReader, BindingsExtender
           , BindingsReader, EnvReader AtomSubstVal, MonadFail)

runSimplifyM :: Distinct n => Bindings n -> SimplifyM n n (e n) -> e n
runSimplifyM bindings cont =
  withImmutEvidence (toImmutEvidence bindings) $
    runHardFail $
      runBuilderT bindings $
        runEnvReaderT idEnv $
          runSimplifyM' cont

instance Simplifier SimplifyM

instance Fallible (SimplifyM i o) where

-- TODO: figure out why we can't derive this one (here and elsewhere)
instance Builder (SimplifyM i) where
  emitDecl hint ann expr = SimplifyM $ emitDecl hint ann expr
  buildScoped cont = SimplifyM $ EnvReaderT $ ReaderT \env ->
    buildScoped $ runEnvReaderT (inject env) (runSimplifyM' cont)

-- === Top level ===

simplifyModule :: Distinct n => Bindings n -> Module n -> Module n
simplifyModule bindings (Module Core decls result) = runSimplifyM bindings do
  Immut <- return $ toImmutEvidence bindings
  DistinctAbs decls' result' <-
    buildScoped $ simplifyDecls decls $
      substEvaluatedModuleM result
  return $ Module Simp decls' result'
simplifyModule _ (Module ir _ _) = error $ "Expected Core, got: " ++ show ir

type AbsEvaluatedModule n = Abs (Nest (NameBinder AtomNameC)) EvaluatedModule n

splitSimpModule :: Distinct n => Bindings n -> Module n
                -> (Block n , AbsEvaluatedModule n)
splitSimpModule bindings (Module _ decls result) = do
  let (vs, recon) = captureClosure decls result
  let result = Atom $ ProdVal $ map Var vs
  let block = runHardFail $ runBindingsReaderT bindings $
                refreshAbsM (Abs decls result) \decls' result' ->
                  makeBlock decls' result'
  (block, recon)

applyDataResults :: Distinct n => Bindings n
                 -> AbsEvaluatedModule n -> Atom n
                 -> EvaluatedModule n
applyDataResults bindings (Abs bs evaluated) x =
  runHardFail $ runBindingsReaderT bindings $
    runEnvReaderT idEnv do
      xs <- getUnpacked $ inject x
      extendEnv (bs @@> map SubstVal xs) $
        substEvaluatedModuleM evaluated

-- === All the bits of IR  ===

simplifyDecl ::  (Emits o, Simplifier m) => Decl i i' -> m i' o a -> m i o a
simplifyDecl (Let b (DeclBinding ann _ expr)) cont = case ann of
  NoInlineLet -> do
    x <- simplifyStandalone expr
    v <- emitDecl (getNameHint b) NoInlineLet (Atom x)
    extendEnv (b@>Rename v) cont
  _ -> do
    x <- simplifyExpr expr
    extendEnv (b@>SubstVal x) cont

simplifyDecls ::  (Emits o, Simplifier m) => Nest Decl i i' -> m i' o a -> m i o a
simplifyDecls Empty cont = cont
simplifyDecls (Nest decl rest) cont = simplifyDecl decl $ simplifyDecls rest cont

simplifyStandalone :: Simplifier m => Expr i -> m i o (Atom o)
simplifyStandalone (Atom (Lam (LamExpr (LamBinder b argTy arr Pure) body))) = do
  argTy' <- substM argTy
  buildPureLam (getNameHint b) arr argTy' \v ->
    extendEnv (b@>Rename v) $ simplifyBlock body
simplifyStandalone block =
  error $ "@noinline decorator applied to non-pure-function" ++ pprint block

simplifyExpr :: (Emits o, Simplifier m) => Expr i -> m i o (Atom o)
simplifyExpr expr = case expr of
  App f x -> do
    x' <- simplifyAtom x
    f' <- simplifyAtom f
    simplifyApp f' x'
  Op  op  -> mapM simplifyAtom op >>= simplifyOp
  Hof hof -> simplifyHof hof
  Atom x  -> simplifyAtom x
  Case e alts resultTy -> do
    e' <- simplifyAtom e
    resultTy' <- substM resultTy
    undefined

simplifyApp :: (Emits o, Simplifier m) => Atom o -> Atom o -> m i o (Atom o)
simplifyApp f x = case f of
  Lam (LamExpr b body) ->
    dropSubst $ extendEnv (b@>SubstVal x) $ simplifyBlock body
  DataCon printName namedDef@(defName, _) params con xs -> do
    DataDef _ paramBs _ <- getDataDef defName
    let (params', xs') = splitAt (nestLength paramBs) $ params ++ xs ++ [x]
    return $ DataCon printName namedDef params' con xs'
  ACase e alts ~(Pi ab) -> undefined
  TypeCon def params -> return $ TypeCon def params'
     where params' = params ++ [x]
  _ -> liftM Var $ emit $ App f x

simplifyAtom :: (Emits o, Simplifier m) => Atom i -> m i o (Atom o)
simplifyAtom atom = case atom of
  Var v -> do
    env <- getEnv
    case env ! v of
      SubstVal x -> return x
      Rename v' -> do
        AtomNameBinding bindingInfo <- lookupBindings v'
        case bindingInfo of
          LetBound (DeclBinding ann _ (Atom x))
            | ann /= NoInlineLet -> dropSubst $ simplifyAtom x
          _ -> return $ Var v'
  Lam _ -> substM atom
  Pi  _ -> substM atom
  Con con -> Con <$> mapM simplifyAtom con
  TC  tc  -> TC  <$> mapM simplifyAtom tc
  Eff _ -> substM atom
  TypeCon (defName, def) params -> do
    defName' <- substM defName
    def'     <- substM def
    TypeCon (defName', def') <$> mapM simplifyAtom params
  DataCon printName (defName, def) params con args -> do
    defName' <- substM defName
    def'     <- substM def
    DataCon printName (defName', def') <$> mapM simplifyAtom params
                                       <*> pure con <*> mapM simplifyAtom args
  Record items -> Record <$> mapM simplifyAtom items
  DataConRef _ _ _ -> error "Should only occur in Imp lowering"
  BoxedRef _ _ _   -> error "Should only occur in Imp lowering"
  ProjectElt idxs v -> getProjection (toList idxs) <$> simplifyAtom (Var v)

simplifyOp :: (Emits o, Simplifier m) => Op o -> m i o (Atom o)
simplifyOp op = case op of
  _ -> emitOp op

data Reconstruct n =
   IdentityRecon
 | LamRecon (NaryAbs AtomNameC Atom n)

simplifyLam :: (Emits o, Simplifier m) => LamExpr i -> m i o (LamExpr o, Reconstruct o)
simplifyLam lam = simplifyLams 1 lam

simplifyLams :: Simplifier m => Int -> LamExpr i -> m i o (LamExpr o, Reconstruct o)
simplifyLams n lam = fromPairE <$> liftImmut do
  Abs bs body <- return $ fromNaryLam n lam
  refreshBinders bs \bs' -> do
    DistinctAbs decls result <- buildScoped $ simplifyBlock body
    -- TODO: this would be more efficient if we had the two-computation version of buildScoped
    extendBindings (toBindingsFrag decls) do
      (resultData, recon) <- defuncAtom (toScopeFrag bs' >>> toScopeFrag decls) result
      block <- makeBlock decls $ Atom result
      return $ PairE (toNaryLam $ Abs bs' block) recon

fromNaryLam :: Int -> LamExpr n -> Abs (Nest LamBinder) Block n
fromNaryLam 1 (LamExpr b block) = Abs (Nest b Empty) block
fromNaryLam n _ = undefined
fromNaryLam _ _ = error "only defined for n >= 1"

toNaryLam :: Abs (Nest LamBinder) Block n -> LamExpr n
toNaryLam (Abs Empty _) = error "not defined for nullary lambda"
toNaryLam (Abs (Nest b Empty) block) = LamExpr b block

defuncAtom :: BindingsReader m => ScopeFrag n l -> Atom l -> m l (Atom l, Reconstruct n)
defuncAtom frag x = do
  xTy <- getType x
  if isData xTy
    then return (x, IdentityRecon)
    else error "todo"

isData :: Type n -> Bool
isData _ = True  -- TODO!

simplifyHof :: (Emits o, Simplifier m) => Hof i -> m i o (Atom o)
simplifyHof hof = case hof of
  For d ~(Lam lam) -> do
    (lam', recon) <- simplifyLam lam
    ans <- liftM Var $ emit $ Hof $ For d $ Lam lam'
    case recon of
      IdentityRecon -> return ans
      LamRecon _ -> undefined

simplifyBlock :: (Emits o, Simplifier m) => Block i -> m i o (Atom o)
simplifyBlock (Block _ decls result) = simplifyDecls decls $ simplifyExpr result

-- === instances ===

instance GenericE Reconstruct where
  type RepE Reconstruct = EitherE UnitE (NaryAbs AtomNameC Atom)
  toE = undefined
  fromE = undefined

instance InjectableE Reconstruct
instance HoistableE  Reconstruct
instance SubstE Name Reconstruct
instance SubstE AtomSubstVal Reconstruct
instance AlphaEqE Reconstruct
