use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result};
use image::AnimationDecoder;
use image::codecs::gif::GifDecoder;

use crate::render::RgbFrame;

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
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if extension == "gif" {
        return load_gif(path);
    }

    let image = image::ImageReader::open(path)
        .with_context(|| format!("opening image {}", path.display()))?
        .with_guessed_format()
        .context("guessing image format")?
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
    let file = File::open(path).with_context(|| format!("opening GIF {}", path.display()))?;
    let decoder = GifDecoder::new(BufReader::new(file))
        .with_context(|| format!("decoding GIF header {}", path.display()))?;
    let decoded = decoder
        .into_frames()
        .collect_frames()
        .with_context(|| format!("decoding GIF frames {}", path.display()))?;
    let mut pts = Duration::ZERO;
    let mut frames = Vec::with_capacity(decoded.len());
    for (index, frame) in decoded.into_iter().enumerate() {
        let delay = delay_to_duration(frame.delay());
        let buffer = frame.into_buffer();
        let width = buffer.width();
        let height = buffer.height();
        let rgb = image::DynamicImage::ImageRgba8(buffer).to_rgb8();
        frames.push(GifFrame {
            frame: RgbFrame {
                generation: 0,
                index: index as u64,
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
}
