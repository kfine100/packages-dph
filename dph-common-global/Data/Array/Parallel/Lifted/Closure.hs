{-# LANGUAGE
	TypeOperators, ScopedTypeVariables, ExistentialQuantification,
	TypeFamilies, Rank2Types, MultiParamTypeClasses, 
        StandaloneDeriving #-}

module Data.Array.Parallel.Lifted.Closure where
import Data.Array.Parallel.PArray

-- Closures -------------------------------------------------------------------
infixr 0 :->
data (a :-> b)
	= forall env. PM env
	=> Clo 	(env -> a -> b)
		(forall m1 m2
			.  (PJ m1 env, PJ m2 a)
			=> Int -> PData m1 env -> PData m2 a -> PData Sized b)
		env

-- | Closure application.
($:) :: (a :-> b) -> a -> b
($:) (Clo fv fl env) x	= fv env x


-- | Construct an arity-1 closure.
closure1 
	:: (a -> b)
	-> (forall m2. PJ m2 a => Int -> PData m2 a -> PData Sized b)
	-> (a :-> b)
closure1 fv fl	
	= Clo	(\_env -> fv)
		(\n _env -> fl n)
		()


-- | Construct an arity-2 closure.
closure2 
	:: forall a b c. PM a
	=> (a -> b -> c)
	-> (forall m1 m2
		.  (PJ m1 a, PJ m2 b)
		=> Int -> PData m1 a -> PData m2 b -> PData Sized c)
	-> (a :-> b :-> c)

closure2 fv fl
 = let	fv_1 	:: forall env. env -> a -> (b :-> c)
	fv_1 _ xa = Clo fv fl xa

	fl_1 	:: forall env m1 m2
		.  (PJ m1 env, PJ m2 a)
		=> Int -> PData m1 env -> PData m2 a -> PData Sized (b :-> c)

	fl_1 n _ xs = AClo fv fl (restrictPJ n xs)
	
   in	Clo fv_1 fl_1 ()


-- Array Closures -------------------------------------------------------------
data instance PData m (a :-> b)
	= forall env. (PJ m env, PM env)
	=> AClo	(env -> a -> b)
		(forall m1 m2
			.  (PJ m1 env, PJ m2 a)
			=> Int -> PData m1 env -> PData m2 a -> PData Sized b)
		(PData m env)

instance PR (a :-> b) where
  emptyPR 
	= AClo 	(\_ _ -> error "empty array closure")
 		(\_ _ -> error "empty array closure")
		(emptyPR :: PData Sized ())

  appPR		= error "appPR[:->] not defined"
  fromListPR	= error "fromListPR[:->] not defined"


instance PJ Global (a :-> b) where
  restrictPJ n (AClo fv fl env)	
	= AClo fv fl (restrictPJ n env)

  indexPJ   (AClo fv fl env) ix
	= Clo fv fl (indexPJ env ix)


instance PJ Sized (a :-> b) where
  restrictPJ n (AClo fv fl env)	
	= AClo fv fl (restrictPJ n env)

  indexPJ   (AClo fv fl env) ix 
	= Clo fv fl (indexPJ env ix)


instance PE (a :-> b) where
  repeatPE (Clo fv fl env)
	= AClo fv fl (repeatPE env)


instance PM (a :-> b)


-- | Lifted closure application.
liftedApply 
	:: PJ m2 a
	=> Int -> PData m1 (a :-> b) -> PData m2 a -> PData Sized b

liftedApply n (AClo _ fl envs) as
	= fl n envs as
