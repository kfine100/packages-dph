{-# LANGUAGE
        CPP,
        BangPatterns,
        TypeFamilies,
        FlexibleInstances, FlexibleContexts,
        MultiParamTypeClasses,
        StandaloneDeriving,
        ExistentialQuantification,
        UndecidableInstances,
        ParallelListComp #-}

{-# OPTIONS -fno-spec-constr #-}

#include "fusion-phases.h"

module Data.Array.Parallel.PArray.PData.Nested 
        ( PData(..)
        , mkPNested
        , pnested_vsegids
        , pnested_pseglens
        , pnested_psegstarts
        , pnested_psegsrcids

        -- * Testing functions. TODO: move these somewhere else
        , validIx
        , validLen
        , validBool
                
        -- * Functions derived from PR primops
        , concatPR
        , unconcatPR
        , concatlPR
        , slicelPR
        , appendlPR)
where
import Data.Array.Parallel.PArray.PData.Base
import Data.Array.Parallel.Base

import qualified Data.IntSet                    as IS
import qualified Data.Array.Parallel.Unlifted   as U
import qualified Data.Vector                    as V
import qualified Data.Vector.Unboxed            as VU
import Text.PrettyPrint


-- Nested arrays --------------------------------------------------------------

data instance PData Int
        = PInt (U.Array Int)

-- TODO: Using plain V.Vector for the psegdata field means that operations on
--       this field aren't parallelised. In particular, when we append two
--       psegdata fields during appPR or combinePR this runs sequentially
--
data instance PData (PArray a)
        = PNested
        { pnested_uvsegd       :: !U.VSegd
          -- ^ Virtual segmentation descriptor. 
          --   Defines a virtual nested array based on physical data.

        , pnested_psegdata     :: !(V.Vector (PData a)) }

-- TODO: we shouldn't be using these directly.
pnested_vsegids    = U.takeVSegidsOfVSegd . pnested_uvsegd
pnested_pseglens   = U.lengthsSSegd . U.takeSSegdOfVSegd . pnested_uvsegd
pnested_psegstarts = U.startsSSegd  . U.takeSSegdOfVSegd . pnested_uvsegd
pnested_psegsrcids = U.sourcesSSegd . U.takeSSegdOfVSegd . pnested_uvsegd

mkPNested vsegids pseglens psegstarts psegsrcids psegdata
        = PNested
                (U.mkVSegd vsegids 
                        $ U.mkSSegd psegstarts psegsrcids
                        $ U.lengthsToSegd pseglens)
                psegdata

-- | Pretty print the physical representation of a nested array
instance PprPhysical (PData a) => PprPhysical (PData (PArray a)) where
 pprp (PNested uvsegd pdata)
  =   text "PNested"
  $+$ (nest 4 $ vcat 
        $ pprp uvsegd 
        : [ int n <> colon <> text " " <> pprp pd
                | n  <- [0..]
                | pd <- V.toList pdata])


instance (PR a, PprVirtual (PData a)) => PprVirtual (PData (PArray a)) where
 pprv arr
  =   lbrack <> hcat (punctuate comma (map pprv $ V.toList $ toVectorPR arr)) <> rbrack

     
deriving instance Show (PData a) 
        => Show (PData (PArray a))


-- Testing --------------------------------------------------------------------
-- TODO: shift this stuff into dph-base
validIx  :: String -> Int -> Int -> Bool
validIx str len ix 
        = check str len ix (ix >= 0 && ix < len)

validLen :: String -> Int -> Int -> Bool
validLen str len ix 
        = checkLen str len ix (ix >= 0 && ix <= len)

-- TODO: slurp debug flag from base 
validBool :: String -> Bool -> Bool
validBool str b
        = if b  then True 
                else error $ "validBool check failed -- " ++ str


-- Constructors ---------------------------------------------------------------
-- | Flatten a nested array into its segment descriptor and data.
--
--   WARNING: Doing this to replicated arrays can cause index overflow.
--            See the warning in `unsafeMaterializeUVSegd`.
--
unsafeFlattenPR :: PR a => PData (PArray a) -> (U.Segd, PData a)
{-# INLINE unsafeFlattenPR #-}
unsafeFlattenPR arr@(PNested uvsegd _)
 =      ( U.demoteToSegdOfVSegd uvsegd
        , concatPR arr)


instance U.Elt (Int, Int, Int)

-- PR Instances ---------------------------------------------------------------
instance PR a => PR (PArray a) where

  -- TODO: make this check all sub arrays as well
  -- TODO: ensure that all psegdata arrays are referenced from some psegsrc.
  -- TODO: shift segd checks into associated modules.
  {-# INLINE_PDATA validPR #-}
  validPR arr
   = let 
         vsegids        = pnested_vsegids     arr
         pseglens       = pnested_pseglens    arr
         psegstarts     = pnested_psegstarts  arr
         psegsrcs       = pnested_psegsrcids  arr
         psegdata       = pnested_psegdata    arr


        -- The lengths of the pseglens, psegstarts and psegsrcs fields must all be the same
         fieldLensOK
                = validBool "nested array field lengths not identical"
                $ and 
                [ U.length psegstarts == U.length pseglens
                , U.length psegsrcs   == U.length pseglens ]

         -- Every vseg must reference a valid pseg.
         vsegsRefOK
                = validBool "nested array vseg doesn't ref pseg"
                $ U.and
                $ U.map (\vseg -> vseg < U.length pseglens) vsegids
                
         
         -- Every pseg source id must point to a flat data array
         psegsrcsRefOK
                = validBool "nested array psegsrc doesn't ref flat array"
                $ U.and 
                $ U.map (\srcid -> srcid < V.length psegdata) psegsrcs

         -- Every physical segment must be a valid slice of the corresponding flat array.
         -- 
         --   We allow psegs with len 0, start 0 even if the flat array is empty.
         --   This occurs with [ [] ]. 
         -- 
         --   As a generalistion of above, we allow segments with len 0, start <= srclen.
         --   This occurs when there is an empty array as the last segment
         --   For example:
         --        [ [5, 4, 3, 2] [ ] ].
         --        PNested  vsegids:    [0,1]
         --                 pseglens:   [4,0]
         --                 psegstarts: [0,4]  -- last '4' here is <= length of flat array
         --                 psegsrcs:   [0,0]
         --                 PInt        [5, 4, 3, 2]
         --
         psegSlicesOK 
                = validBool "nested array pseg slices are invalid"
                $ U.and 
                $ U.zipWith3 
                        (\len start srcid
                           -> let srclen = lengthPR (psegdata V.! srcid)
                              in  and [    (len == 0 && start <= srclen)
                                        || validIx  "nested array psegstart " srclen start
                                      ,    validLen "nested array pseglen   " srclen (start + len)])
                        pseglens psegstarts psegsrcs

         -- Every pseg must be referenced by some vseg.
         vsegs   = IS.fromList $ U.toList vsegids
         psegsReffedOK
                =  validBool "nested array pseg not reffed by vseg"
                $  (U.length pseglens == 0) 
                || (U.and $ U.map (flip IS.member vsegs) 
                          $ U.enumFromTo 0 (U.length pseglens - 1))

     in  and [ fieldLensOK
             , vsegsRefOK
             , psegsrcsRefOK
             , psegSlicesOK
             , psegsReffedOK ]


  {-# INLINE_PDATA emptyPR #-}
  emptyPR = PNested U.emptyVSegd V.empty


  {-# INLINE_PDATA nfPR #-}
  nfPR    = error "nfPR[PArray]: not defined yet"


  {-# INLINE_PDATA lengthPR #-}
  lengthPR (PNested uvsegd _)
          = U.lengthOfVSegd uvsegd


  -- When replicating an array we use the source as the single physical
  -- segment, then point all the virtual segments to it.
  replicatePR c (PArray n darr)
   = {-# SCC "replicatePR" #-}
     checkNotEmpty "replicatePR[PArray]" c
   $ let -- Physical segment descriptor contains a single segment.
         ussegd  = U.singletonSSegd n
         
         -- All virtual segments point to the same physical segment.
         uvsegd  = U.mkVSegd (U.replicate c 0) ussegd

     in  PNested uvsegd (V.singleton darr)
  {-# NOINLINE replicatePR #-}
  --  NOINLINE because it's a cheap segment descriptor operation, 
  --  and doesn't need to fuse with anything.
                

  -- For segmented replicates, we just replicate the vsegids field.
  --
  -- TODO: Does replicate_s really need the whole segd,
  --       or could we get away without creating the indices field?
  --
  -- TODO: If we know the lens does not contain zeros, then we don't need
  --       to cull down the psegs.
  --
  {-# INLINE_PDATA replicatesPR #-}
  replicatesPR segd (PNested uvsegd pdata)
   = PNested (U.updateVSegsOfVSegd
                (\vsegids -> U.replicate_s segd vsegids) uvsegd)
             pdata  


  -- To index into a nested array, first determine what segment the index
  -- corresponds to, and extract that as a slice from that physical array.
  {-# INLINE_PDATA indexPR #-}
  indexPR (PNested uvsegd pdata) ix
   | (pseglen, psegstart, psegsrcid)    <- U.getSegOfVSegd uvsegd ix
   = let !psrc          = pdata `V.unsafeIndex` psegsrcid
         !pdata'        = extractPR psrc psegstart pseglen
     in  PArray pseglen pdata'


  -- Lifted indexing
  --
  -- source
  --   VIRT [ [[0],[1,2,3]], [[0],[1,2,3]]
  --        , [[5,6,7,8,9]], [[5,6,7,8,9]], [[5,6,7,8,9]]
  --        , [[7,8,9,10,11,12,13],[0],[1,2,3],[0],[5,6,7,8,9],[0],[1,2,3]] ]
  --
  --   PHYS PNested
  --          UVSegd vsegids: [0,0,1,1,1,2]
  --          USSegd lengths: [2,1,7]
  --                 indices: [0,2,3]
  --                 srcids:  [0,0,0]
  --          0: PNested
  --                 UVSegd vsegids: [0,1,2,3,4,5,6,7,8,9]
  --                 USSegd lengths: [1,3,5,7,1,3,1,5,1,3]
  --                        indices: [0,1,0,0,7,8,11,12,17,18]
  --                        srcids:  [0,0,1,2,2,2,2,2,2,2]
  --                 0: PInt [0,1,2,3]
  --                 1: PInt [5,6,7,8,9]
  --                 2: PInt [7,8,9,10,11,12,13,0,1,2,3,0,5,6,7,8,9,0,1,2,3]
  --
  -- indexl with [1, 0, 0, 0, 0, 4]
  --   VIRT  [[1,2,3],[0],[5,6,7,8,9],[5,6,7,8,9],[5,6,7,8,9],[1,2,3]]
  --   PHYS  PNested
  --           UVSegd vsegids: [0,1,2,3,4,5]
  --           USSegd lengths: [3,1,5,5,5,3]
  --                  indices: [1,0,0,0,0,8]
  --                  srcids:  [0,0,1,1,1,2]
  --           0: PInt [0,1,2,3]
  --           1: PInt [5,6,7,8,9]
  --           2: PInt [7,8,9,10,11,12,13,0,1,2,3,0,5,6,7,8,9,0,1,2,3]
  --
  {-# INLINE_PDATA indexlPR #-}
  indexlPR c (PNested uvsegd pdata) (PInt ixs)
   = let        
         -- See Note: psrcoffset
         psrcoffset     = V.prescanl (+) 0 $ V.map (V.length . pnested_psegdata) pdata

         -- length, start and srcid of the segments we're returning.
         --   Note that we need to offset the srcid 
         seginfo :: U.Array (Int, Int, Int)
         seginfo 
          = U.zipWith (\segid ix -> 
                        let (_,       segstart,  segsrcid)   = U.getSegOfVSegd uvsegd segid
                            (PNested uvsegd2 _)              = pdata V.! segsrcid
                            (len, start, srcid)              = U.getSegOfVSegd uvsegd2 (segstart + ix)
                        in  (len, start, srcid + (psrcoffset V.! segsrcid)))
                (U.enumFromTo 0 (c - 1))
                ixs

         (pseglens', psegstarts', psegsrcs')    
                        = U.unzip3 seginfo
                
         -- TODO: check that doing lengthsToSegd won't cause overflow
         uvsegd'        = U.promoteSSegdToVSegd
                        $ U.mkSSegd psegstarts' psegsrcs'
                        $ U.lengthsToSegd pseglens'
                                 
         -- All flat data arrays in the sources go into the result.
         psegdata'      = V.concat $ V.toList $ V.map pnested_psegdata pdata
         
    in  PNested uvsegd' psegdata'


  -- To extract a range of elements from a nested array, perform the extract
  -- on the vsegids field. The `updateVSegsOfUVSegd` function will then filter
  -- out all of the psegs that are no longer reachable from the new vsegids.
  {-# NOINLINE extractPR #-}
  extractPR (PNested uvsegd pdata) start len
   = {-# SCC "extractPR" #-}
     PNested (U.updateVSegsOfVSegd (\vsegids -> U.extract vsegids start len) uvsegd)
             pdata


  --   TODO: cleanup pnested projections
  --         use getSegOfUVSegd like in indexlPR

  -- [Note: psrcoffset]
  -- ~~~~~~~~~~~~~~~~~~
  -- As all the flat data arrays in the sources are present in the result array,
  -- we need to offset the psegsrcs field when combining multiple sources.
  -- 
  -- Exaple
  --  Source Arrays:
  --   arr0  ...
  --         psrcids  :  [0, 0, 0, 1, 1]
  --         psegdata :  [PInt xs1, PInt xs2]
  --
  --   arr1  ... 
  --         psrcids  :  [0, 0, 1, 1, 2, 2, 2]
  --         psegdata :  [PInt ys1, PInt ys2, PInt ys3]
  -- 
  --   Result Array:
  --         psrcids  :  [...]
  --         psegdata :  [PInt xs1, PInt xs2, PInt ys1, PInt ys2, PInt ys3] 
  --
  --  Note that references to flatdata arrays [0, 1, 2] in arr1 need to be offset
  --  by 2 (which is length arr0.psegdata) to refer to the same flat data arrays
  --  in the result.
  -- 
  --  We encode these offsets in the psrcoffset vector:
  --       psrcoffset :  [0, 2]
  --
  {-# NOINLINE extractsPR #-}
  extractsPR arrs ussegd
   = {-# SCC "extractsPR" #-}
     let segsrcs        = U.sourcesSSegd ussegd
         segstarts      = U.startsSSegd  ussegd
         seglens        = U.lengthsSSegd ussegd

         vsegids_src      = uextracts (V.map pnested_vsegids  arrs) segsrcs segstarts seglens

         srcids'          = U.replicate_s (U.lengthsToSegd seglens) segsrcs

         -- See Note: psrcoffset
         psrcoffset       = V.prescanl (+) 0 $ V.map (V.length . pnested_psegdata) arrs

         -- Unpack the lens and srcids arrays so we don't need to 
         -- go though all the segment descriptors each time.
         !arrs_pseglens   = V.map pnested_pseglens   arrs
         !arrs_psegstarts = V.map pnested_psegstarts arrs
         !arrs_psegsrcids = V.map pnested_psegsrcids arrs

         -- Function to get one element of the result.
         {-# INLINE get #-}
         get srcid vsegid
          = let !pseglen        = (arrs_pseglens   `V.unsafeIndex` srcid) `VU.unsafeIndex` vsegid
                !psegstart      = (arrs_psegstarts `V.unsafeIndex` srcid) `VU.unsafeIndex` vsegid
                !psegsrcid      = (arrs_psegsrcids `V.unsafeIndex` srcid) `VU.unsafeIndex` vsegid  
                                + psrcoffset `V.unsafeIndex` srcid
            in  (pseglen, psegstart, psegsrcid)
            
         (pseglens', psegstarts', psegsrcs')
                = U.unzip3 $ U.zipWith get srcids' vsegids_src

         -- All flat data arrays in the sources go into the result.
         psegdata'      = V.concat $ V.toList $ V.map pnested_psegdata arrs
   
         -- Build the result segment descriptor.
         vsegd'         = U.promoteSSegdToVSegd
                        $ U.mkSSegd psegstarts' psegsrcs'
                        $ U.lengthsToSegd pseglens'
   
     in  PNested vsegd' psegdata'


  -- Append nested arrays by appending the segment descriptors,
  -- and putting all physical arrays in the result.
  {-# INLINE_PDATA appendPR #-}
  appendPR (PNested uvsegd1 pdata1) (PNested uvsegd2 pdata2)
   = PNested    (U.appendVSegd
                        uvsegd1 (V.length pdata1) 
                        uvsegd2 (V.length pdata2))
                (pdata1 V.++ pdata2)


  -- Performing segmented append requires segments from the physical arrays to
  -- be interspersed, so we need to copy data from the second level of nesting.  
  --
  -- In the implementation we can safely flatten out replication in the vsegs
  -- because the source program result would have this same physical size
  -- anyway. Once this is done we use copying segmented append on the flat 
  -- arrays, and then reconstruct the segment descriptor.
  --
  {- INLINE_PDATA appendsPR #-}
  appendsPR rsegd segd1 xarr segd2 yarr
   = let (xsegd, xs)    = unsafeFlattenPR xarr
         (ysegd, ys)    = unsafeFlattenPR yarr
   
         xsegd' = U.lengthsToSegd 
                $ U.sum_s segd1 (U.lengthsSegd xsegd)
                
         ysegd' = U.lengthsToSegd
                $ U.sum_s segd2 (U.lengthsSegd ysegd)
                
         segd'  = U.lengthsToSegd
                $ U.append_s rsegd segd1 (U.lengthsSegd xsegd)
                                   segd2 (U.lengthsSegd ysegd)

     in  PNested (U.promoteSegdToVSegd segd')
                 (V.singleton 
                  $ appendsPR (U.plusSegd xsegd' ysegd')
                            xsegd' xs
                            ysegd' ys)
                

  -- Pack the vsegids to determine which of the vsegs are present in the result.
  --  eg  tags:           [0 1 1 1 0 0 0 0 1 0 0 0 0 1 0 1 0 1 1]   tag = 1
  --      vsegids:        [0 0 1 1 2 2 2 2 3 3 4 4 4 5 5 5 5 6 6]
  --  =>  vsegids_packed: [  0 1 1         3         5   5   6 6]
  --       
  {-# INLINE_PDATA packByTagPR #-}
  packByTagPR (PNested uvsegd pdata) tags tag
   = PNested (U.updateVSegsOfVSegd (\vsegids -> U.packByTag vsegids tags tag) uvsegd)
             pdata


  -- Combine nested arrays by combining the segment descriptors, 
  -- and putting all physical arrays in the result.
  {-# INLINE_PDATA combine2PR #-}
  combine2PR sel2 (PNested uvsegd1 pdata1) (PNested uvsegd2 pdata2)
   = PNested    (U.combine2VSegd sel2 
                        uvsegd1 (V.length pdata1)
                        uvsegd2 (V.length pdata2))
                (pdata1 V.++ pdata2)


  -- Conversions ----------------------
  {-# INLINE_PDATA fromVectorPR #-}
  fromVectorPR xx
   | V.length xx == 0 = emptyPR
   | otherwise
   = let segd      = U.lengthsToSegd $ U.fromList $ V.toList $ V.map lengthPA xx
     in  mkPNested
                (U.enumFromTo 0 (V.length xx - 1))
                (U.lengthsSegd segd)
                (U.indicesSegd segd)
                (U.replicate (V.length xx) 0)
                (V.singleton (V.foldl1 appendPR $ V.map unpackPA xx))


  {-# INLINE_PDATA toVectorPR #-}
  toVectorPR arr
   = V.generate (U.length (pnested_vsegids arr))
   $ indexPR arr


  fromUArrayPR  = error "fromUArrayPR[PArray]: not defined yet"   
  toUArrayPR    = error "toUArrayPR[PArray]: not defined et"


-------------------------------------------------------------------------------
-- | O(len result). Concatenate a nested array.
--
--   This physically performs a 'gather' operation, whereby array data is copied
--   through the index-space transformation defined by the segment descriptor.
--   We need to do this because discarding the segment descriptor means that we
--   can no-longer represent the data layout of the logical array other than by
--   physically creating it.
--
--   The segment descriptor keeps track of the layout of the data, and if it 
--   knows that the segments are already in a single, contiguous array with
--   no sharing then we can just return that array directly in O(1) time.
--
--   IMPORTANT:
--   In the case where there is sharing between segments, or they are scattered
--   through multiple arrays, only outer-most two levels of nesting are physically
--   merged. The data for lower levels is not touched. This ensures that concat
--   has complexity proportional to the length of the result array, instead
--   of the total number of elements within it.
--
concatPR :: PR a => PData (PArray a) -> PData a
concatPR arr = {-# SCC "concatPR" #-} concatPR' arr
concatPR' (PNested vsegd pdatas)
        -- If we know that the segments are in a single contiguous array, 
        -- and there is no sharing between them, then we can just return
        -- that array directly.
        | U.isManifestVSegd   vsegd
        , U.isContiguousVSegd vsegd
        , V.length pdatas == 1
        = pdatas `V.unsafeIndex` 0

        -- Otherwise we have to pull all the segments through the index 
        -- space transform defined by the vsegd, which copies them
        -- into a single contiguous array.
        | otherwise
        = let   -- Flatten out the virtualization of the vsegd so that we have
                -- a description of each segment individually.
                ussegd  = U.demoteToSSegdOfVSegd vsegd

                -- Copy these segments into a new array.
          in   extractsPR pdatas ussegd

{-# NOINLINE concatPR  #-}
--  TODO: we'll need to inline this when we take the second branch, 
--  to get specialisation for extractsPR.


-- | Build a nested array given a single flat data vector, 
--   and a template nested array that defines the segmentation.
-- 
--   Although the template nested array may be using vsegids to describe
--   internal sharing, the provided data array has manifest elements
--   for every segment. Because of this we need flatten out the virtual
--   segmentation of the template array.
--
unconcatPR :: PR a => PData (PArray a) -> PData b -> PData (PArray b)
unconcatPR (PNested vsegd pdatas) arr
 = {-# SCC "unconcatPR" #-}
   let  
        -- Demote the vsegd to a manifest vsegd so it contains all the segment
        -- lengths individually without going through the vsegids.
        !segd           = U.demoteToSegdOfVSegd vsegd

        -- Rebuild the vsegd based on the manifest vsegd. 
        -- The vsegids will be just [0..len-1], but this field is constructed
        -- lazilly and consumers aren't required to demand it.
        !vsegd'         = U.promoteSegdToVSegd segd

   in   PNested vsegd' (V.singleton arr)

{-# NOINLINE unconcatPR #-}
--  NOINLINE because it won't fuse with anything.
--  The operations is also entierly on the segment descriptor, so we don't 
--  need to inline it to specialise it for the element type.


-- | Lifted concat.
--   Both arrays must contain the same number of elements.
concatlPR :: PR a => PData (PArray (PArray a)) -> PData (PArray a)
concatlPR arr
 = let  (segd1, darr1)  = unsafeFlattenPR arr
        (segd2, darr2)  = unsafeFlattenPR darr1
        
        segd'           = U.mkSegd (U.sum_s segd1 (U.lengthsSegd segd2))
                                   (U.bpermute (U.indicesSegd segd2) (U.indicesSegd segd1))
                                   (U.elementsSegd segd2)

   in   PNested (U.promoteSegdToVSegd segd') 
                (V.singleton darr2)

{-# INLINE concatlPR #-}


-- | Lifted append.
--   Both arrays must contain the same number of elements.
appendlPR :: PR a => PData (PArray a) -> PData (PArray a) -> PData (PArray a)
{-# NOINLINE appendlPR #-}
appendlPR  arr1 arr2
 = let  (segd1, darr1)  = unsafeFlattenPR arr1
        (segd2, darr2)  = unsafeFlattenPR arr2
        segd'           = U.plusSegd segd1 segd2
   in   PNested (U.promoteSegdToVSegd segd' )
                (V.singleton
                 $ appendsPR segd' segd1 darr1 segd2 darr2)


-- | Extract some slices from some arrays.
--   The arrays of starting indices and lengths must themselves
--   have the same length.
--   TODO: cleanup pnested projections
slicelPR 
        :: PR a
        => PData Int            -- ^ starting indices of slices
        -> PData Int            -- ^ lengths of slices
        -> PData (PArray a)     -- ^ arrays to slice
        -> PData (PArray a)
{-# NOINLINE slicelPR #-}
slicelPR (PInt sliceStarts) (PInt sliceLens) arr

 = let  segs            = U.length vsegids
        vsegids        = pnested_vsegids     arr
        psegstarts     = pnested_psegstarts  arr
        psegsrcs       = pnested_psegsrcids  arr
        psegdata       = pnested_psegdata    arr
   in   
        mkPNested
                (U.enumFromTo 0 (segs - 1))
                sliceLens
                (U.zipWith (+) (U.bpermute psegstarts vsegids) sliceStarts)
                (U.bpermute psegsrcs vsegids)
                psegdata
