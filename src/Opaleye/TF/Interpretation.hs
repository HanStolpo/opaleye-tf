{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE KindSignatures #-}

module Opaleye.TF.Interpretation where

import Opaleye.TF.Machinery

data Interpret (col :: t)

type family HaskellTyfun (col :: t) :: (TyFun t * -> *)
type family HaskellNullableTyfun (col :: t) :: (TyFun t * -> *)