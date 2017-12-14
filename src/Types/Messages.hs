{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}

{-|

The 'Message' is a single displayed event in a Channel.  All Messages
have a date/time, and messages that represent posts to the channel
have a (hash) ID, and displayable text, along with other attributes.

All Messages are sorted chronologically.  There is no assumption that
the server date/time is synchronized with the local date/time, so all
of the Message ordering uses the server's date/time.

The mattermost-api retrieves a 'Post' from the server, briefly encodes
the useful portions of that as a 'ClientPost' object and then converts
it to a 'Message' inserting this result it into the collection of
Messages associated with a Channel.  The PostID of the message
uniquely identifies that message and can be used to interact with the
server for subsequent operations relative to that message's 'Post'.
The date/time associated with these messages is generated by the
server.

There are also "messages" generated directly by the Matterhorn client
which can be used to display additional, client-related information to
the user. Examples of these client messages are: date boundaries, the
"new messages" marker, errors from invoking the browser, etc.  These
client-generated messages will have a date/time although it is locally
generated (usually by relation to an associated Post).

Most other Matterhorn operations primarily are concerned with
user-posted messages (@case mPostId of Just _@ or @case mType of CP
_@), but others will include client-generated messages (@case mPostId
of Nothing@ or @case mType of C _@).

--}

module Types.Messages
  ( -- * Message and operations on a single Message
    Message(..)
  , isDeletable, isReplyable, isEditable, isReplyTo
  , mText, mUserName, mDate, mType, mPending, mDeleted
  , mAttachments, mInReplyToMsg, mPostId, mReactions, mFlagged
  , mOriginalPost, mChannelId
  , MessageType(..)
  , ReplyState(..)
  , clientMessageToMessage
  , newMessageOfType
    -- * Message Collections
  , Messages
  , ChronologicalMessages
  , RetrogradeMessages
  , MessageOps (..)
  , noMessages
  , filterMessages
  , reverseMessages
  , unreverseMessages
    -- * Operations on Posted Messages
  , splitMessages
  , findMessage
  , getNextPostId
  , getPrevPostId
  , getLatestPostId
  , findLatestUserMessage
  , messagesAfter
  )
where

import           Cheapskate (Blocks)
import           Control.Applicative
import qualified Data.Map.Strict as Map
import           Data.Maybe (isJust)
import qualified Data.Sequence as Seq
import qualified Data.Text as T
import           Lens.Micro.Platform
import           Network.Mattermost.Types (ChannelId, PostId, Post, ServerTime)
import           Types.Posts

-- ----------------------------------------------------------------------
-- * Messages

-- | A 'Message' is any message we might want to render, either from
--   Mattermost itself or from a client-internal source.
data Message = Message
  { _mText          :: Blocks
  , _mUserName      :: Maybe T.Text
  , _mDate          :: ServerTime
  , _mType          :: MessageType
  , _mPending       :: Bool
  , _mDeleted       :: Bool
  , _mAttachments   :: Seq.Seq Attachment
  , _mInReplyToMsg  :: ReplyState
  , _mPostId        :: Maybe PostId
  , _mReactions     :: Map.Map T.Text Int
  , _mOriginalPost  :: Maybe Post
  , _mFlagged       :: Bool
  , _mChannelId     :: Maybe ChannelId
  } deriving (Show)

isDeletable :: Message -> Bool
isDeletable m = _mType m `elem` [CP NormalPost, CP Emote]

isReplyable :: Message -> Bool
isReplyable m = _mType m `elem` [CP NormalPost, CP Emote]

isEditable :: Message -> Bool
isEditable m = _mType m `elem` [CP NormalPost, CP Emote]

isReplyTo :: PostId -> Message -> Bool
isReplyTo expectedParentId m =
    case _mInReplyToMsg m of
        NotAReply                -> False
        InReplyTo actualParentId -> actualParentId == expectedParentId

-- | A 'Message' is the representation we use for storage and
--   rendering, so it must be able to represent either a
--   post from Mattermost or an internal message. This represents
--   the union of both kinds of post types.
data MessageType = C ClientMessageType
                 | CP ClientPostType
                 deriving (Eq, Show)

-- | The 'ReplyState' of a message represents whether a message
--   is a reply, and if so, to what message
data ReplyState =
    NotAReply
    | InReplyTo PostId
    deriving (Show)

