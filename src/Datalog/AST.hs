{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE DeriveLift           #-}
{-# LANGUAGE DerivingStrategies   #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE UndecidableInstances #-}
module Datalog.AST where

import           Data.ByteString            (ByteString)
import           Data.Hex                   (hex)
import           Data.Set                   (Set)
import           Data.Text                  (Text, intercalate, pack)
import           Data.Text.Encoding         (decodeUtf8)
import           Data.Time                  (UTCTime)
import           Data.Void                  (Void, absurd)
import           Instances.TH.Lift          ()
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax

data IsWithinSet = NotWithinSet | WithinSet
data ParsedAs = RegularString | QuasiQuote

type family VariableType (inSet :: IsWithinSet) (ctx :: ParsedAs) where
  VariableType 'NotWithinSet p = Text
  VariableType 'WithinSet p    = Void

type family SliceType (inSet :: IsWithinSet) (ctx :: ParsedAs) where
  SliceType s 'RegularString = Void
  SliceType s 'QuasiQuote    = String

type family SetType (inSet :: IsWithinSet) (ctx :: ParsedAs) where
  SetType 'NotWithinSet m = Set (ID' 'WithinSet m)
  SetType 'WithinSet    m = Void

data ID' (inSet :: IsWithinSet) (ctx :: ParsedAs) =
    Symbol Text
  | Variable (VariableType inSet ctx)
  | LInteger Int
  | LString Text
  | LDate UTCTime
  | LBytes ByteString
  | LBool Bool
  | Antiquote (SliceType inSet ctx)
  | TermSet (SetType inSet ctx)

deriving instance ( Eq (VariableType inSet ctx)
                  , Eq (SliceType inSet ctx)
                  , Eq (SetType inSet ctx)
                  ) => Eq (ID' inSet ctx)

-- In a regular AST, antiquotes have already been eliminated
type ID = ID' 'NotWithinSet 'RegularString
-- In an AST parsed from a QuasiQuoter, there might be references to haskell variables
type QQID = ID' 'NotWithinSet 'QuasiQuote

instance Lift (ID' 'NotWithinSet 'QuasiQuote) where
  lift (Symbol n)    = apply 'Symbol [lift n]
  lift (Variable n)  = apply 'Variable [lift n]
  lift (LInteger i)  = apply 'LInteger [lift i]
  lift (LString s)   = apply 'LString [lift s]
  lift (LDate t)     = apply 'LDate [ [| read $(lift (show t)) |] ]
  lift (LBytes bs)   = apply 'LBytes [lift bs]
  lift (LBool b)     = apply 'LBool [lift b]
  lift (Antiquote n) = appE (varE 'toLiteralId) (varE $ mkName n)
  lift (TermSet _)   = apply 'LBool [lift True] -- todo

instance Lift (ID' 'WithinSet 'QuasiQuote) where
  lift =
    let lift' = lift @(ID' 'NotWithinSet 'QuasiQuote)
    in \case
      Symbol i -> lift' (Symbol i)
      LInteger i -> lift' (LInteger i)
      LString i -> lift' (LString i)
      LDate i -> lift' (LDate i)
      LBytes i -> lift' (LBytes i)
      LBool i -> lift' (LBool i)
      Antiquote i -> lift' (Antiquote i)
      Variable v -> absurd v
      TermSet v -> absurd v

apply :: Name -> [Q Exp] -> Q Exp
apply n = foldl appE (conE n)

class ToLiteralId t where
  toLiteralId :: t -> ID

instance ToLiteralId Text where
  toLiteralId = LString

instance ToLiteralId Bool where
  toLiteralId = LBool

instance ToLiteralId ByteString where
  toLiteralId = LBytes

renderId :: ID -> Text
renderId = \case
  Symbol name    -> "#" <> name
  Variable name  -> "$" <> name
  LInteger int   -> pack $ show int
  LString str    -> pack $ show str
  LDate time     -> pack $ show time
  LBytes bs      -> "hex:" <> decodeUtf8 (hex bs)
  LBool True     -> "true"
  LBool False    -> "false"
  TermSet _ -> "[todo]"
  Antiquote v -> absurd v

data Predicate' (ctx :: ParsedAs) = Predicate
  { name  :: Text
  , terms :: [ID' 'NotWithinSet ctx]
  }

deriving instance Lift (ID' 'NotWithinSet ctx) => Lift (Predicate' ctx)

type Predicate = Predicate' 'RegularString

renderPredicate :: Predicate -> Text
renderPredicate Predicate{name,terms} =
  name <> "(" <> intercalate ", " (fmap renderId terms) <> ")"

data Rule' ctx = Rule
  { rhead :: Predicate' ctx
  , body  :: [Predicate' ctx]
  }

deriving instance Lift (Predicate' ctx) => Lift (Rule' ctx)

renderRule :: Rule' 'RegularString -> Text
renderRule Rule{rhead,body} =
  renderPredicate rhead <> " <- " <> intercalate ", " (fmap renderPredicate body)


data Expression' (ctx :: ParsedAs) = Void
  deriving stock (Show, Lift)
