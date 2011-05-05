module Data.Array.Parallel.Lifted.Closure (
  (:->)(..), PArray(..),
  mkClosure, mkClosureP, ($:), ($:^),
  closure, liftedClosure, liftedApply,

  closure1, closure2, closure3
) where

import Data.Array.Parallel.Lifted.PArray
import Data.Array.Parallel.Lifted.Instances
import Data.Array.Parallel.Lifted.Repr

import GHC.Exts (Int#)

infixr 0 :->
infixl 0 $:, $:^

-- | The type of closures.
--   This bundles up 
--      1) the vectorised verion of the function that takes an explicit environment
--      2) the lifted version, that works on arrays.
--         the first parameter of this function is the 'lifting context'
--         that gives the length of the array.
--      3) the environment of the closure.
-- 
--   The vectoriser closure-converts the source program so that all functions
--   types are expressed in this form.
--
data a :-> b 
  = forall e. PA e 
  => Clo !(e -> a -> b)                                 -- vectorised version
         !(Int# -> PData e -> PData a -> PData b)       -- lifted version
         e                                              -- environment


lifted :: (PArray e -> PArray a -> PArray b)
       -> Int# -> PData e -> PData a -> PData b
{-# INLINE lifted #-}
lifted f n# es as 
  = case f (PArray n# es) (PArray n# as) of
     PArray _ bs -> bs


-- |Closure construction
--
mkClosure :: forall a b e. 
             PA e => (e -> a -> b)
                  -> (PArray e -> PArray a -> PArray b)
                  -> e -> (a :-> b)
{-# INLINE CONLIKE mkClosure #-}
mkClosure fv fl e = Clo fv (lifted fl) e

closure :: forall a b e.
           PA e => (e -> a -> b)
                -> (Int# -> PData e -> PData a -> PData b)
                -> e
                -> (a :-> b)
{-# INLINE closure #-}
closure fv fl e = Clo fv fl e

-- |Closure application
--
($:) :: forall a b. (a :-> b) -> a -> b
{-# INLINE ($:) #-}
Clo f _ e $: a = f e a

{-# RULES

"mkClosure/($:)" forall fv fl e x.
  mkClosure fv fl e $: x = fv e x

 #-}

-- |Arrays of closures (aka array closures)
--
data instance PData (a :-> b)
  = forall e. PA e => AClo !(e -> a -> b)
                           !(Int# -> PData e -> PData a -> PData b)
                            (PData e)

-- |Lifted closure construction
--
mkClosureP :: forall a b e.
              PA e => (e -> a -> b)
                   -> (PArray e -> PArray a -> PArray b)
                   -> PArray e -> PArray (a :-> b)
{-# INLINE mkClosureP #-}
mkClosureP fv fl (PArray n# es) = PArray n# (AClo fv (lifted fl) es)

liftedClosure :: forall a b e.
                 PA e => (e -> a -> b)
                      -> (Int# -> PData e -> PData a -> PData b)
                      -> PData e
                      -> PData (a :-> b)
{-# INLINE liftedClosure #-}
liftedClosure fv fl es = AClo fv fl es

-- |Lifted closure application
--
($:^) :: forall a b. PArray (a :-> b) -> PArray a -> PArray b
{-# INLINE ($:^) #-}
PArray n# (AClo _ f es) $:^ PArray _ as = PArray n# (f n# es as)

liftedApply :: forall a b. Int# -> PData (a :-> b) -> PData a -> PData b
{-# INLINE liftedApply #-}
liftedApply n# (AClo _ f es) as = f n# es as

type instance PRepr (a :-> b) = a :-> b

instance (PA a, PA b) => PA (a :-> b) where
  toPRepr      = id
  fromPRepr    = id
  toArrPRepr   = id
  fromArrPRepr = id

instance PR (a :-> b) where
  {-# INLINE emptyPR #-}
  emptyPR = AClo (\e  a  -> error "empty array closure")
                 (\es as -> error "empty array closure")
                 (emptyPD :: PData ())

  {-# INLINE replicatePR #-}
  replicatePR n# (Clo f f' e) = AClo f f' (replicatePD n# e)

  {-# INLINE replicatelPR #-}
  replicatelPR segd (AClo f f' es)
    = AClo f f' (replicatelPD segd es)

  {-# INLINE indexPR #-}
  indexPR (AClo f f' es) i# = Clo f f' (indexPD es i#)

  {-# INLINE bpermutePR #-}
  bpermutePR (AClo f f' es) n# is = AClo f f' (bpermutePD es n# is)

  {-# INLINE packByTagPR #-}
  packByTagPR (AClo f f' es) n# tags t# = AClo f f' (packByTagPD es n# tags t#)

-- Closure construction

closure1 :: (a -> b) -> (PArray a -> PArray b) -> (a :-> b)
{-# INLINE closure1 #-}
closure1 fv fl = mkClosure (\_ -> fv) (\_ -> fl) ()

closure2 :: PA a
         => (a -> b -> c)
         -> (PArray a -> PArray b -> PArray c)
         -> (a :-> b :-> c)
{-# INLINE closure2 #-}
closure2 fv fl = mkClosure fv_1 fl_1 ()
  where
    fv_1 _ x  = mkClosure  fv fl x
    fl_1 _ xs = mkClosureP fv fl xs

closure3 :: (PA a, PA b)
         => (a -> b -> c -> d)
         -> (PArray a -> PArray b -> PArray c -> PArray d)
         -> (a :-> b :-> c :-> d)
{-# INLINE closure3 #-}
closure3 fv fl = mkClosure fv_1 fl_1 ()
  where
    fv_1 _  x  = mkClosure  fv_2 fl_2 x
    fl_1 _  xs = mkClosureP fv_2 fl_2 xs

    fv_2 x  y  = mkClosure  fv_3 fl_3 (x,y)
    fl_2 xs ys = mkClosureP fv_3 fl_3 (zipPA# xs ys)

    fv_3 (x,y) z = fv x y z
    fl_3 ps zs = case unzipPA# ps of (xs,ys) -> fl xs ys zs

