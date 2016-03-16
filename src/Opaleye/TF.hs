{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Opaleye.TF
       ( -- $intro
         -- * The 'Col' type family
         type Col,

         -- * Mapping PostgreSQL types
         PGType(..), Lit(..), null, nullable,

         -- * Defining tables
         Table(..),

         -- * Querying tables
         queryTable, Expr, select, leftJoin, restrict, (==.),

         -- * Inserting data
         insert, Insertion, Default(..),

         -- * Implementation details
         Compose(..), Interpretation, InterpretPGType, Interpret)
       where

import Prelude hiding (null)
import Opaleye.TF.Insert
import Opaleye.TF.Default
import Opaleye.TF.Expr
import Opaleye.TF.Interpretation
import Opaleye.TF.Machinery
import Opaleye.TF.Lit
import Opaleye.TF.BaseTypes
import Opaleye.TF.Col
import Opaleye.TF.Nullable

import Control.Applicative
import Control.Monad (void)
import Data.Int
import Data.Profunctor
import Data.Profunctor.Product ((***!))
import Data.Proxy (Proxy(..))
import Data.String (IsString(..))
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.FromField as PG
import qualified Database.PostgreSQL.Simple.FromRow as PG
import GHC.Generics
import GHC.TypeLits (Symbol, KnownSymbol, symbolVal)
import qualified Opaleye.Internal.Column as Op
import qualified Opaleye.Internal.HaskellDB.PrimQuery as Op
import qualified Opaleye.Internal.Join as Op
import qualified Opaleye.Internal.PackMap as Op
import qualified Opaleye.Internal.RunQuery as Op
import qualified Opaleye.Internal.Table as Op
import qualified Opaleye.Internal.TableMaker as Op
import qualified Opaleye.Internal.Unpackspec as Op
import qualified Opaleye.Join as Op
import qualified Opaleye.Manipulation as Op
import qualified Opaleye.Operators as Op
import qualified Opaleye.QueryArr as Op
import qualified Opaleye.RunQuery as Op
import qualified Opaleye.Table as Op hiding (required)

--------------------------------------------------------------------------------

-- | 'Table' is used to specify the schema definition in PostgreSQL. The type
-- itself uses a GHC \"symbol\" to specify the table name. This is also an
-- instance of 'FromString', where the string is taken as the column name.
--
-- Example:
--
-- @
-- userTable :: User ('Table' "user")
-- userTable = User { userId = "id"
--                  , userName = "name"
--                  , userBio = "bio"
--                  }
-- @
newtype Table (tableName :: Symbol) (columnType :: k) =
  Column String
  deriving (Show)

-- This handy instance gives us a bit more sugar when defining a table.
instance IsString (Table tableName columnType) where fromString = Column

--------------------------------------------------------------------------------

-- | 'queryTable' moves from 'Table' to 'Expr'. Accessing the fields of your
-- table record will now give you expressions to view data in the individual
-- columns.
queryTable :: forall table tableName. (KnownSymbol tableName, TableLike table tableName)
           => table (Table tableName) -> Op.Query (table Expr)
queryTable t =
  Op.queryTableExplicit
    columnMaker
    (Op.Table (symbolVal (Proxy :: Proxy tableName))
              (Op.TableProperties undefined
                                  (Op.View columnView)))
  where columnView = columnViewRep (from t)
        columnMaker =
          Op.ColumnMaker
            (Op.PackMap
               (\inj columns ->
                  fmap to (injPackMap inj columns)))

-- TODO This should probably be a type class so I don't force generics on people.
type TableLike t tableName = (Generic (t Expr),Generic (t (Table tableName)), InjPackMap (Rep (t Expr)), ColumnView (Rep (t (Table tableName))) (Rep (t Expr)))

-- | A type class to get the column names out of the record.
class ColumnView f g where
  columnViewRep :: f x -> g x

instance ColumnView f f' => ColumnView (M1 i c f) (M1 i c f') where
  columnViewRep (M1 f) = M1 (columnViewRep f)

