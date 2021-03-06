{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Lasca.Infer (
  generalizeType,
  typeCheck,
  inferExpr,
  inferExprDefault,
  showTypeError,
  showPretty,
  defaultTyenv
) where

import Prelude hiding (foldr)

import Lasca.Type
import Lasca.Syntax

import Control.Monad.State
import Control.Monad.Except
import qualified Control.Lens as Lens
import Control.Lens.TH
import Control.Lens.Operators

import Data.Monoid
import qualified Data.List as List
import Data.Foldable (foldr)
import Data.Maybe
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Set (Set)
import qualified Data.Set as Set
import Debug.Trace as Debug
import Text.Printf
import Data.Text.Prettyprint.Doc
import Data.Text.Prettyprint.Doc.Render.String

newtype TypeEnv = TypeEnv (Map Name Type) deriving (Semigroup, Monoid)


instance Pretty TypeEnv where
    pretty (TypeEnv subst) = "Γ = {" <+> line <+> indent 2 elems <+> "}"
      where elems = vcat $ map (\(name, scheme) -> pretty name <+> ":" <+> pretty scheme) (Map.toList subst)

instance Show TypeEnv where
    show (TypeEnv subst) = "Γ = {\n" ++ elems ++ "}"
      where elems = List.foldl' (\s (name, scheme) -> s ++ show name ++ " : " ++ showPretty scheme ++ "\n") "" (Map.toList subst)

showPretty :: Pretty a => a -> String
showPretty = renderString . layoutPretty defaultLayoutOptions . pretty

data InferState = InferState {_count :: Int, _current :: Expr}
makeLenses ''InferState

type Infer = ExceptT TypeError (State InferState)
type Subst = Map TVar Type

data TypeError
    = UnificationFail Expr Type Type
    | InfiniteType Expr TVar Type
    | UnboundVariable Expr Name
    | UnificationMismatch Expr [Type] [Type]
    | ArityMismatch Expr Type Int Int
    deriving (Eq, Ord, Show)

showTypeError typeError = case typeError of
    UnificationFail expr expected infered ->
        printf "%s: Type error: expected type %s but got %s in expression %s"
          (show $ exprPosition expr) (show expected) (show infered) (show expr)
    InfiniteType expr tvar tpe ->
        printf "%s: Type error: infinite type %s %s in expression %s"
          (show $ exprPosition expr) (show tvar) (show tpe) (show expr)
    UnboundVariable expr symbol ->
        printf "%s: Type error: unknown symbol %s in expression %s"
          (show $ exprPosition expr) (show symbol) (show expr)
    UnificationMismatch expr expected infered ->
        printf "%s: Type error: expected type %s but got %s in expression %s"
          (show $ exprPosition expr) (show expected) (show infered) (show expr)
    ArityMismatch expr tpe expected actual ->
        printf "%s: Call error: applying %s arguments to a function of type %s with arity %s in expression %s"
          (show $ exprPosition expr) (show actual) (show tpe) (show expected) (show expr)

class Substitutable a where
    substitute :: Subst -> a -> a
    ftv   :: a -> Set TVar

instance Substitutable Type where
    {-# INLINE substitute #-}
    substitute _ (TypeIdent a)       = TypeIdent a
    substitute s t@(TVar a)     = Map.findWithDefault t a s
    substitute s (t1 `TypeFunc` t2) = substitute s t1 `TypeFunc` substitute s t2
    substitute s (TypeApply t args) = TypeApply (substitute s t) (substitute s args)
    substitute s (Forall tvars t) = Forall tvars $ substitute s' t
                               where s' = foldr Map.delete s tvars
--    substitute s t = error $ "Wat? " ++ show s ++ ", " ++ show t

    ftv TypeIdent{}         = Set.empty
    ftv (TVar a)       = Set.singleton a
    ftv (t1 `TypeFunc` t2) = ftv t1 `Set.union` ftv t2
    ftv (TypeApply t args)       = ftv args
    ftv (Forall as t) = ftv t `Set.difference` Set.fromList as

instance Substitutable a => Substitutable [a] where
    {-# INLINE substitute #-}
    substitute s a = (fmap . substitute) s a
    ftv   = foldr (Set.union . ftv) Set.empty

instance Substitutable TypeEnv where
    {-# INLINE substitute #-}
    substitute s (TypeEnv env) =  TypeEnv $ Map.map (substitute s) env
    ftv (TypeEnv env) = ftv $ Map.elems env


nullSubst :: Subst
nullSubst = Map.empty

compose :: Subst -> Subst -> Subst
s1 `compose` s2 = Map.map (substitute s1) s2 `Map.union` s1

unify ::  Type -> Type -> Infer Subst
unify (l `TypeFunc` r) (l' `TypeFunc` r')  = do
    s1 <- unify l l'
    s2 <- unify (substitute s1 r) (substitute s1 r')
    return (s2 `compose` s1)

unify TypeAny t = return nullSubst
unify t TypeAny = return nullSubst
unify t (TVar a) = bind a t
unify (TVar a) t = bind a t
unify (TypeIdent a) (TypeIdent b) | a == b = return nullSubst
unify (TypeApply (TypeIdent lhs) largs) (TypeApply (TypeIdent rhs) rargs) | lhs == rhs = unifyList largs rargs
unify t1 t2 = do
    expr <- gets _current
    let pos = exprPosition expr
    throwError $ UnificationFail expr t1 t2

unifyList :: [Type] -> [Type] -> Infer Subst
-- unifyList x y | traceArgs ["unifyList", show x, show y] = undefined
unifyList [TVar _] [] = return nullSubst
unifyList [] [] = return nullSubst
unifyList (t1 : ts1) (t2 : ts2) = do
    su1 <- unify t1 t2
    su2 <- unifyList (substitute su1 ts1) (substitute su1 ts2)
    return (su2 `compose` su1)
unifyList t1 t2 = do
    expr <- gets _current
    throwError $ UnificationMismatch expr t1 t2

bind ::  TVar -> Type -> Infer Subst
bind a t
  | t == TVar a     = return nullSubst
  | occursCheck a t = do
      expr <- gets _current
      throwError $ InfiniteType expr a t
  | otherwise       = return $ Map.singleton a t

occursCheck ::  Substitutable a => TVar -> a -> Bool
occursCheck a t = a `Set.member` ftv t

letters :: [Text]
letters = do
    i <- [1..]
    s <- flip replicateM ['a'..'z'] i
    return $ T.pack s

fresh :: Infer Type
fresh = do
    s <- get
    count += 1
    return $ TVar $ TV (T.pack $ show $ _count s)

runInfer :: Expr -> Infer (Subst, Type) -> Either TypeError (Type, Expr)
runInfer e m =
    case runState (runExceptT m) (initState e) of
        (Left err, st)  -> Left err
        (Right res, st) -> do
            let (schema, expr) = closeOver res $ _current st
            Right (schema, {-Debug.trace (show expr)-} expr)

closeOver :: (Subst, Type) -> Expr -> (Type, Expr)
closeOver (sub, ty) e = do
    let e' = substituteAll sub e
    let sc = generalizeWithTypeEnv emptyTyenv (substitute sub ty)
    let (normalized, mapping) = normalize sc
    let e'' = closeOverInner mapping e'
    let e''' = Lens.set (metaLens.exprType) normalized e''
    (normalized, {-Debug.trace ("Full type for" ++ show e''')-} e''')

substituteAll sub e = updateMeta f e
  where f meta = meta { _exprType = substitute sub (_exprType meta) }


closeOverInner mapping e = do
  {-Debug.trace (printf "Closing over inner %s with mapping %s" (show e) (show mapping)) $-} updateMeta f e
  where
    schema = getExprType e
    f meta = case _exprType meta of
        Forall tv t -> meta { _exprType = Forall tv $ substype schema t mapping }
        t -> meta

updateMeta f e =
    case e of
        EmptyExpr -> e
        Literal meta lit -> Literal (f meta) lit
        Ident meta name -> Ident (f meta) name
        Apply meta expr exprs -> Apply (f meta) (updateMeta f expr) (map (updateMeta f) exprs)
        Lam meta name expr -> Lam (f meta) name (updateMeta f expr)
        Select meta tree expr -> Select (f meta) (updateMeta f tree) (updateMeta f expr)
        Match meta expr cases -> Match (f meta) (updateMeta f expr) (map (\(Case pat e) -> Case pat (updateMeta f e)) cases)
        this@Closure{} -> this
        If meta cond tr fl -> If (f meta) (updateMeta f cond) (updateMeta f tr) (updateMeta f fl)
        Let rec meta name tpe expr body -> Let rec (f meta) name tpe (updateMeta f expr) (updateMeta f body)
        Array meta exprs -> Array (f meta) (map (updateMeta f) exprs)
        this@Data{} -> this
        Module{} -> e
        Import{} -> e

-- For now don't allow Forall inside Forall
normalize schema@(Forall ts body) =
    let res = (Forall (fmap snd ord) (normtype body), ord)
    in {-Debug.trace (show res)-} res
  where
    ord = let a = zip (List.nub $ fv body) (fmap TV letters)
          in {-Debug.trace ("mapping = " ++ show a)-} a   -- from [b, c, c, d, f, e, g] -> [a, b, c, d, e, f]

    fv (TVar a)   = [a]
    fv (TypeFunc a b) = fv a ++ fv b
    fv (TypeIdent _)   = []
    fv (TypeApply t [])       = error "Should not be TypeApply without arguments!" -- TODO use NonEmpty List?
    fv (TypeApply t args)   = fv t ++ (args >>= fv)
    fv Forall{} = error ("Forall inside forall: " ++ show schema)

    normtype (TypeFunc a b)  = TypeFunc  (normtype a) (normtype b)
    normtype (TypeApply a b) = TypeApply (normtype a) (map normtype b)
    normtype (TypeIdent a)   = TypeIdent a
    normtype (TVar a)        =
        case lookup a ord of
            Just x -> {-Debug.trace (printf "lookup for %s, found %s" (show a) (show x))-} (TVar x)
            Nothing -> error $ printf "Type variable %s not in signature %s" (show a) (show schema)
    normtype Forall{} = error ("Forall inside forall: " ++ show schema)
normalize t = (t, [])

substype schema (TypeFunc a b)  ord = TypeFunc  (substype schema a ord) (substype schema b ord)
substype schema (TypeApply a b) ord = TypeApply (substype schema a ord) b
substype schema (TypeIdent a)   ord = TypeIdent a
substype schema t@(TVar a)        ord =
    case lookup a ord of
        Just x -> TVar x
        Nothing -> t
substype schema t@Forall{} ord = error ("Forall inside forall: " ++ show t)


initState :: Expr -> InferState
initState e = InferState { _count = 0, _current = e}

extend :: TypeEnv -> (Name, Type) -> TypeEnv
extend (TypeEnv env) (x, s) = TypeEnv $ Map.insert x s env

emptyTyenv = TypeEnv Map.empty

defaultTyenv :: TypeEnv
defaultTyenv = TypeEnv builtinFunctions

instantiate :: Type -> Infer Type
instantiate (Forall as t) = do
    as' <- mapM (const fresh) as
    let s = Map.fromList $ zip as as'
    return $ substitute s t
instantiate t = return t

generalizeWithTypeEnv :: TypeEnv -> Type -> Type
generalizeWithTypeEnv env t  = case Set.toList $ ftv t `Set.difference` ftv env of
    [] -> t
    vars -> Forall vars t

generalizeType tpe = generalizeWithTypeEnv emptyTyenv tpe

ops = Map.fromList [
    ("and", TypeBool ==> TypeBool ==> TypeBool),
    ("or", TypeBool ==> TypeBool ==> TypeBool)
    ]

--lookupEnv :: TypeEnv -> String -> Infer (Subst, Type)
lookupEnv (TypeEnv env) x =
    case Map.lookup x env of
        Nothing -> do
            expr <- gets _current
            Debug.traceM $ printf "Env %s" (show env)
            throwError $ UnboundVariable expr x
        Just s  -> do t <- instantiate s
                      return (nullSubst, t)

setCurrentExpr :: Expr -> Infer ()
setCurrentExpr e = modify (\s -> s {_current = e })

infer :: Ctx -> TypeEnv -> Expr -> Infer (Subst, Type)
infer ctx env ex = case ex of
    Ident meta x -> do
        (s, t) <- lookupEnv env x
--        traceM $ printf "Ident %s: %s = %s" (show x) (show t) (show s)
        setCurrentExpr $ Ident (meta `withType` t) x
        return (s, t)

    Apply meta (Ident _ op) [e1, e2] | op `Map.member` ops -> do
        (s1, t1) <- infer ctx env e1
        (s2, t2) <- infer ctx env e2
        tv <- fresh
        s3 <- unify (TypeFunc t1 (TypeFunc t2 tv)) (ops Map.! op)
        return (s1 `compose` s2 `compose` s3, substitute s3 tv)

    this@(Apply meta expr args) -> do
        tv <- fresh
        (s1, exprType) <- infer ctx env expr
        expr1 <- gets _current
        let exprArity = funcTypeArity exprType
        let argLen = length args
        {- Check we don't partially apply a function.
           Currently we only support fully applied function calls.

           Note, argLen /= exprArity is a valid scenario
           exptType can be a free type variable

           def foo(f) = f(1, 2)

           here exprType would be TV "1", and argLen = 2
           We should infer f: Int -> Int -> a, and foo: (Int -> Int -> a) -> a
           Same applies to recursive calls.
        -}
        if argLen < exprArity then do
--            Debug.traceM $ printf "%s subst %s env %s" (show exprType) (show s1) (show env)
            throwError $ ArityMismatch this exprType exprArity argLen
        else do
            (s2, applyType, args') <- inferPrim ctx env args exprType
            let subst = s2 `compose` s1
            let subApplyType = substitute subst applyType
            let subExprType = substitute subst exprType
--            Debug.traceM $ printf "%s === %s, subst %s" (show subExprType) (show subApplyType) (show subst)
            setCurrentExpr $ Apply (meta `withType` subApplyType) expr1 args'
            return (subst, subApplyType)

    -- toplevel val definition: Pi = 3.1415
    Let False meta x tpe e1 EmptyExpr -> do
        (s1, t1) <- infer ctx env e1
        e1' <- gets _current
--        Debug.traceM $ printf "Let %s = %s, type %s, subst %s, env %s" (show x) (show e1) (show t1) (show s1) (show env)
        setCurrentExpr $ Let False (meta `withType` t1) x tpe e1' EmptyExpr
--        when (not $ Set.null $ ftv s1) $ error $ printf "%s: Global val %s has free type variables: !" (showPosition meta) (show x) (ftv s1)
        return (s1, t1)

    -- inner non recursive let binding: a = 15 or l = { a -> 15 }
    Let False meta x tpe e1 e2 -> do
        (s1, t1) <- infer ctx env e1
        e1' <- gets _current
        let env' = substitute s1 env
            t'   = generalizeWithTypeEnv env' t1
        (s2, t2) <- infer ctx (env' `extend` (x, t')) e2
        e2' <- gets _current
        setCurrentExpr $ Let False (meta `withType` t2) x tpe e1' e2'
        let subst = s2 `compose` s1
    --    traceM $ printf "let %s: %s in %s = %s" x (show $ substitute subst t1) (show t2) (show subst)
        return (subst, t2)
        
    -- Example: external def foo(a: Int, b: String): Bool = "builtin_foo"
    Let True meta x tpe e1 e2 | meta^.isExternal -> do
        let (args, _) = uncurryLambda e1
            argToType (Arg _ t) = t
            ts = map argToType args
            t = generalizeType $ foldr (==>) tpe ts
        return (nullSubst, t)

    -- Example: def foo(a: Int, b: String): Bool = false
    Let True meta name tpe e1 e2 -> do
        -- functions are recursive, so do Fixpoint for inference
        let nameArg = Arg name TypeAny
        let curried = Lam meta nameArg e1
        tv <- fresh
        tv1 <- fresh
        -- fixpoint
        (s1, ttt) <- infer ctx env curried
        let composedType = substitute s1 (ttt ==> tv1)
--            traceM $ "composedType " ++ show composedType
        s2 <- unify composedType ((tv ==> tv) ==> tv)
        let (s, t) = (s2 `compose` s1, substitute s2 tv1)
        e' <- gets _current
        let (Lam _ _ uncurried) = e'

        (subst, letType, body) <- do
            case e2 of
                -- toplevel def
                EmptyExpr -> return (s, t, e2)
                -- inner def
                _ -> do let env' = substitute s env
                            t'   = generalizeWithTypeEnv env' t
                        (s2, t2) <- infer ctx (env' `extend` (name, t')) e2
                        e2' <- gets _current
                        return (s2 `compose` s, t2, e2')
                
        -- Debug.traceM $ printf "def %s :: %s" (show name) (show letType)
        setCurrentExpr $ Let True (meta `withType` letType) name tpe uncurried body
        let (args, _) = uncurryLambda e1
--        traceM $ printf "def %s(%s): %s, subs: %s" (show name) (List.intercalate "," $ map show args) (show letType) (show subst)
        return (subst, letType)

    If meta cond tr fl -> do

        condTv <- fresh
        (s1, t1) <- infer ctx env cond
        s2 <- unify (substitute s1 t1) TypeBool
        let substCond = s2 `compose` s1
        cond' <- gets _current

        tv <- fresh
        let env' = substitute substCond env
        (s3, trueType) <- infer ctx env' tr
        s4 <- unify (substitute s3 trueType) tv
        let substTrue = s4 `compose` s3
        tr' <- gets _current

        let env'' = substitute substTrue env'
        (s5, falseType) <- infer ctx env'' fl
        s6 <- unify (substitute s5 falseType) tv
        let substFalse = s6 `compose` s5
        fl' <- gets _current

        let subst = substFalse `compose` substTrue `compose` substCond
        let resultType = substitute subst tv

        setCurrentExpr $ If (meta `withType` resultType) cond' tr' fl'
    --    traceM $ printf "if %s then %s else %s: %s"  (show substCond) (show substTrue) (show substFalse) (show resultType)
        return (subst, resultType)

    Lam meta arg@(Arg x argType) e -> do
        case argType of
            TypeAny -> do
                tv <- fresh
                let env' = env `extend` (x, tv)
                (s1, t1) <- infer ctx env' e
                e' <- gets _current
                let resultType = substitute s1 tv ==> t1
                setCurrentExpr $ Lam (meta `withType` resultType) arg e'
                return (s1, resultType)
            _ -> do
                let generalizedArgType = generalizeWithTypeEnv env argType -- FIXME: should not generalize it here
                let env' = env `extend` (x, argType)
                (s1, t1) <- infer ctx env' e
                e' <- gets _current
                let resultType = substitute s1 argType ==> t1
                setCurrentExpr $ Lam (meta `withType` resultType) arg e'
                return (s1, resultType)


    Data meta name tvars constructors -> error $ "Shouldn't happen! " ++ show meta
    Select meta tree expr -> do
        (s, t) <- infer ctx env (Apply meta expr [tree])
        (Apply _ e' [tree']) <- gets _current
        setCurrentExpr $ Select (meta `withType` t) tree' e'
        return (s, t)

    Array meta exprs -> do
        tv <- fresh
        let tpe = foldr (\_ t -> tv ==> t) (TypeArray tv) exprs
        (subst, t, exprs') <- inferPrim ctx env exprs tpe
        setCurrentExpr $ Array (meta `withType` t) exprs'
        return (subst, t)

    Match meta expr cases -> do
        tv <- fresh
        {-
          Consider data Role = Admin | Group(id: Int)
                   data User = Person(name: String, role: Role)
                   match Person("God", Admin) { | Person(_ ,Group(i)) -> true }

                   unify: User -> User -> Bool
                   unify: String -> Role
                            _       Group(i)
                                      Int
                                       i
        -}
        (s1, te) <- infer ctx env expr
        e' <- gets _current
  --      Debug.traceM $ "Matching expression type " ++ show te
        (s2, te', exprs') <- foldM (inferCase te) (s1, tv, []) cases
        let cases' = map (\((Case pat e), e') -> Case pat e') (zip cases exprs')
  --      Debug.traceM $ printf "Matching result type %s in %s" (show te') (show s2)
        setCurrentExpr $ Match (meta `withType` te') e' cases'
        return (s2, te')
      where
        inferCase :: Type -> (Subst, Type, [Expr]) -> Case -> Infer (Subst, Type, [Expr])
        inferCase expectedType (s1, expectedResult, exprs) (Case pat e) = do
            (env1, patType) <- getPatType env pat   -- (name -> String, User)
            su <- unify expectedType patType
            let env2 = substitute su env1
  --              Debug.traceM $ printf "unify expectedType %s patType %s = %s %s" (show expectedType) (show patType) (show su) (show env2)
            (s2, te) <- infer ctx env2 e
            s3 <- unify expectedResult te
  --              Debug.traceM $ printf "s1 = %s, s2 = %s, s3 = %s, combined = %s" (show s1) (show s2) (show s3) (show (s3 `compose` s2 `compose` su `compose` s1))
            let resultType = substitute s3 te
            e' <- gets _current
            return (s3 `compose` s2 `compose` su `compose` s1, resultType, exprs ++ [e'])

        getPatType :: TypeEnv -> Pattern -> Infer (TypeEnv, Type)
        getPatType env pat = case pat of
            WildcardPattern -> do
                tv <- fresh
                return (env, tv)       -- (0, a)
            (VarPattern n)    -> do                  -- (n -> a, a)
                tv <- fresh
                return (env `extend` (n, tv), tv)
            (LitPattern lit) -> return (env, litType lit)   -- (0, litType)
            (ConstrPattern name args) -> do          -- (name -> a, a -> User)
                (_, t) <- lookupEnv env name           -- t = String -> User
                result <- fresh                        -- result = a

                let inferArgs (accEnv, accType) pat = do
                      (e, t) <- getPatType env pat
                      return (accEnv `mappend` e, t ==> accType)

                (env', pattype) <- foldM inferArgs (env, result) (reverse args)
  --                  Debug.traceM $ "Holy shit " ++ show env' ++ ", " ++ show pattype
                subst <- unify pattype t
                let restpe = substitute subst result
                let env'' =  substitute subst env'
  --                  Debug.traceM $ printf "restpe = %s" (show restpe)
                return (env'', restpe)                   -- (name -> String, User)



                

    Literal meta lit -> do
        let tpe = litType lit
        setCurrentExpr $ Literal (meta `withType` tpe) lit
        return (nullSubst, tpe)
    e -> error ("Wat? " ++ show e)

litType (IntLit _)    = TypeInt
litType (FloatLit _)  = TypeFloat
litType (BoolLit _)   = TypeBool
litType (StringLit _) = TypeString
litType UnitLit       = TypeUnit


inferPrim :: Ctx -> TypeEnv -> [Expr] -> Type -> Infer (Subst, Type, [Expr])
inferPrim ctx env l t = do
    tv <- fresh
    (s1, tf, exprs) <- foldM inferStep (nullSubst, id, []) l
    let composedType = substitute s1 (tf tv)
--    Debug.traceM $ "composedType " ++ show composedType
    s2 <- unify composedType t
    return (s2 `compose` s1, substitute s2 tv, reverse exprs)
  where
    inferStep (s, tf, exprs) exp = do
        (s', t) <- infer ctx (substitute s env) exp
        exp' <- gets _current
        return (s' `compose` s, tf . TypeFunc t, exp' : exprs)

inferExpr :: Ctx -> TypeEnv -> Expr -> Either TypeError (Type, Expr)
inferExpr ctx env e = runInfer e $ infer ctx env e

inferExprDefault :: Ctx -> Expr -> Either TypeError (Type, Expr)
inferExprDefault ctx expr = inferExpr ctx defaultTyenv expr

inferTop :: Ctx -> TypeEnv -> [(Name, Expr)] -> Either TypeError (TypeEnv, [Expr])
inferTop ctx env [] = Right (env, [])
inferTop ctx env ((name, ex):xs) = case inferExpr ctx env ex of
    Left err -> Left err
    Right (ty, ex') -> case inferTop ctx (extend env (name, ty)) xs of
                            Left err -> Left err
                            Right (ty, exs) -> Right (ty, ex' : exs)

data InferStuff = InferStuff { _names :: [(Name, Expr)] }
makeLenses ''InferStuff

collectNames exprs = forM_ exprs $ \expr -> case expr of
    Let _ _ name _ _ EmptyExpr -> do
        names %= (++ [(name, expr)])
        return ()
    _ -> return ()

createTypeEnvironment exprs = List.foldl' folder [] exprs
  where
    folder types (Data _ typeName tvars constrs) = do
        let genTypes :: DataConst -> [(Name, Type)]
            genTypes (DataConst name args) =
                let tpe = generalizeType $ foldr (\(Arg _ tpe) acc -> tpe ==> acc) dataTypeIdent args
                    accessors = map (\(Arg n tpe) -> (n, generalizeType $ TypeFunc dataTypeIdent tpe)) args
                in (name, tpe) : accessors
        let constructorsTypes = constrs >>= genTypes
        types ++ constructorsTypes
      where
        dataTypeIdent = case tvars of
            [] -> TypeIdent typeName
            tvars -> TypeApply (TypeIdent typeName) (map TVar tvars)
    folder _ e = error ("createTypeEnvironment should only be called with Data declarations, but was called on " ++ show e)

data Node = Node {
    nodeName :: Name,
    calledBy :: Set Name
} deriving (Show, Eq, Ord)

data Deps = Deps {
    _modName :: Name,
    _curFuncCalls :: Set Name,
    _nodes :: Map Name Node
} deriving (Show, Eq, Ord)
makeLenses ''Deps

anal exprs = execState (traverseTree collectDeps exprs) (
    Deps { _modName = Name "undefined", _curFuncCalls = Set.empty, _nodes = Map.empty })

inModule name mod = nameToList mod `List.isPrefixOf` nameToList name

collectDeps :: Expr -> State Deps ()
collectDeps expr = do
    state <- get
    case expr of
        Module _ name -> modName .= name
        Ident _ name | inModule name (state^.modName) -> do
--            Debug.traceM $ printf "%s in module %s" (show name) (show (state^.modName))
            curFuncCalls %= Set.insert name
        Let _ _ name _ _ EmptyExpr -> do
--            Debug.traceM $ printf "Val %s in module %s" (show name) (show (state^.modName))
            let mapping = state^.nodes
                calls = Set.toList $ state^.curFuncCalls
                emptyNode n = Node { nodeName = n, calledBy = Set.empty }
                combine2 new Nothing = Just new
                combine2 new (Just old) = Just $ old { calledBy = Set.union (calledBy old) (calledBy new) }

            nodes %= Map.alter (combine2 (emptyNode name)) name
            state <- get
--            Debug.traceM $ printf "Node for %s: %s" (show name) (show (Map.lookup name (state^.nodes)))
            forM calls $ \call ->
                nodes %= Map.alter (combine2 (Node { nodeName = call, calledBy = Set.singleton name })) call
            curFuncCalls .= Set.empty
            return ()    
        _ -> return ()
    return ()

linear nodes names = do
    let r = List.foldl' (\p n -> p ++ dependencies n) [] names
        rr = reverse . List.nub . reverse
--        rr = List.nub
    rr r
  where
    dependencies name = let cBy = calledBy (fromMaybe (error $ show name) $ Map.lookup name nodes)
                            cBy1 = Set.delete name cBy
                        in  List.foldl' (\p n -> p ++ dependencies n) [name] cBy1


--typeCheck :: Ctx -> [Expr] -> Either TypeError (TypeEnv, [Expr])
typeCheck ctx exprs = do
    -- TODO use flow analysis to find order of typing functions/vals and mutually recursive functions
    let stuff = execState (collectNames exprs) (InferStuff {_names = []})
    let namedExprs = stuff ^. names
    let dataConstructorsEnv = Map.fromList $ createTypeEnvironment (ctx^.dataDefs)
    let (TypeEnv te) = defaultTyenv
    let typeEnv = TypeEnv (Map.union te dataConstructorsEnv)

    let depanal = anal exprs
--    putStrLn $ printf "DepAnalisys: %s" (show depanal)
    let names = map fst namedExprs
--    print names
--    putStrLn $ printf "Linear: names %s" (show $ linear (_nodes depanal) names)
    let ordered = linear (_nodes depanal) names
    let mapping = Map.fromList namedExprs
    
    let orderedNamedExprs = ordered >>= (\n -> map (\r -> (n, r)) (maybeToList $ Map.lookup n mapping))
--    putStrLn $ "Ordered " ++ show orderedNamedExprs
    let res = inferTop ctx typeEnv orderedNamedExprs
    return $ fmap (\(typeEnv, exprs) -> (typeEnv, ctx^.dataDefs ++ exprs)) res

traverseTree :: Monad m => (Expr -> m a) -> [Expr] -> m [a]
traverseTree traverser exprs = sequence [traverseExpr traverser e | e <- exprs ]

traverseExpr :: Monad m => (Expr -> m a) -> Expr -> m a
traverseExpr traverser expr = case expr of
    Array meta exprs -> do
        mapM go exprs
        traverser expr
    Select meta tree expr -> do
        go tree
        go expr
        traverser expr
    If meta cond true false -> do
        go cond
        go true
        go false
        traverser expr
    Match meta ex cases -> do
        forM cases $ \(Case p expr) -> go expr
        traverser expr
    Let _ meta n _ e body -> do
        go e
        go body
        traverser expr
    Lam m a@(Arg n t) e -> do
        go e
        traverser expr
    Apply meta e args -> do
        go e
        mapM go args
        traverser expr
    e -> traverser e
    where go e = traverseExpr traverser e

isData Data{} = True
isData _ = False