-- | Convert a 'ClientMessage' to a 'Message'.  A 'ClientMessage' is
-- one that was generated by the Matterhorn client and which the
-- server knows nothing about.  For example, an error message
-- associated with passing a link to the local browser.
clientMessageToMessage :: ClientMessage -> Message
clientMessageToMessage cm = Message
  { _mText          = getBlocks (cm^.cmText)
  , _mUserName      = Nothing
  , _mDate          = cm^.cmDate
  , _mType          = C $ cm^.cmType
  , _mPending       = False
  , _mDeleted       = False
  , _mAttachments   = Seq.empty
  , _mInReplyToMsg  = NotAReply
  , _mPostId        = Nothing
  , _mReactions     = Map.empty
  , _mOriginalPost  = Nothing
  , _mFlagged       = False
  , _mChannelId     = Nothing
  }

newMessageOfType :: T.Text -> MessageType -> ServerTime -> Message
newMessageOfType text typ d = Message
  { _mText         = getBlocks text
  , _mUserName     = Nothing
  , _mDate         = d
  , _mType         = typ
  , _mPending      = False
  , _mDeleted      = False
  , _mAttachments  = Seq.empty
  , _mInReplyToMsg = NotAReply
  , _mPostId       = Nothing
  , _mReactions    = Map.empty
  , _mOriginalPost = Nothing
  , _mFlagged      = False
  , _mChannelId    = Nothing
  }

-- ** 'Message' Lenses

makeLenses ''Message

-- ----------------------------------------------------------------------

-- These declarations allow the use of a DirectionalSeq, which is a Seq
-- that uses a phantom type to identify the ordering of the elements
-- in the sequence (Forward or Reverse).  The constructors are not
-- exported from this module so that a DirectionalSeq can only be
-- constructed by the functions in this module.

data Chronological
data Retrograde
class SeqDirection a
instance SeqDirection Chronological
instance SeqDirection Retrograde

data SeqDirection dir => DirectionalSeq dir a =
    DSeq { dseq :: Seq.Seq a }
         deriving (Show, Functor, Foldable, Traversable)

instance SeqDirection a => Monoid (DirectionalSeq a Message) where
    mempty = DSeq mempty
    mappend a b = DSeq $ mappend (dseq a) (dseq b)

onDirectedSeq :: SeqDirection dir => (Seq.Seq a -> Seq.Seq b)
              -> DirectionalSeq dir a -> DirectionalSeq dir b
onDirectedSeq f = DSeq . f . dseq

-- ----------------------------------------------------------------------

-- * Message Collections

-- | A wrapper for an ordered, unique list of 'Message' values.
--
-- This type has (and promises) the following instances: Show,
-- Functor, Monoid, Foldable, Traversable
type ChronologicalMessages = DirectionalSeq Chronological Message
type Messages = ChronologicalMessages

-- | There are also cases where the list of 'Message' values are kept
-- in reverse order (most recent -> oldest); these cases are
-- represented by the `RetrogradeMessages` type.
type RetrogradeMessages = DirectionalSeq Retrograde Message

-- ** Common operations on Messages

filterMessages ::
  SeqDirection seq =>
  (Message -> Bool) ->
  DirectionalSeq seq Message ->
  DirectionalSeq seq Message
filterMessages p = onDirectedSeq (Seq.filter p)

class MessageOps a where
    addMessage :: Message -> a -> a

instance MessageOps ChronologicalMessages where
    addMessage m ml =
        case Seq.viewr (dseq ml) of
            Seq.EmptyR -> DSeq $ Seq.singleton m
            _ Seq.:> l ->
                case compare (m^.mDate) (l^.mDate) of
                  GT -> DSeq $ dseq ml Seq.|> m
                  EQ -> if m^.mPostId == l^.mPostId && isJust (m^.mPostId)
                        then ml
                        else dirDateInsert m ml
                  LT -> dirDateInsert m ml

dirDateInsert :: Message -> ChronologicalMessages -> ChronologicalMessages
dirDateInsert m = onDirectedSeq $ finalize . foldr insAfter initial
   where initial = (Just m, mempty)
         insAfter c (Nothing, l) = (Nothing, c Seq.<| l)
         insAfter c (Just n, l) =
             case compare (n^.mDate) (c^.mDate) of
               GT -> (Nothing, c Seq.<| (n Seq.<| l))
               EQ -> if n^.mPostId == c^.mPostId && isJust (c^.mPostId)
                     then (Nothing, c Seq.<| l)
                     else (Just n, c Seq.<| l)
               LT -> (Just n, c Seq.<| l)
         finalize (Just n, l) = n Seq.<| l
         finalize (_, l) = l

noMessages :: Messages
noMessages = DSeq mempty

-- | Reverse the order of the messages
reverseMessages :: Messages -> RetrogradeMessages
reverseMessages = DSeq . Seq.reverse . dseq