instance (ColumnView f f', ColumnView g g') => ColumnView (f :*: g) (f' :*: g') where
  columnViewRep (f :*: g) = columnViewRep f :*: columnViewRep g

instance ColumnView (K1 i (Table tableName colType)) (K1 i (Expr colType)) where
  columnViewRep (K1 (Column name)) = K1 (Expr (Op.BaseTableAttrExpr name))

-- A type to generate that weird PackMap thing queryTableExplicit wants.
-- Basically associating column symbol names with the given record.
class InjPackMap g where
  injPackMap :: Applicative f => (Op.PrimExpr -> f Op.PrimExpr) -> g x -> f (g x)

instance InjPackMap f => InjPackMap (M1 i c f) where
  injPackMap f (M1 a) = fmap M1 (injPackMap f a)

instance (InjPackMap f, InjPackMap g) => InjPackMap (f :*: g) where
  injPackMap f (a :*: b) = liftA2 (:*:) (injPackMap f a) (injPackMap f b)

instance InjPackMap (K1 i (Expr colType)) where
  injPackMap f (K1 (Expr prim)) = fmap (K1 . Expr) (f prim)

--------------------------------------------------------------------------------

-- | 'select' executes a PostgreSQL query as a @SELECT@ statement, returning
-- data mapped to Haskell values.
select :: Selectable pg haskell => PG.Connection -> Op.Query pg -> IO [haskell]
select conn = Op.runQueryExplicit queryRunner conn

-- A type class for selectable things, so we can return a table or a tuple.
class Selectable expr haskell | expr -> haskell where
  queryRunner :: Op.QueryRunner expr haskell

-- A scary instance for interpreting Expr to Haskell types generically.
instance (Generic (rel Expr),ParseRelRep (Rep (rel Expr)) (Rep (rel Interpret)),Generic (rel Interpret),UnpackspecRel (Rep (rel Expr)), HasFields (Rep (rel Expr))) =>
           Selectable (rel Expr) (rel Interpret) where
  queryRunner = gqueryRunner

