use std::fs::File;
use std::time::Duration;

use image::codecs::gif::{GifEncoder, Repeat};
use image::{Delay, Frame, Rgb, RgbImage, Rgba, RgbaImage};
use terminal_video_player::media::{ImageSource, load_image_source};
use terminal_video_player::render::{
    AnsiRenderer, ColorCapability, DisplayMode, RenderStrategy, RgbFrame, sample_cells_with_mode,
};

fn exercise_all_modes(frame: &RgbFrame) {
    assert_eq!(DisplayMode::ALL.len(), 5);
    for mode in DisplayMode::ALL {
        let grid = sample_cells_with_mode(frame, 8, 4, 2.0, mode);
        assert!(!grid.cells.is_empty(), "{mode:?}");
        if mode == DisplayMode::HalfBlock {
            assert!(
                grid.cells
                    .iter()
                    .all(|cell| cell.glyph.as_char() == '▀' && cell.background.is_some())
            );
        } else {
            assert!(grid.cells.iter().all(|cell| cell.background.is_none()));
        }

        let encoded =
            AnsiRenderer::new(RenderStrategy::Adaptive, ColorCapability::Truecolor).encode(&grid);
        assert!(encoded.ends_with(b"\x1b[0m"), "{mode:?}");
        if mode == DisplayMode::HalfBlock {
            let text = String::from_utf8(encoded).expect("half-block output is UTF-8");
            assert!(text.contains("\x1b[38;2;"));
            assert!(text.contains("\x1b[48;2;"));
            assert!(text.contains('▀'));
        }
    }
}

#[test]
fn representative_unicode_path_still_renders_in_all_five_modes() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let directory = temporary
        .path()
        .join("\u{62a}\u{635}\u{627}\u{648}\u{6cc}\u{631} \u{631}\u{646}\u{6af}\u{6cc} \u{1f3a8}");
    std::fs::create_dir(&directory).expect("create Unicode directory");
    let path = directory.join(
        "\u{646}\u{645}\u{648}\u{646}\u{647} \u{646}\u{6cc}\u{645} \u{628}\u{644}\u{648}\u{6a9}.png",
    );

    let mut image = RgbImage::new(4, 4);
    for (x, y, pixel) in image.enumerate_pixels_mut() {
        *pixel = Rgb([(x * 60) as u8, (y * 70) as u8, ((x + y) * 30) as u8]);
    }
    image.save(&path).expect("save still fixture");

    let ImageSource::Still(frame) = load_image_source(&path).expect("load still fixture") else {
        panic!("PNG was classified as GIF");
    };
    exercise_all_modes(&frame);
}

#[test]
fn representative_timed_gif_preserves_delays_and_renders_in_all_five_modes() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let directory = temporary
        .path()
        .join("\u{67e}\u{648}\u{6cc}\u{627}\u{646}\u{645}\u{627}\u{6cc}\u{6cc} \u{1f39e}\u{fe0f}");
    std::fs::create_dir(&directory).expect("create Unicode directory");
    let path = directory.join(
        "\u{646}\u{645}\u{648}\u{646}\u{647} \u{632}\u{645}\u{627}\u{646} \u{628}\u{646}\u{62f}\u{6cc}.gif",
    );
    let file = File::create(&path).expect("create GIF");
    let mut encoder = GifEncoder::new(file);
    encoder
        .set_repeat(Repeat::Finite(1))
        .expect("set GIF repeat");

    let mut first = RgbaImage::new(4, 4);
    for (x, y, pixel) in first.enumerate_pixels_mut() {
        *pixel = Rgba([(x * 60) as u8, 0, (y * 70) as u8, 255]);
    }
    encoder
        .encode_frame(Frame::from_parts(
            first,
            0,
            0,
            Delay::from_numer_denom_ms(50, 1),
        ))
        .expect("encode first GIF frame");

    let mut second = RgbaImage::new(4, 4);
    for (x, y, pixel) in second.enumerate_pixels_mut() {
        *pixel = Rgba([0, (x * 60) as u8, (y * 70) as u8, 255]);
    }
    encoder
        .encode_frame(Frame::from_parts(
            second,
            0,
            0,
            Delay::from_numer_denom_ms(200, 1),
        ))
        .expect("encode second GIF frame");
    drop(encoder);

    let ImageSource::Gif(frames) = load_image_source(&path).expect("load GIF fixture") else {
        panic!("GIF was classified as still");
    };
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0].delay, Duration::from_millis(50));
    assert_eq!(frames[1].delay, Duration::from_millis(200));
    for frame in &frames {
        exercise_all_modes(&frame.frame);
    }
}
