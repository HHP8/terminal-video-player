use crate::cli::DisplayModeChoice;

pub const DEFAULT_RAMP: &str = " .:-=+*#%@";
pub const CLASSIC_ASCII_RAMP: &str = " .:-=+*#%@";
// Adapted from tplay's CHARS3 ramp under the MIT License. See THIRD-PARTY-NOTICES.md.
pub const DETAILED_ASCII_RAMP: &str =
    " .-':_,^=;><+!rc*/z?sLTv)J7(|Fi{C}fI31tlu[neoZ5Yxjya]2ESwqkP6h9d4VpOGbUAKXHm8RD#$Bg0MNWQ%&@";
pub const GRADIENT_RAMP: &str = " ░▒▓█";

const GRADIENT_GLYPHS: &[char] = &[' ', '░', '▒', '▓', '█'];
const LIGHT_SHADE: u8 = 0x80;
const MEDIUM_SHADE: u8 = 0x81;
const DARK_SHADE: u8 = 0x82;
const FULL_BLOCK: u8 = 0x83;
const UPPER_HALF_BLOCK: u8 = 0x84;
const LOWER_HALF_BLOCK: u8 = 0x85;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
#[repr(transparent)]
pub struct Glyph(u8);

impl Glyph {
    pub const fn ascii(value: u8) -> Self {
        Self(value)
    }

    pub fn as_char(self) -> char {
        match self.0 {
            LIGHT_SHADE => '░',
            MEDIUM_SHADE => '▒',
            DARK_SHADE => '▓',
            FULL_BLOCK => '█',
            UPPER_HALF_BLOCK => '▀',
            LOWER_HALF_BLOCK => '▄',
            value => char::from(value),
        }
    }

    pub fn write_utf8(self, output: &mut Vec<u8>) {
        if self.0.is_ascii() {
            output.push(self.0);
        } else {
            let mut utf8 = [0_u8; 4];
            output.extend_from_slice(self.as_char().encode_utf8(&mut utf8).as_bytes());
        }
    }

    pub const fn full_block() -> Self {
        Self(FULL_BLOCK)
    }

    pub const fn upper_half_block() -> Self {
        Self(UPPER_HALF_BLOCK)
    }

    pub const fn lower_half_block() -> Self {
        Self(LOWER_HALF_BLOCK)
    }
}

impl std::fmt::Debug for Glyph {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.as_char().fmt(formatter)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DisplayMode {
    Default,
    ClassicAscii,
    DetailedAscii,
    Gradient,
    HalfBlock,
}

impl DisplayMode {
    pub const ALL: [Self; 5] = [
        Self::Default,
        Self::ClassicAscii,
        Self::DetailedAscii,
        Self::Gradient,
        Self::HalfBlock,
    ];

    pub const CHARACTER_MODES: [Self; 4] = [
        Self::Default,
        Self::ClassicAscii,
        Self::DetailedAscii,
        Self::Gradient,
    ];

    pub const fn label(self) -> &'static str {
        match self {
            Self::Default => "Default",
            Self::ClassicAscii => "Classic ASCII",
            Self::DetailedAscii => "Detailed ASCII",
            Self::Gradient => "Gradient",
            Self::HalfBlock => "Colored Half-Block",
        }
    }

    pub const fn ramp(self) -> &'static str {
        match self {
            Self::Default => DEFAULT_RAMP,
            Self::ClassicAscii => CLASSIC_ASCII_RAMP,
            Self::DetailedAscii => DETAILED_ASCII_RAMP,
            Self::Gradient => GRADIENT_RAMP,
            Self::HalfBlock => "▀",
        }
    }

    pub fn glyph_for_luma(self, luma: u8) -> Glyph {
        if self == Self::Gradient {
            return [
                Glyph::ascii(b' '),
                Glyph(LIGHT_SHADE),
                Glyph(MEDIUM_SHADE),
                Glyph(DARK_SHADE),
                Glyph(FULL_BLOCK),
            ][ramp_index(luma, GRADIENT_GLYPHS.len())];
        }
        if self == Self::HalfBlock {
            return Glyph::upper_half_block();
        }

        let ramp = self.ramp().as_bytes();
        debug_assert!(ramp.is_ascii());
        Glyph::ascii(ramp[ramp_index(luma, ramp.len())])
    }

    pub fn character_for_luma(self, luma: u8) -> char {
        self.glyph_for_luma(luma).as_char()
    }

    pub const fn from_menu_number(number: u8) -> Option<Self> {
        match number {
            1 => Some(Self::Default),
            2 => Some(Self::ClassicAscii),
            3 => Some(Self::DetailedAscii),
            4 => Some(Self::Gradient),
            5 => Some(Self::HalfBlock),
            _ => None,
        }
    }
}

impl From<DisplayModeChoice> for DisplayMode {
    fn from(value: DisplayModeChoice) -> Self {
        match value {
            DisplayModeChoice::Default => Self::Default,
            DisplayModeChoice::ClassicAscii => Self::ClassicAscii,
            DisplayModeChoice::DetailedAscii => Self::DetailedAscii,
            DisplayModeChoice::Gradient => Self::Gradient,
            DisplayModeChoice::HalfBlock => Self::HalfBlock,
        }
    }
}