-- The same instance but for left joins.
instance (Generic (rel (Compose Expr 'Nullable)),ParseRelRep (Rep (rel (Compose Expr 'Nullable))) (Rep (rel (Compose Interpret 'Nullable))),Generic (rel (Compose Interpret 'Nullable)),UnpackspecRel (Rep (rel (Compose Expr 'Nullable))), Generic (rel Interpret), DistributeMaybe (rel (Compose Interpret 'Nullable)) (rel Interpret), HasFields (Rep (rel (Compose Expr 'Nullable)))) =>
           Selectable (rel (Compose Expr 'Nullable)) (Maybe (rel Interpret)) where
  queryRunner = fmap distributeMaybe (gqueryRunner :: Op.QueryRunner (rel (Compose Expr 'Nullable)) (rel (Compose Interpret 'Nullable)))

-- This lets us turn a record of Maybe's into a Maybe of fields.
class DistributeMaybe x y | x -> y where
  distributeMaybe :: x -> Maybe y

instance (Generic (rel (Compose Interpret 'Nullable)), Generic (rel Interpret), GDistributeMaybe (Rep (rel (Compose Interpret 'Nullable))) (Rep (rel Interpret))) => DistributeMaybe (rel (Compose Interpret 'Nullable)) (rel Interpret) where
  distributeMaybe = fmap to . gdistributeMaybe . from

class GDistributeMaybe x y where
  gdistributeMaybe :: x a -> Maybe (y a)

instance GDistributeMaybe f f' => GDistributeMaybe (M1 i c f) (M1 i c f') where
  gdistributeMaybe (M1 a) = fmap M1 (gdistributeMaybe a)

instance (GDistributeMaybe f f', GDistributeMaybe g g') => GDistributeMaybe (f :*: g) (f' :*: g') where
  gdistributeMaybe (a :*: b) = liftA2 (:*:) (gdistributeMaybe a) (gdistributeMaybe b)

instance GDistributeMaybe (K1 i (Maybe a)) (K1 i a) where
  gdistributeMaybe (K1 a) = fmap K1 a

instance GDistributeMaybe (K1 i (Maybe a)) (K1 i (Maybe a)) where
  gdistributeMaybe (K1 a) = fmap (K1 . Just) a

-- Tuples
instance (Selectable e1 h1, Selectable e2 h2) => Selectable (e1,e2) (h1,h2) where
  queryRunner = queryRunner ***! queryRunner

instance (Selectable e1 h1,Selectable e2 h2,Selectable e3 h3) => Selectable (e1,e2,e3) (h1,h2,h3) where
  queryRunner =
    dimap (\(a,b,c) -> ((a,b),c))
          (\((a,b),c) -> (a,b,c))
          (queryRunner ***! queryRunner ***! queryRunner)

instance (Selectable e1 h1,Selectable e2 h2,Selectable e3 h3,Selectable e4 h4) => Selectable (e1,e2,e3,e4) (h1,h2,h3,h4) where
  queryRunner =
    dimap (\(a,b,c,d) -> ((a,b),(c,d)))
          (\((a,b),(c,d)) -> (a,b,c,d))
          ((queryRunner ***! queryRunner) ***! (queryRunner ***! queryRunner))

-- Build a query runner generically.
gqueryRunner :: (HasFields (Rep expr), Generic expr, ParseRelRep (Rep expr) (Rep haskell), Generic haskell, UnpackspecRel (Rep expr)) => Op.QueryRunner expr haskell
gqueryRunner =
  Op.QueryRunner
    (Op.Unpackspec
       (Op.PackMap
          (\inj p -> unpackRel inj (from p))))
    (fmap to . parseRelRep . from)
    (ghasFields . from)

class HasFields f where
  ghasFields :: f a -> Bool

instance HasFields (M1 i c f) where
  ghasFields _ = True

class ParseRelRep f g where
  parseRelRep :: f x -> PG.RowParser (g x)

instance ParseRelRep f f' => ParseRelRep (M1 i c f) (M1 i c f') where
  parseRelRep (M1 a) = fmap M1 (parseRelRep a)

instance (ParseRelRep f f', ParseRelRep g g') => ParseRelRep (f :*: g) (f' :*: g') where
  parseRelRep (a :*: b) = liftA2 (:*:) (parseRelRep a) (parseRelRep b)

instance (haskell ~ Col Interpret colType, PG.FromField haskell) => ParseRelRep (K1 i (Expr colType)) (K1 i haskell) where
  parseRelRep (K1 _) = fmap K1 PG.field

class UnpackspecRel rep where
  unpackRel :: Applicative f => (Op.PrimExpr -> f Op.PrimExpr) -> rep x -> f ()

instance UnpackspecRel f => UnpackspecRel (M1 i c f) where
  unpackRel inj (M1 a) = unpackRel inj a

instance (UnpackspecRel a, UnpackspecRel b) => UnpackspecRel (a :*: b) where
  unpackRel inj (a :*: b) = unpackRel inj a *> unpackRel inj b

instance UnpackspecRel (K1 i (Expr colType)) where
  unpackRel inj (K1 (Expr prim)) = void (inj prim)

--------------------------------------------------------------------------------

-- | A left join takes two queries and performs a relational @LEFT JOIN@ between
-- them. The left join has all rows of the left query, joined against zero or
-- more rows in the right query. If the join matches no rows in the right table,
-- then all columns will be @null@.
leftJoin :: (ToNull right nullRight)
         => (left -> right -> Expr 'PGBoolean)
         -> Op.Query left
         -> Op.Query right
         -> Op.Query (left,nullRight)
leftJoin f l r =
  Op.leftJoinExplicit
    undefined
    undefined
    (Op.NullMaker toNull)
    l
    r
    (\(l',r') ->
       case f l' r' of
         Expr prim -> Op.Column prim)

class ToNull expr exprNull | expr -> exprNull where
  toNull :: expr -> exprNull

instance (GToNull (Rep (rel Expr)) (Rep (rel (Compose Expr 'Nullable))), Generic (rel Expr), Generic (rel (Compose Expr 'Nullable))) => ToNull (rel Expr) (rel (Compose Expr 'Nullable)) where
  toNull = to . gtoNull . from

class GToNull f g | f -> g where
  gtoNull :: f x -> g x

instance GToNull f f' => GToNull (M1 i c f) (M1 i c f') where
  gtoNull (M1 f) = M1 (gtoNull f)

instance (GToNull f f', GToNull g g') => GToNull (f :*: g) (f' :*: g') where
  gtoNull (f :*: g) = gtoNull f :*: gtoNull g

instance (t' ~ Col (Compose Expr 'Nullable) t, t' ~ Expr x) => GToNull (K1 i (Expr t)) (K1 i t') where
  gtoNull (K1 (Expr prim)) = K1 (Expr prim)

--------------------------------------------------------------------------------

-- | Apply a @WHERE@ restriction to a table.
restrict :: Op.QueryArr (Expr 'PGBoolean) ()
restrict = lmap (\(Expr prim) -> Op.Column prim) Op.restrict

-- | The PostgreSQL @=@ operator.
(==.) :: Expr a -> Expr a -> Expr 'PGBoolean
Expr a ==. Expr b =
  case Op.Column a Op..== Op.Column b of
    Op.Column c -> Expr c

infix 4 ==.

--------------------------------------------------------------------------------

class Insertable table row | table -> row where
  insertTable :: table -> Op.Table row ()

instance (KnownSymbol tableName,Generic (rel Insertion),Generic (rel (Table tableName)),GWriter (Rep (rel (Table tableName))) (Rep (rel Insertion))) => Insertable (rel (Table tableName)) (rel Insertion) where
  insertTable table =
    Op.Table (symbolVal (Proxy :: Proxy tableName))
             (lmap from
                   (Op.TableProperties (gwriter (from table))
                                       undefined))

class GWriter f g where
  gwriter :: f x -> Op.Writer (g x) ()

instance GWriter f f' => GWriter (M1 i c f) (M1 i c f') where
  gwriter (M1 a) =
    lmap (\(M1 x) -> x)
         (gwriter a)

instance (GWriter f f',GWriter g g') => GWriter (f :*: g) (f' :*: g') where
  gwriter (l :*: r) =
    dimap (\(l' :*: r') -> (l',r'))
          fst
          (gwriter l ***! gwriter r)

instance GWriter (K1 i (Table tableName ('HasDefault t))) (K1 i (Default (Expr t))) where
  gwriter (K1 (Column columnName)) =
    dimap (\(K1 def) ->
             case def of
               InsertDefault -> Op.Column (Op.DefaultInsertExpr)
               ProvideValue (Expr a) -> Op.Column a)
          (const ())
          (Op.required columnName)

instance GWriter (K1 i (Table tableName ('NotNullable t))) (K1 i (Expr t)) where
  gwriter (K1 (Column columnName)) =
    dimap (\(K1 (Expr e)) -> Op.Column e)
          (const ())
          (Op.required columnName)

instance GWriter (K1 i (Table tableName t)) (K1 i (Expr t)) where
  gwriter (K1 (Column columnName)) =
    dimap (\(K1 (Expr e)) -> Op.Column e)
          (const ())
          (Op.required columnName)

-- | Given a 'Table' and a collection of rows for that table, @INSERT@ this data
-- into PostgreSQL. The rows are specified as PostgreSQL expressions.
insert
  :: Insertable table row
  => PG.Connection -> table -> [row] -> IO Int64
insert conn table rows =
  Op.runInsertMany conn
                   (insertTable table)
                   rows

{- $intro

Welcome to @opaleye-tf@, a library to query and interact with PostgreSQL
databases. As the name suggests, this library builds on top of the terrific
@opaleye@ library, but provides a different API that the author believes
provides more succinct code with better type inference.

The basic idea behind @opaleye-tf@ is to \"pivot\" around the ideas in
@opaleye@. The current idiomatic usage of Opaleye is to define your records as
data types where each field is parameterized. Opaleye then varies all of these
parameters together. @opaleye-tf@ makes the observation that if all of these
vary uniformly, then there should only be /one/ parameter, and thus we have
records that are parameterized by functors.

To take an example, let's consider a simple schema for Hackage - the repository
of Haskell libraries.

@
data Package f =
  Package { packageName :: 'Col' f 'PGText'
          , packageAuthor :: Col f \''PGInteger'
          , packageMaintainerId :: Col f (\''PGNull' \''PGInteger')
          }

data User f =
  User { userId :: 'Col' f \''PGInteger'
       , userName :: 'Col' f \''PGText'
       , userBio :: 'Col' f (\''PGNull' 'PGText')
       }
@

In this example, each record (@Package@ and @User@) correspond to tables in a
PostgreSQL database. These records are parameterized over functors @f@, which
will provide /meaning/ depending on how the record is used. Notice all that
we specify the types as they are in PostgreSQL. @opaleye-tf@ primarily focuses
on the flow of information /from/ the database.

One type of meaning that we can give to tables is to map their fields to their
respective columns. This is done by choosing 'Table' as our choice of @f@:

@
packageTable :: Package ('Table' "package")
packageTable = Package { packageName = "name"
                       , packageAuthor = "author_id"
                       , packageMaintainerId = "maintainer_id" }

userTable :: User ('Table' "user")
userTable = User { userId = "id"
                 , userName = "name"
                 , userBio = "bio"
                 }
@

Now that we have full definitions of our tables, we can perform some @SELECT@s.
First, let's list all known packages:

@
listAllPackages :: 'PG.Connection' -> IO [Package 'Interpret']
listAllPackages c = 'select' ('queryTable' packageTable)
@

This computation now returns us a list of @Package@s where @f@ has been set as
'Interpret'. The 'Interpret' functor is responsible for defining the mapping
from PostgreSQL types (such as 'PGText') to Haskell types (such as 'Text').

Another choice of @f@ occurs when we perform a left join. For example, here
is the /query/ to list all packages with their (optional) maintainers:

@
listAllPackagesAndMaintainersQuery :: 'Query' (Package 'Expr', User ('Compose' 'Expr' 'PGNull'))
listAllPackagesAndMaintainersQuery =
  'leftJoin' (\p m -> packageMaintainerId p '==.' userId m)
           ('queryTable' package)
           ('queryTable' user))
@

This query communicates that we will have a collection of 'Expr'essions that
correspond to columns in the @Package@ table, and also a collection of
'Expr'essions that are columns in the @User@ table. However, as the user table
is only present as a left join, all of these columns might be @NULL@ - indicated
by the composition of 'PGNull' with 'Expr'.

@opaleye-tf@ is smart enough to collapse data together where convenient.
For example, if we look at just the final types of @userId@ and @userBio@ in the
context of the left join:

@
> :t fmap (\\(_, u) -> userId u) listAllPackagesAndMaintainersQuery
Query (Expr (PGNull PGInteger))

> :t fmap (\\(_, u) -> userBio u) listAllPackagesAndMaintainersQuery
Query (Expr (PGNull PGText))
@

Which are as expected.

Finally, when executing queries that contain left joins, @opaleye-tf@ is able to
invert the possible @NULLs@ over the whole record:

@
> :t \conn -> select conn listAllPackagesAndMaintainersQuery
Connection -> IO [(Package Interpret, Maybe (User Interpret))]
@

Notice that @User (Compose Expr PGNull)@ was mapped to @Maybe (User Interpret)@.

-}