-- | Unreverse the order of the messages
unreverseMessages :: RetrogradeMessages -> Messages
unreverseMessages = DSeq . Seq.reverse . dseq

-- ----------------------------------------------------------------------
-- * Operations on Posted Messages

-- | Searches for the specified PostId and returns a tuple where the
-- first element is the Message associated with the PostId (if it
-- exists), and the second element is another tuple: the first element
-- of the second is all the messages from the beginning of the list to
-- the message just before the PostId message (or all messages if not
-- found) *in reverse order*, and the second element of the second are
-- all the messages that follow the found message (none if the message
-- was never found) in *forward* order.
splitMessages :: Maybe PostId
              -> Messages
              -> (Maybe Message, (RetrogradeMessages, Messages))
splitMessages Nothing msgs =
    (Nothing, (DSeq $ Seq.reverse $ dseq msgs, noMessages))
splitMessages pid msgs =
    -- n.b. searches from the end as that is usually where the message
    -- is more likely to be found.  There is usually < 1000 messages
    -- total, so this does not need hyper efficiency.
    case Seq.viewr (dseq msgs) of
      Seq.EmptyR  -> (Nothing, (reverseMessages noMessages, noMessages))
      ms Seq.:> m -> if m^.mPostId == pid
                     then (Just m, (DSeq $ Seq.reverse ms, noMessages))
                     else let (a, (b,c)) = splitMessages pid $ DSeq ms
                          in case a of
                               Nothing -> (a, (DSeq $ m Seq.<| (dseq b), c))
                               Just _  -> (a, (b, DSeq $ (dseq c) Seq.|> m))

-- | findMessage searches for a specific message as identified by the
-- PostId.  The search starts from the most recent messages because
-- that is the most likely place the message will occur.
findMessage :: PostId -> Messages -> Maybe Message
findMessage pid msgs =
    Seq.findIndexR (\m -> m^.mPostId == Just pid) (dseq msgs)
    >>= Just . Seq.index (dseq msgs)

-- | Look forward for the first Message that corresponds to a user
-- Post (i.e. has a post ID) that follows the specified PostId
getNextPostId :: Maybe PostId -> Messages -> Maybe PostId
getNextPostId = getRelPostId foldl

-- | Look backwards for the first Message that corresponds to a user
-- Post (i.e. has a post ID) that comes before the specified PostId.
getPrevPostId :: Maybe PostId -> Messages -> Maybe PostId
getPrevPostId = getRelPostId $ foldr . flip

-- | Find the next PostId after the specified PostId (if there is one)
-- by folding in the specified direction
getRelPostId :: ((Either PostId (Maybe PostId)
                      -> Message
                      -> Either PostId (Maybe PostId))
                -> Either PostId (Maybe PostId)
                -> Messages
                -> Either PostId (Maybe PostId))
             -> Maybe PostId
             -> Messages
             -> Maybe PostId
getRelPostId folD jp = case jp of
                         Nothing -> getLatestPostId
                         Just p -> either (const Nothing) id . folD fnd (Left p)
    where fnd = either fndp fndnext
          fndp c v = if v^.mPostId == Just c then Right Nothing else Left c
          idOfPost m = if m^.mDeleted then Nothing else m^.mPostId
          fndnext n m = Right (n <|> idOfPost m)

-- | Find the most recent message that is a Post (as opposed to a
-- local message) (if any).
getLatestPostId :: Messages -> Maybe PostId
getLatestPostId msgs =
    Seq.findIndexR valid (dseq msgs)
    >>= _mPostId <$> Seq.index (dseq msgs)
    where valid m = not (m^.mDeleted) && isJust (m^.mPostId)


-- | Find the most recent message that is a message posted by a user
-- that matches the test (if any), skipping local client messages and
-- any user event that is not a message (i.e. find a normal message or
-- an emote).
findLatestUserMessage :: (Message -> Bool) -> Messages -> Maybe Message
findLatestUserMessage f msgs =
    case getLatestPostId msgs of
        Nothing -> Nothing
        Just pid -> findUserMessageFrom pid msgs
    where findUserMessageFrom p ms =
              let Just msg = findMessage p ms
              in if f msg
                 then Just msg
                 else case getPrevPostId (msg^.mPostId) msgs of
                        Nothing -> Nothing
                        Just p' -> findUserMessageFrom p' msgs

-- | Return all messages that were posted after the specified date/time.
messagesAfter :: ServerTime -> Messages -> Messages
messagesAfter viewTime = onDirectedSeq $ Seq.takeWhileR (\m -> m^.mDate > viewTime)