pub fn bt709_luma(rgb: [u8; 3]) -> u8 {
    let weighted = u32::from(rgb[0]) * 2126 + u32::from(rgb[1]) * 7152 + u32::from(rgb[2]) * 722;
    (weighted / 10_000) as u8
}

fn ramp_index(luma: u8, ramp_len: usize) -> usize {
    debug_assert!(ramp_len > 0);
    usize::from(luma) * (ramp_len - 1) / 255
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;
    use unicode_width::UnicodeWidthChar;

    #[test]
    fn ramps_match_the_product_contract_exactly() {
        assert_eq!(DEFAULT_RAMP, " .:-=+*#%@");
        assert_eq!(CLASSIC_ASCII_RAMP, " .:-=+*#%@");
        assert_eq!(
            DETAILED_ASCII_RAMP,
            " .-':_,^=;><+!rc*/z?sLTv)J7(|Fi{C}fI31tlu[neoZ5Yxjya]2ESwqkP6h9d4VpOGbUAKXHm8RD#$Bg0MNWQ%&@"
        );
        assert_eq!(GRADIENT_RAMP, " ░▒▓█");
        assert_eq!(DETAILED_ASCII_RAMP.chars().count(), 91);
    }

    #[test]
    fn every_ramp_starts_with_one_space_and_uses_single_width_glyphs() {
        for mode in DisplayMode::CHARACTER_MODES {
            let glyphs: Vec<_> = mode.ramp().chars().collect();
            assert_eq!(glyphs.first(), Some(&' '), "{mode:?}");
            assert_ne!(glyphs.get(1), Some(&' '), "{mode:?}");
            for glyph in glyphs {
                assert!(!glyph.is_control(), "{mode:?} contains a control");
                assert_eq!(glyph.width(), Some(1), "{mode:?} {glyph:?}");
            }
        }
        assert_eq!(DisplayMode::HalfBlock.ramp(), "▀");
        assert_eq!(DisplayMode::HalfBlock.character_for_luma(0), '▀');
        assert_eq!(DisplayMode::HalfBlock.character_for_luma(255), '▀');
        assert_eq!('▀'.width(), Some(1));
        assert_eq!(Glyph::lower_half_block().as_char(), '▄');
        assert_eq!('▄'.width(), Some(1));
    }

    #[test]
    fn maps_dark_intermediate_and_bright_luminance_across_complete_ramps() {
        assert_eq!(DisplayMode::Default.character_for_luma(0), ' ');
        assert_eq!(DisplayMode::Default.character_for_luma(128), '=');
        assert_eq!(DisplayMode::Default.character_for_luma(255), '@');

        assert_eq!(DisplayMode::ClassicAscii.character_for_luma(0), ' ');
        assert_eq!(DisplayMode::ClassicAscii.character_for_luma(128), '=');
        assert_eq!(DisplayMode::ClassicAscii.character_for_luma(255), '@');

        assert_eq!(DisplayMode::DetailedAscii.character_for_luma(0), ' ');
        assert_eq!(DisplayMode::DetailedAscii.character_for_luma(128), 'Z');
        assert_eq!(DisplayMode::DetailedAscii.character_for_luma(255), '@');

        assert_eq!(DisplayMode::Gradient.character_for_luma(0), ' ');
        assert_eq!(DisplayMode::Gradient.character_for_luma(128), '▒');
        assert_eq!(DisplayMode::Gradient.character_for_luma(255), '█');

        assert_eq!(DisplayMode::HalfBlock.character_for_luma(0), '▀');
        assert_eq!(DisplayMode::HalfBlock.character_for_luma(128), '▀');
        assert_eq!(DisplayMode::HalfBlock.character_for_luma(255), '▀');
    }

    #[test]
    fn default_preserves_the_existing_threshold_boundaries() {
        for luma in 0..=28 {
            assert_eq!(DisplayMode::Default.character_for_luma(luma), ' ');
        }
        assert_eq!(DisplayMode::Default.character_for_luma(29), '.');
        assert_eq!(DisplayMode::Default.character_for_luma(254), '%');
        assert_eq!(DisplayMode::Default.character_for_luma(255), '@');
    }

    #[test]
    fn every_character_in_each_complete_ramp_is_reachable() {
        for mode in DisplayMode::CHARACTER_MODES {
            let expected = mode.ramp().chars().collect::<BTreeSet<_>>();
            let mapped = (0..=u8::MAX)
                .map(|luma| mode.character_for_luma(luma))
                .collect::<BTreeSet<_>>();
            assert_eq!(mapped, expected, "{mode:?}");
        }
    }

    #[test]
    fn bt709_luma_keeps_expected_endpoints() {
        assert_eq!(bt709_luma([0, 0, 0]), 0);
        assert_eq!(bt709_luma([255, 255, 255]), 255);
        assert_eq!(bt709_luma([255, 0, 0]), 54);
        assert_eq!(bt709_luma([0, 255, 0]), 182);
        assert_eq!(bt709_luma([0, 0, 255]), 18);
    }
}
