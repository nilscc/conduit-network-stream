-- | The network stream header design is inspired by the variable length
-- integers used in Googles Protocol Buffers (protobuf): Each stream block is
-- preceded by a binary header of variable length. There are currently 3 types
-- of headers:
--
--  * The beginning of a conduit block is encoded as @[0, MSB]@
--  * The end of a conduit block is encoded as @[1, MSB]@
--  * Length definition of the current block, encoded as variable length integer
--
-- Each header byte consists of 7 bits + the "most significant bit". For
-- example, the number 256 in its binary representation is:
--
-- > 1 0000 0000
--
-- First, split the number into 7-bit packages (add 0s to the front if
-- necessary):
--
-- > 0000 010   0000 000
--
-- These 7-bit packages are then reversed in order and encoded as 8-bit bytes
-- where the last bit marks the end of our header if set, for example:
--
-- > 0000 000   0000 010   --  reverse order
-- > 0000 0000  0000 0101  --  set 8th bit
-- >         _          X  --  (unset = _, set = X):
--
-- Another example would be the representation of the number 65536, or
--
-- > 1 0000 0000 0000 0000
--
-- as
--
-- > 0000 100   0000 000   0000 000   --  7 bit packages
-- > 0000 000   0000 000   0000 100   --  reverse order
-- > 0000 0000  0000 0000  0000 1001  --  set 8th bit
-- >         _          _          X
--
-- Distinction between sepcial headers (such as the start or end of conduit
-- blocks) and regular variable length integers is done by checking the most
-- significant (i.e. last) byte. In a variable length integer, the first 7 bits
-- of the MSB are always bigger than 0, while special headers are ended by the
-- byte "00000001":
--
-- > 0000 0000  0000 0001  --  special header: conduit block start
-- > 0000 0010  0000 0001  --  special header: conduit block end
-- > 0000 0011             --  block of length 1
-- > 0000 0101             --  block of length 2
-- > 0000 1001             --  block of length 4
-- > 1111 1111             --  block of length 127
-- > 0000 0000  0000 0011  --  block of length 128 (note the 7 bit shift)
-- > 0000 0010  0000 0011  --  block of length 129

module Data.Conduit.Network.Stream.Header where

import Data.Bits
--import Data.Enum
import Data.Word
import Data.Conduit
-- import Data.Conduit.Network.Stream.Exceptions

import qualified Data.Conduit.Binary  as CB
import qualified Data.ByteString      as BS
--import qualified Data.ByteString.Lazy as BL

data Header
  = ConduitSTART
  | ConduitEND
  | VarInt Int
  | InvalidHeader [Word8]
  | EndOfInput
  deriving (Show)

-- | Make the current \"7-bit byte\" the most significant byte in the header
mkMSB :: Word8 -> Word8
mkMSB = setBit `flip` 7

specialHeaderMSB :: Word8
specialHeaderMSB = mkMSB 0

-- | Test wether or not a byte is the most significant byte of a special header
-- (i.e. 8th bit = 1, rest = 0)
isSpecialHeaderMSB :: Word8 -> Bool
isSpecialHeaderMSB = (specialHeaderMSB ==)

-- | Test wether or not a byte is the most significant byte (i.e. the last byte
-- of a header block)
isMSB :: Word8 -> Bool
isMSB = testBit `flip` 7

varint :: (Show int, Integral int) => int -> [Word8]
varint int = go (fromIntegral int :: Integer) []
 where
  go i l =
    let w8 = fromIntegral $ 127 .&. i -- take the first 7 bits
        r  = shiftR i 7               -- shift the rest of the bits to the right
     in if r == 0
           then l ++ [mkMSB w8]
           else go r (l ++ [w8])

fromVarint :: (Show int, Integral int, Bits int) => [Word8] -> int
fromVarint []    = 0
fromVarint [x]   = fromIntegral $ x `clearBit` 7
fromVarint (w:r) = fromIntegral w + shiftL (fromVarint r) 7

condStart, condEnd :: [Word8]
condStart = [0, mkMSB 0]
condEnd   = [1, mkMSB 0]

-- | A decode 'ByteString' sink which returns the current header
decodeHeader :: Monad m => Consumer BS.ByteString m Header
decodeHeader = go []
 where
  go w8s = do
    h <- CB.head
    case h of
         Nothing -> return EndOfInput
         Just w8 | isSpecialHeaderMSB w8 -> spec w8s
                 | isMSB w8              -> var  (w8s ++ [w8])
                 | otherwise             -> go   (w8s ++ [w8])

  -- special header decoding
  spec [0] = return ConduitSTART
  spec [1] = return ConduitEND
  spec w8s = return $ InvalidHeader w8s

  -- var int decoding
  var  vi  = return $ VarInt (fromVarint vi)

encodeHeader :: Header -> Maybe BS.ByteString
encodeHeader ConduitSTART = Just $ BS.pack condStart
encodeHeader ConduitEND   = Just $ BS.pack condEnd
encodeHeader (VarInt vi)  = Just $ BS.pack (varint vi)
encodeHeader _            = Nothing
