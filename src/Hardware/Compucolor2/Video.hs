{-# LANGUAGE NumericUnderscores, RecordWildCards, ViewPatterns #-}
{-# LANGUAGE ApplicativeDo #-}
module Hardware.Compucolor2.Video where

import Clash.Prelude
import qualified Clash.Signal.Delayed.Bundle as D
import RetroClash.Utils
import RetroClash.VGA
import RetroClash.Video
import RetroClash.Delayed
import RetroClash.Barbies

import Hardware.Compucolor2.CRT5027 as CRT5027

import Control.Monad
import Data.Maybe (isJust, fromMaybe)

type FontWidth = 6
type FontHeight = 8

type VidSize = TextWidth * TextHeight * 2
type VidAddr = Index VidSize

-- | 40 MHz clock, needed for the VGA mode we use.
createDomain vSystem{vName="Dom40", vPeriod = hzToPeriod 40_000_000}

video
    :: (HiddenClockResetEnable Dom40)
    => Signals Dom40 CRT5027.Output
    -> Signal Dom40 (Maybe (Bool, VidAddr))
    -> Signal Dom40 (Maybe (Unsigned 8))
    -> ( VGAOut Dom40 8 8 8
       , Signal Dom40 Bool
       , Signal Dom40 (Maybe (Unsigned 8))
       )
video CRT5027.MkOutput{..} (unsafeFromSignal -> extAddr) (unsafeFromSignal -> extWrite) =
    ( delayVGA vgaSync rgb
    , toSignal $ delayI False frameEnd <* rgb
    , toSignal extRead
    )
  where
    VGADriver{..} = vgaDriver vga800x600at60
    -- (vgaY', scanline) = scale (SNat @2) . center $ vgaY
    (fromSignal -> textX, fromSignal -> glyphX) = scale (SNat @6) . fst . scale (SNat @2) . center $ vgaX
    (fromSignal -> textY, fromSignal -> glyphY) = scale (SNat @8) . fst . scale (SNat @2) . center $ vgaY

    frameEnd = liftD (isFalling False) (isJust <$> textY)

    newChar = liftD (isRising False) $ glyphX .== Just 0

    charAddr = do
        x <- textX
        y <- textY
        newChar <- newChar
        pure $ case (x, y, newChar) of
            (Just x, Just y, True) -> Just $ bitCoerce (y, x, (0 :: Index 2))
            _ -> Nothing

    (extAddr1, extAddr2) = D.unbundle $ unbraid <$> extAddr
    extRead1 :> charLoad :> extRead2 :> Nil = sharedDelayed (ram . D.unbundle) $
        extAddr1 `withWrite` extWrite :>
        noWrite charAddr :>
        extAddr2 `withWrite` extWrite :>
        Nil
      where
        ram (addr, wr) = delayedRam (blockRamU ClearOnReset (SNat @VidSize) (const 0)) addr (packWrite <$> addr <*> wr)

    extRead = mplus <$> extRead1 <*> extRead2

    -- TODO: why do we need the type annotation on `isChar`, when
    -- `glyphLoad`'s def should constrain it to `Bool`?
    (isChar, glyphAddr) = D.unbundle $ bitCoerce @_ @(Bool, _) . fromMaybe 0 <$> charLoad

    glyphLoad = mux (delayI False isChar)
        (fontRom glyphAddr (fromMaybe 0 <$> delayI Nothing glyphY))
        (pure 0x00) -- TODO: get glyph data from char itself
    newCol = liftD (changed Nothing) glyphX
    glyphRow = delayedRegister 0x00 $ \glyphRow ->
      mux (delayI False newChar) glyphLoad $
      mux (delayI False newCol) ((`shiftL` 1) <$> glyphRow) $
      glyphRow

    rgb = do
        x <- delayI Nothing textX
        y <- delayI Nothing textY
        cursor <- delayI Nothing $ fromSignal cursor
        pixel <- bitToBool . msb <$> glyphRow

        pure $ case liftA2 (,) x y of
            Nothing -> (0x30, 0x30, 0x30)
            Just (x, y) -> if pixel `xor` isCursor then (maxBound, maxBound, maxBound) else (minBound, minBound, minBound)
              where
                isCursor = cursor == Just (x', y')
                x' = fromIntegral @(Index TextWidth) x
                y' = fromIntegral @(Index TextHeight) y

unbraid :: Maybe (Bool, a) -> (Maybe a, Maybe a)
unbraid Nothing = (Nothing, Nothing)
unbraid (Just (first, x)) = if first then (Just x, Nothing) else (Nothing, Just x)

fontRom
    :: (HiddenClockResetEnable dom)
    => DSignal dom n (Unsigned 7)
    -> DSignal dom n (Index FontHeight)
    -> DSignal dom (n + 1) (Unsigned 8) -- (Unsigned FontWidth)
fontRom char row = delayedRom (fmap unpack . romFilePow2 "chargen.uf6.bin") $
    toAddr <$> char <*> row
  where
    toAddr :: Unsigned 7 -> Index 8 -> Unsigned (7 + CLog 2 FontHeight)
    toAddr char row = bitCoerce (char, row)
