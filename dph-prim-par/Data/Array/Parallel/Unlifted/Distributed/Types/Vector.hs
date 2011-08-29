{-# OPTIONS -Wall -fno-warn-orphans -fno-warn-missing-signatures #-}

-- | Distribution of Vectors.
module Data.Array.Parallel.Unlifted.Distributed.Types.Vector
        (lengthD)
where
import Data.Array.Parallel.Unlifted.Distributed.Types.Prim      ()
import Data.Array.Parallel.Unlifted.Distributed.Types.Base
import Data.Array.Parallel.Unlifted.Distributed.Gang
import Data.Array.Parallel.Unlifted.Sequential.Vector   as V
import qualified Data.Vector                            as BV
import qualified Data.Vector.Mutable                    as MBV
import Prelude                                          as P
import Control.Monad


instance Unbox a => DT (V.Vector a) where
  data Dist  (Vector a)   = DVector  !(Dist  Int)   !(BV.Vector      (Vector a))
  data MDist (Vector a) s = MDVector !(MDist Int s) !(MBV.STVector s (Vector a))

  indexD (DVector _ a) i
   = a BV.! i

  newMD g
   = liftM2 MDVector (newMD g) 
                        (MBV.replicate (gangSize g) (error "MDist (Vector a) - uninitalised"))

  readMD (MDVector _ marr)
   = MBV.read marr

  writeMD (MDVector mlen marr) i a 
   = do writeMD mlen i (V.length a)
        MBV.write marr i $! a

  unsafeFreezeMD (MDVector len a)
   = liftM2 DVector (unsafeFreezeMD len)
                    (BV.unsafeFreeze a)

  sizeD  (DVector  _ a) = BV.length  a
  sizeMD (MDVector _ a) = MBV.length a

  measureD xs           = "Vector " P.++ show (V.length xs)


-- | Yield the distributed length of a distributed array.
lengthD :: Unbox a => Dist (Vector a) -> Dist Int
lengthD (DVector l _) = l
