use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use image::codecs::gif::GifDecoder;
use image::{AnimationDecoder, ImageDecoder, Limits};

use crate::render::RgbFrame;

const MAX_GIF_WIDTH: u32 = 4_096;
const MAX_GIF_HEIGHT: u32 = 4_096;
const MAX_GIF_FRAMES: usize = 10_000;
const MAX_GIF_DECODED_BYTES: u64 = 256 * 1024 * 1024;
const MAX_GIF_DECODER_ALLOC: u64 = 256 * 1024 * 1024;
const MAX_STILL_WIDTH: u32 = 4_096;
const MAX_STILL_HEIGHT: u32 = 4_096;
const MAX_STILL_DECODER_ALLOC: u64 = 128 * 1024 * 1024;

#[derive(Clone, Copy, Debug)]
struct StillLimits {
    max_width: u32,
    max_height: u32,
    max_decoder_alloc: u64,
}

impl Default for StillLimits {
    fn default() -> Self {
        Self {
            max_width: MAX_STILL_WIDTH,
            max_height: MAX_STILL_HEIGHT,
            max_decoder_alloc: MAX_STILL_DECODER_ALLOC,
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct GifLimits {
    max_width: u32,
    max_height: u32,
    max_frames: usize,
    max_decoded_bytes: u64,
    max_decoder_alloc: u64,
}

impl Default for GifLimits {
    fn default() -> Self {
        Self {
            max_width: MAX_GIF_WIDTH,
            max_height: MAX_GIF_HEIGHT,
            max_frames: MAX_GIF_FRAMES,
            max_decoded_bytes: MAX_GIF_DECODED_BYTES,
            max_decoder_alloc: MAX_GIF_DECODER_ALLOC,
        }
    }
}

#[derive(Debug)]
pub struct GifFrame {
    pub frame: RgbFrame,
    pub delay: Duration,
}

#[derive(Debug)]
pub enum ImageSource {
    Still(RgbFrame),
    Gif(Vec<GifFrame>),
}

pub fn load_image_source(path: &Path) -> Result<ImageSource> {
    let reader = image::ImageReader::open(path)
        .with_context(|| format!("opening image {}", path.display()))?
        .with_guessed_format()
        .context("guessing image format")?;
    if reader.format() == Some(image::ImageFormat::Gif) {
        return load_gif(path);
    }

    load_still_with_limits(path, StillLimits::default())
}

fn load_still_with_limits(path: &Path, limits: StillLimits) -> Result<ImageSource> {
    let mut reader = image::ImageReader::open(path)
        .with_context(|| format!("opening image {}", path.display()))?
        .with_guessed_format()
        .context("guessing image format")?;
    let mut decoder_limits = Limits::default();
    decoder_limits.max_image_width = Some(limits.max_width);
    decoder_limits.max_image_height = Some(limits.max_height);
    decoder_limits.max_alloc = Some(limits.max_decoder_alloc);
    reader.limits(decoder_limits);

    let image = reader
        .decode()
        .with_context(|| format!("decoding image {}", path.display()))?
        .to_rgb8();
    Ok(ImageSource::Still(RgbFrame {
        generation: 0,
        index: 0,
        pts: Duration::ZERO,
        width: image.width(),
        height: image.height(),
        rgb: image.into_raw().into_boxed_slice(),
    }))
}

fn load_gif(path: &Path) -> Result<ImageSource> {
    load_gif_with_limits(path, GifLimits::default())
}

fn load_gif_with_limits(path: &Path, limits: GifLimits) -> Result<ImageSource> {
    let file = File::open(path).with_context(|| format!("opening GIF {}", path.display()))?;
    let mut decoder = GifDecoder::new(BufReader::new(file))
        .with_context(|| format!("decoding GIF header {}", path.display()))?;
    let mut decoder_limits = Limits::default();
    decoder_limits.max_image_width = Some(limits.max_width);
    decoder_limits.max_image_height = Some(limits.max_height);
    decoder_limits.max_alloc = Some(limits.max_decoder_alloc);
    decoder
        .set_limits(decoder_limits)
        .with_context(|| format!("applying GIF decode limits to {}", path.display()))?;

    let mut pts = Duration::ZERO;
    let mut frames = Vec::new();
    let mut decoded_bytes = 0_u64;
    for frame in decoder.into_frames() {
        let frame = frame.with_context(|| format!("decoding GIF frames {}", path.display()))?;
        if frames.len() == limits.max_frames {
            anyhow::bail!(
                "GIF exceeds the {}-frame safety limit: {}",
                limits.max_frames,
                path.display()
            );
        }
        let delay = delay_to_duration(frame.delay());
        let buffer = frame.into_buffer();
        let width = buffer.width();
        let height = buffer.height();
        let frame_bytes = u64::from(width)
            .checked_mul(u64::from(height))
            .and_then(|pixels| pixels.checked_mul(3))
            .context("GIF decoded frame size overflow")?;
        decoded_bytes = decoded_bytes
            .checked_add(frame_bytes)
            .context("GIF aggregate decoded size overflow")?;
        if decoded_bytes > limits.max_decoded_bytes {
            anyhow::bail!(
                "GIF exceeds the {}-byte decoded safety limit: {}",
                limits.max_decoded_bytes,
                path.display()
            );
        }
        let rgb = image::DynamicImage::ImageRgba8(buffer).to_rgb8();
        frames.push(GifFrame {
            frame: RgbFrame {
                generation: 0,
                index: frames.len() as u64,
                pts,
                width,
                height,
                rgb: rgb.into_raw().into_boxed_slice(),
            },
            delay,
        });
        pts += delay;
    }
    if frames.is_empty() {
        anyhow::bail!("GIF contains no frames: {}", path.display());
    }
    Ok(ImageSource::Gif(frames))
}

fn delay_to_duration(delay: image::Delay) -> Duration {
    let (numerator, denominator) = delay.numer_denom_ms();
    if denominator == 0 {
        return Duration::from_millis(100);
    }
    let seconds = f64::from(numerator) / f64::from(denominator) / 1_000.0;
    Duration::from_secs_f64(seconds.max(0.01))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::codecs::gif::{GifEncoder, Repeat};
    use image::{Delay, Frame, Rgba, RgbaImage};

    #[test]
    fn still_decode_rejects_dimensions_over_the_configured_limit() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("wide.png");
        RgbaImage::from_pixel(2, 1, Rgba([255, 0, 0, 255]))
            .save(&path)
            .expect("encode PNG");

        let limits = StillLimits {
            max_width: 1,
            ..StillLimits::default()
        };
        assert!(load_still_with_limits(&path, limits).is_err());
    }

    #[test]
    fn gif_preserves_per_frame_delays() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("timed.gif");
        let file = File::create(&path).expect("create GIF");
        let mut encoder = GifEncoder::new(file);
        encoder
            .set_repeat(Repeat::Infinite)
            .expect("set GIF repeat");
        encoder
            .encode_frame(Frame::from_parts(
                RgbaImage::from_pixel(2, 1, Rgba([255, 0, 0, 255])),
                0,
                0,
                Delay::from_numer_denom_ms(50, 1),
            ))
            .expect("encode first frame");
        encoder
            .encode_frame(Frame::from_parts(
                RgbaImage::from_pixel(2, 1, Rgba([0, 0, 255, 255])),
                0,
                0,
                Delay::from_numer_denom_ms(200, 1),
            ))
            .expect("encode second frame");
        drop(encoder);

        let ImageSource::Gif(frames) = load_image_source(&path).expect("decode timed GIF") else {
            panic!("GIF was classified as a still image");
        };
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].frame.pts, Duration::ZERO);
        assert_eq!(frames[0].delay, Duration::from_millis(50));
        assert_eq!(frames[1].frame.pts, Duration::from_millis(50));
        assert_eq!(frames[1].delay, Duration::from_millis(200));
    }

    #[test]
    fn gif_content_with_png_extension_uses_the_bounded_gif_decoder() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("disguised.png");
        write_test_gif(&path, 1, 1, 2);

        let ImageSource::Gif(frames) =
            load_image_source(&path).expect("decode extension-mismatched GIF")
        else {
            panic!("GIF content bypassed the bounded GIF decoder");
        };
        assert_eq!(frames.len(), 2);
    }

    fn write_test_gif(path: &Path, width: u32, height: u32, frame_count: usize) {
        let file = File::create(path).expect("create GIF");
        let mut encoder = GifEncoder::new(file);
        for index in 0..frame_count {
            encoder
                .encode_frame(Frame::from_parts(
                    RgbaImage::from_pixel(width, height, Rgba([index as u8, 0, 0, 255])),
                    0,
                    0,
                    Delay::from_numer_denom_ms(10, 1),
                ))
                .expect("encode GIF frame");
        }
    }

    #[test]
    fn gif_decode_rejects_dimensions_over_the_configured_limit() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("wide.gif");
        write_test_gif(&path, 2, 1, 1);

        let limits = GifLimits {
            max_width: 1,
            ..GifLimits::default()
        };
        assert!(load_gif_with_limits(&path, limits).is_err());
    }

    #[test]
    fn gif_decode_rejects_excessive_frame_count_before_retaining_it() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("many-frames.gif");
        write_test_gif(&path, 1, 1, 3);

        let limits = GifLimits {
            max_frames: 2,
            ..GifLimits::default()
        };
        assert!(load_gif_with_limits(&path, limits).is_err());
    }

    #[test]
    fn gif_decode_rejects_excessive_aggregate_decoded_bytes() {
        let temporary = tempfile::tempdir().expect("temporary directory");
        let path = temporary.path().join("aggregate.gif");
        write_test_gif(&path, 2, 2, 2);

        let limits = GifLimits {
            max_decoded_bytes: 20,
            ..GifLimits::default()
        };
        assert!(load_gif_with_limits(&path, limits).is_err());
    }
}
