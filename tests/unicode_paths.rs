use std::path::Path;

use image::{Rgb, RgbImage};
use terminal_video_player::media::{ImageSource, load_image_source};

#[test]
fn opens_an_image_from_a_runtime_constructed_unicode_path() {
    let temporary = tempfile::tempdir().expect("temporary directory");
    let nested = temporary.path().join(
        "\u{631}\u{633}\u{627}\u{646}\u{647} \u{647}\u{627}\u{6cc} \u{645}\u{646} \u{1f39e}\u{fe0f}",
    );
    std::fs::create_dir(&nested).expect("create Unicode directory");
    let path =
        nested.join("\u{646}\u{645}\u{648}\u{646}\u{647} \u{62a}\u{635}\u{648}\u{6cc}\u{631}.png");
    RgbImage::from_pixel(2, 2, Rgb([25, 100, 200]))
        .save(&path)
        .expect("save Unicode-path fixture");

    let decoded = load_image_source(&path).expect("decode Unicode-path image");
    match decoded {
        ImageSource::Still(frame) => {
            assert_eq!((frame.width, frame.height), (2, 2));
            assert!(frame.validate());
        }
        ImageSource::Gif(_) => panic!("PNG was classified as GIF"),
    }
}

#[test]
fn path_components_are_not_lossily_normalized() {
    let directory_name = "\u{648}\u{6cc}\u{62f}\u{6cc}\u{648} \u{647}\u{627}\u{6cc} \u{645}\u{646}";
    let file_name = "\u{646}\u{645}\u{648}\u{646}\u{647} \u{641}\u{6cc}\u{644}\u{645}.mp4";
    let path = Path::new("C:\\").join(directory_name).join(file_name);
    assert_eq!(
        path.file_name().and_then(|value| value.to_str()),
        Some(file_name)
    );
}
