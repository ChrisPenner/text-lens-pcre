{-|
Module      : Control.Lens.Regex
Description : PCRE regex combinators for interop with lens
Copyright   : (c) Chris Penner, 2019
License     : BSD3
-}

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Control.Lens.Regex.ByteString
    (
    -- * Combinators
      regex
    , match
    , groups
    , group
    , matchAndGroups

    -- * Compiling regexes
    , rx
    , mkRegexQQ
    , compile
    , compileM

    -- * Types
    , Regex
    , Match
    ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Builder as BS
import Text.Regex.PCRE.Heavy
import Text.Regex.PCRE.Light (compile)
import Control.Lens hiding (re, matching)
import Data.Bifunctor
import Language.Haskell.TH.Quote

-- $setup
-- >>> :set -XQuasiQuotes
-- >>> :set -XOverloadedStrings
-- >>> :set -XTypeApplications
-- >>> import qualified Data.ByteString.Char8 as Char8
-- >>> import Data.Char
-- >>> import Data.List hiding (group)
-- >>> import Data.ByteString.Lens

-- | Match represents a whole regex match; you can drill into it using 'match' or 'groups' or 'matchAndGroups'
--
-- Consider this to be internal; its representation may change on patch on non-major version bumps
type Match = [Either BS.Builder BS.Builder]
type MatchRange = (Int, Int)
type GroupRanges = [(Int, Int)]

unBuilder :: BS.Builder -> BS.ByteString
unBuilder = BL.toStrict . BS.toLazyByteString

building :: Iso' BS.Builder BS.ByteString
building = iso unBuilder BS.byteString

-- | Access all groups of a match as a list. Stashes the full match text as the index in case
-- you need it.
--
-- Note that you can edit the groups through this traversal,
-- Changing the length of the list has behaviour similar to 'partsOf'.
--
-- Get all matched groups:
--
-- >>> "raindrops on roses and whiskers on kittens" ^.. regex [rx|(\w+) on (\w+)|] . groups
-- [["raindrops","roses"],["whiskers","kittens"]]
--
-- You can access a specific group combining with 'ix', or just use 'group' instead
--
-- >>> "raindrops on roses and whiskers on kittens" ^.. regex [rx|(\w+) on (\w+)|] . groups .  ix 1
-- ["roses","kittens"]
--
-- Editing groups:
--
-- >>> "raindrops on roses and whiskers on kittens" & regex [rx|(\w+) on (\w+)|] . groups .  ix 1 %~ Char8.map toUpper
-- "raindrops on ROSES and whiskers on KITTENS"
--
-- Editing the list rearranges groups
--
-- >>> "raindrops on roses and whiskers on kittens" & regex [rx|(\w+) on (\w+)|] . groups %~ reverse
-- "roses on raindrops and kittens on whiskers"
--
-- You can traverse the list to flatten out all groups
--
-- >>> "raindrops on roses and whiskers on kittens" ^.. regex [rx|(\w+) on (\w+)|] . groups . traversed
-- ["raindrops","roses","whiskers","kittens"]
--
-- Use indexed helpers to access the full match when operating on a group.
--
-- This replaces each group with the full match text wrapped in parens:
--
-- >>> "one-two" & regex [rx|(\w+)-(\w+)|] . groups <. traversed %@~ \mtch grp -> grp <> ":(" <> mtch <> ")"
-- "one:(one-two)-two:(one-two)"
groups :: IndexedTraversal' BS.ByteString Match [BS.ByteString]
groups = conjoined groupsT (reindexed (view match) selfIndex <. groupsT)
    where
      groupsT :: Traversal' Match [BS.ByteString]
      groupsT = partsOf (traversed . _Right . building)

-- | Access a specific group of a match. Numbering starts at 0.
--
-- Stashes the full match text as the index in case you need it.
--
-- See 'groups' for more info on grouping
--
-- >>> "key:value, a:b" ^.. regex [rx|(\w+):(\w+)|] . group 0
-- ["key","a"]
--
-- >>> "key:value, a:b" ^.. regex [rx|(\w+):(\w+)|] . group 1
-- ["value","b"]
--
-- >>> "key:value, a:b" & regex [rx|(\w+):(\w+)|] . group 1 %~ Char8.map toUpper
-- "key:VALUE, a:B"
--
-- Replace the first capture group with the full match:
--
-- >>> "a, b" & regex [rx|(\w+), (\w+)|] . Control.Lens.Regex.ByteString.group 0 .@~ \i -> "(" <> i <> ")"
-- "(a, b), b"
group :: Int -> IndexedTraversal' BS.ByteString Match BS.ByteString
group n = groups <. ix n

-- | Traverse each match
--
-- Stashes any matched groups into the index in case you need them.
--
--  Get a match if one exists:
--
-- >>> "find a needle in a haystack" ^? regex [rx|n..dle|] . match
-- Just "needle"
--
--  Collect all matches
--
-- >>> "one _two_ three _four_" ^.. regex [rx|_\w+_|] . match
-- ["_two_","_four_"]
--
-- You can edit the traversal to perform a regex replace/substitution
--
-- >>> "one _two_ three _four_" & regex [rx|_\w+_|] . match %~ Char8.map toUpper
-- "one _TWO_ three _FOUR_"
--
-- Here we use the group matches stored in the index to form key-value pairs, replacing the entire match.
--
-- >>> "abc-def, ghi-jkl" & regex [rx|(\w+)-(\w+)|] . match %@~ \[k, v] _ -> "{" <> k <> ":" <> v <> "}"
-- "{abc:def}, {ghi:jkl}"
match :: IndexedTraversal' [BS.ByteString] Match BS.ByteString
match = conjoined matchBS (reindexed (view groups) selfIndex <. matchBS)
  where
    matchBS :: Traversal' Match BS.ByteString
    matchBS = matchT . building
    matchT :: Traversal' Match BS.Builder
    matchT f grps =
        (:[]) . Right <$> f (grps ^. folded . chosen)

-- | The base combinator for doing regex searches.
-- It's a traversal which selects 'Match'es; compose it with 'match' or 'groups'
-- to get the relevant parts of your match.
--
-- >>> txt = "raindrops on roses and whiskers on kittens"
--
-- Search
--
-- >>> has (regex [rx|whisk|]) txt
-- True
--
-- Get matches
--
-- >>> txt ^.. regex [rx|\br\w+|] . match
-- ["raindrops","roses"]
--
-- Edit matches
--
-- >>> txt & regex [rx|\br\w+|] . match %~ Char8.intersperse '-' . Char8.map toUpper
-- "R-A-I-N-D-R-O-P-S on R-O-S-E-S and whiskers on kittens"
--
-- Get Groups
--
-- >>> txt ^.. regex [rx|(\w+) on (\w+)|] . groups
-- [["raindrops","roses"],["whiskers","kittens"]]
--
-- Edit Groups
--
-- >>> txt & regex [rx|(\w+) on (\w+)|] . groups %~ reverse
-- "roses on raindrops and kittens on whiskers"
--
-- Get the third match
--
-- >>> txt ^? regex [rx|\w+|] . index 2 . match
--Just "roses"
--
-- Edit matches
--
-- >>> txt & regex [rx|\br\w+|] . match %~ Char8.intersperse '-' . Char8.map toUpper
-- "R-A-I-N-D-R-O-P-S on R-O-S-E-S and whiskers on kittens"
--
-- Get Groups
--
-- >>> txt ^.. regex [rx|(\w+) on (\w+)|] . groups
-- [["raindrops","roses"],["whiskers","kittens"]]
--
-- Edit Groups
--
-- >>> txt & regex [rx|(\w+) on (\w+)|] . groups %~ reverse
-- "roses on raindrops and kittens on whiskers"
--
-- Get the third match
--
-- >>> txt ^? regex [rx|\w+|] . index 2 . match
-- Just "roses"
--
-- Match integers, 'Read' them into ints, then sort them in-place
-- dumping them back into the source text afterwards.
--
-- >>> "Monday: 29, Tuesday: 99, Wednesday: 3" & partsOf (regex [rx|\d+|] . match . from packedChars . _Show @Int) %~ sort
-- "Monday: 3, Tuesday: 29, Wednesday: 99"
--
-- To alter behaviour of the regex you may wish to pass 'PCREOption's when compiling it.
-- The default behaviour may seem strange in certain cases; e.g. it operates in 'single-line'
-- mode. You can 'compile' the 'Regex' separately and add any options you like, then pass the resulting
-- 'Regex' into 'regex';
-- Alternatively can make your own version of the QuasiQuoter with any options you want embedded
-- by using 'mkRegexQQ'.
regex :: Regex -> IndexedTraversal' Int BS.ByteString Match
regex pattern = conjoined (regexT pattern) (indexing (regexT pattern))

-- | Base regex traversal. Used only to define 'regex' traversal
regexT :: Regex -> Traversal' BS.ByteString [Either BS.Builder BS.Builder]
regexT pattern f txt = unBuilder . collapseMatch <$> apply (splitAll txt matches)
  where
    matches :: [(MatchRange, GroupRanges)]
    matches = scanRanges pattern txt
    collapseMatch :: [Either BS.Builder [Either BS.Builder BS.Builder]] -> BS.Builder
    collapseMatch xs = xs ^. folded . beside id (traversed . chosen)
    apply xs = xs & traversed . _Right %%~ f

-- | Collect both the match text AND all the matching groups
--
-- >>> "raindrops on roses and whiskers on kittens" ^.. regex [rx|(\w+) on (\w+)|] . matchAndGroups
-- [("raindrops on roses",["raindrops","roses"]),("whiskers on kittens",["whiskers","kittens"])]
matchAndGroups :: Getter Match (BS.ByteString, [BS.ByteString])
matchAndGroups = to $ \m -> (m ^. match, m ^. groups)

-- | 'QuasiQuoter' for compiling regexes.
-- This is just 're' re-exported under a different name so as not to conflict with @re@ from
-- 'Control.Lens'
rx :: QuasiQuoter
rx = re

---------------------------------------------------------------------------------------------

splitAll :: BS.ByteString -> [(MatchRange, GroupRanges)] -> [Either BS.Builder [Either BS.Builder BS.Builder]]
splitAll txt matches = fmap (second (\(txt', (start,_), grps) -> groupSplit txt' start grps)) splitUp
  where
    splitUp = splits txt 0 matches

groupSplit :: BS.ByteString -> Int -> GroupRanges -> [Either BS.Builder BS.Builder]
groupSplit txt _ [] = [Left $ BS.byteString txt]
groupSplit txt offset ((grpStart, grpEnd) : rest) | offset == grpStart =
    let (prefix, suffix) = BS.splitAt (grpEnd - offset) txt
     in Right (BS.byteString prefix) : groupSplit suffix grpEnd rest
groupSplit txt offset ((grpStart, grpEnd) : rest) =
    let (prefix, suffix) = BS.splitAt (grpStart - offset) txt
     in Left (BS.byteString prefix) : groupSplit suffix grpStart ((grpStart, grpEnd) : rest)

splits :: BS.ByteString -> Int -> [(MatchRange, GroupRanges)] -> [Either BS.Builder (BS.ByteString, MatchRange, GroupRanges)]
-- No more matches left
splits txt _ [] = [Left $ BS.byteString txt]
-- We're positioned at a match
splits txt offset (((start, end), grps) : rest) | offset == start =
    let (prefix, suffix) = BS.splitAt (end - offset) txt
     in (Right (prefix, (start, end), grps)) : splits suffix end rest
-- jump to the next match
splits txt offset matches@(((start, _), _) : _) =
    let (prefix, suffix) = BS.splitAt (start - offset) txt
     in (Left $ BS.byteString prefix) : splits suffix start matches
