{-# LANGUAGE OverloadedStrings #-}

module Language.Nano.Eval
  ( execFile, execString, execExpr
  , eval, lookupId, prelude
  , parse
  , env0
  )
  where

import Control.Exception (throw, catch)
import Language.Nano.Types
import Language.Nano.Parser
import Data.List (tail)

--------------------------------------------------------------------------------
execFile :: FilePath -> IO Value
--------------------------------------------------------------------------------
execFile f = (readFile f >>= execString) `catch` exitError

--------------------------------------------------------------------------------
execString :: String -> IO Value
--------------------------------------------------------------------------------
execString s = execExpr (parseExpr s) `catch` exitError

--------------------------------------------------------------------------------
execExpr :: Expr -> IO Value
--------------------------------------------------------------------------------
execExpr e = return (eval prelude e) `catch` exitError

--------------------------------------------------------------------------------
-- | `parse s` returns the Expr representation of the String s
--
-- >>> parse "True"
-- EBool True
--
-- >>> parse "False"
-- EBool False
--
-- >>> parse "123"
-- EInt 123
--
-- >>> parse "foo"
-- EVar "foo"
--
-- >>> parse "x + y"
-- EBin Plus (EVar "x") (EVar "y")
--
-- >>> parse "if x <= 4 then a || b else a && b"
-- EIf (EBin Le (EVar "x") (EInt 4)) (EBin Or (EVar "a") (EVar "b")) (EBin And (EVar "a") (EVar "b"))
--
-- >>> parse "if 4 <= z then 1 - z else 4 * z"
-- EIf (EBin Le (EInt 4) (EVar "z")) (EBin Minus (EInt 1) (EVar "z")) (EBin Mul (EInt 4) (EVar "z"))
--
-- >>> parse "let a = 6 * 2 in a /= 11"
-- ELet "a" (EBin Mul (EInt 6) (EInt 2)) (EBin Ne (EVar "a") (EInt 11))
--
-- >>> parseTokens "() (  )"
-- Right [LPAREN (AlexPn 0 1 1),RPAREN (AlexPn 1 1 2),LPAREN (AlexPn 3 1 4),RPAREN (AlexPn 6 1 7)]
--
-- >>> parse "f x"
-- EApp (EVar "f") (EVar "x")
--
-- >>> parse "(\\ x -> x + x) (3 * 3)"
-- EApp (ELam "x" (EBin Plus (EVar "x") (EVar "x"))) (EBin Mul (EInt 3) (EInt 3))
--
-- >>> parse "(((add3 (x)) y) z)"
-- EApp (EApp (EApp (EVar "add3") (EVar "x")) (EVar "y")) (EVar "z")
--
-- >>> parse <$> readFile "tests/input/t1.hs"
-- EBin Mul (EBin Plus (EInt 2) (EInt 3)) (EBin Plus (EInt 4) (EInt 5))
--
-- >>> parse <$> readFile "tests/input/t2.hs"
-- ELet "z" (EInt 3) (ELet "y" (EInt 2) (ELet "x" (EInt 1) (ELet "z1" (EInt 0) (EBin Minus (EBin Plus (EVar "x") (EVar "y")) (EBin Plus (EVar "z") (EVar "z1"))))))
--
-- >>> parse "1-2-3"
-- EBin Minus (EBin Minus (EInt 1) (EInt 2)) (EInt 3)
-- >>> parse "1+a&&b||c+d*e-f-g x"
-- EBin Or (EBin And (EBin Plus (EInt 1) (EVar "a")) (EVar "b")) (EBin Minus (EBin Minus (EBin Plus (EVar "c") (EBin Mul (EVar "d") (EVar "e"))) (EVar "f")) (EApp (EVar "g") (EVar "x")))
--
-- >>> parse "1:3:5:[]"
-- EBin Cons (EInt 1) (EBin Cons (EInt 3) (EBin Cons (EInt 5) ENil))
--
-- >>> parse "[1,3,5]"
-- EBin Cons (EInt 1) (EBin Cons (EInt 3) (EBin Cons (EInt 5) ENil))

--------------------------------------------------------------------------------
parse :: String -> Expr
--------------------------------------------------------------------------------
parse = parseExpr

exitError :: Error -> IO Value
exitError (Error msg) = return (VErr msg)

--------------------------------------------------------------------------------
-- | `eval env e` evaluates the Nano expression `e` in the environment `env`
--   (i.e. uses `env` for the values of the **free variables** in `e`),
--   and throws an `Error "unbound variable"` if the expression contains
--   a free variable that is **not bound** in `env`.
--
-- part (a)
--
-- >>> eval env0 (EBin Minus (EBin Plus "x" "y") (EBin Plus "z" "z1"))
-- 0
--
-- >>> eval env0 "p"
-- *** Exception: Error {errMsg = "unbound variable: p"}
--
-- part (b)
--
-- >>> eval []  (EBin Le (EInt 2) (EInt 3))
-- True
--
-- >>> eval []  (EBin Eq (EInt 2) (EInt 3))
-- False
--
-- >>> eval []  (EBin Eq (EInt 2) (EBool True))
-- *** Exception: Error {errMsg = "type error: binop"}
--
-- >>> eval []  (EBin Lt (EInt 2) (EBool True))
-- *** Exception: Error {errMsg = "type error: binop"}
--
-- >>> let e1 = EIf (EBin Lt "z1" "x") (EBin Ne "y" "z") (EBool False)
-- >>> eval env0 e1
-- True
--
-- >>> let e2 = EIf (EBin Eq "z1" "x") (EBin Le "y" "z") (EBin Le "z" "y")
-- >>> eval env0 e2
-- False
--
-- part (c)
--
-- >>> let e1 = EBin Plus "x" "y"
-- >>> let e2 = ELet "x" (EInt 1) (ELet "y" (EInt 2) e1)
-- >>> eval [] e2
-- 3
--
-- part (d)
--
-- >>> eval [] (EApp (ELam "x" (EBin Plus "x" "x")) (EInt 3))
-- 6
--
-- >>> let e3 = ELet "h" (ELam "y" (EBin Plus "x" "y")) (EApp "f" "h")
-- >>> let e2 = ELet "x" (EInt 100) e3
-- >>> let e1 = ELet "f" (ELam "g" (ELet "x" (EInt 0) (EApp "g" (EInt 2)))) e2
-- >>> eval [] e1
-- 102
--
-- part (e)
-- |
-- >>> :{
-- eval [] (ELet "fac" (ELam "n" (EIf (EBin Eq "n" (EInt 0))
--                                  (EInt 1)
--                                  (EBin Mul "n" (EApp "fac" (EBin Minus "n" (EInt 1))))))
--             (EApp "fac" (EInt 10)))
-- :}
-- 3628800
--
-- part (f)
--
-- >>> let el = EBin Cons (EInt 1) (EBin Cons (EInt 2) ENil)
-- >>> execExpr el
-- (1 : (2 : []))
-- >>> execExpr (EApp "head" el)
-- 1
-- >>> execExpr (EApp "tail" el)
-- (2 : [])
--------------------------------------------------------------------------------
eval :: Env -> Expr -> Value
--------------------------------------------------------------------------------
eval env (EInt i) = VInt i
eval env (EBool i) = VBool i
eval env (EVar id) = lookupId id env
eval env (EBin binop e1 e2) = 
  case binop of
    Plus -> inteval env binop e1 e2
    Minus -> inteval env binop e1 e2
    Mul   -> inteval env binop e1 e2
    Lt    -> inteval env binop e1 e2
    Le    -> inteval env binop e1 e2
    Eq    -> case (eval env e1, eval env e2) of 
      (VNil, VNil)       -> VBool True
      (VNil, _)          -> VBool False
      (_, VNil)          -> VBool False
      (VInt _, VInt _)   -> inteval env Eq e1 e2
      (VBool _, VBool _) -> booleval env Eq e1 e2
      _                  -> throw (Error "type error: incompatible types for Eq")
    Ne -> case (eval env e1, eval env e2) of 
       (VNil, VNil)       -> VBool False
       (VNil, _)          -> VBool True
       (_, VNil)          -> VBool True
       (VInt _, VInt _)   -> inteval env Ne e1 e2
       (VBool _, VBool _) -> booleval env Ne e1 e2
       _                  -> throw (Error "type error: incompatible types for Ne")
    And   -> booleval env binop e1 e2
    Or    -> booleval env binop e1 e2
    Cons  -> VPair (eval env e1) (eval env e2)
eval env (EIf p t f) =
  case eval env p of
    VBool True -> eval env t
    VBool False -> eval env f
    _ -> throw (Error "type error: expected bool")
eval env (ELet x e1 e2) = eval newEnv e2
  where
    closure = eval newEnv e1  -- Use newEnv to include the current binding
    newEnv = ((x, closure):env)
eval env (ELam id e) = VClos env id e
eval env (EApp e1 e2) = 
  case eval env e1 of
    VClos closEnv x body -> eval bodyEnv body
      where
        vArg = eval env e2
        bodyEnv = ((x, vArg):closEnv)
    VPrim f -> f (eval env e2)
eval env ENil = VNil
eval env _ = throw (Error "here 2")

inteval :: Env -> Binop -> Expr -> Expr -> Value
inteval env binop e1 e2 = 
  case (eval env e1, eval env e2) of
    (VInt v1, VInt v2) -> f v1 v2
    _ -> throw (Error "type error: expected integers")
  where
    f v1 v2 = case binop of
                Plus  -> VInt (v1 + v2)
                Minus -> VInt (v1 - v2)
                Mul   -> VInt (v1 * v2)
                Lt    -> VBool (v1 < v2)
                Le    -> VBool (v1 <= v2)
                Eq    -> VBool (v1 == v2)
                Ne    -> VBool (v1 /= v2)


booleval :: Env -> Binop -> Expr -> Expr -> Value
booleval env binop e1 e2 = 
  case (eval env e1, eval env e2) of
    (VBool v1, VBool v2) -> VBool (f v1 v2)
    _ -> throw (Error "type error: expected booleans")
  where
    f v1 v2 = case binop of
                And -> v1 && v2
                Or  -> v1 || v2
                Eq    -> v1 == v2
                Ne    -> v1 /= v2


headOp :: Value -> Value
headOp (VPair h _) = h
headOp VNil        = throw (Error "head called on empty list")
headOp _           = throw (Error "head called on non-list")

tailOp :: Value -> Value
tailOp (VPair _ t) = t
tailOp VNil        = VNil
tailOp _           = throw (Error "tail called on non-list")


--------------------------------------------------------------------------------
evalOp :: Binop -> Value -> Value -> Value
--------------------------------------------------------------------------------
evalOp = error "TBD:evalOp"

--------------------------------------------------------------------------------
-- | `lookupId x env` returns the most recent
--   binding for the variable `x` (i.e. the first
--   from the left) in the list representing the
--   environment, and throws an `Error` otherwise.
--
-- >>> lookupId "z1" env0
-- 0
-- >>> lookupId "x" env0
-- 1
-- >>> lookupId "y" env0
-- 2
-- >>> lookupId "mickey" env0
-- *** Exception: Error {errMsg = "unbound variable: mickey"}
--------------------------------------------------------------------------------
lookupId :: Id -> Env -> Value
--------------------------------------------------------------------------------
lookupId x [] = throw (Error ("unbound variable: " ++ x))
lookupId x ((y,val):envir)
 | x == y  = val
 | otherwise = lookupId x envir

prelude :: Env
prelude = 
  [ ("head", VPrim headOp)
  , ("tail", VPrim tailOp)
  ]

env0 :: Env
env0 =  [ ("z1", VInt 0)
        , ("x" , VInt 1)
        , ("y" , VInt 2)
        , ("z" , VInt 3)
        , ("z1", VInt 4)
        ]

--------------------------------------------------------------------------------