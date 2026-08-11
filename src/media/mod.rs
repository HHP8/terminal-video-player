mod ffmpeg_process;
mod image_source;
mod probe;

pub use ffmpeg_process::{
    AudioPipe, DecoderErrorTail, ProcessWorker, VideoEvent, VideoPipe, build_audio_command,
    build_video_command, read_exact_frame, spawn_audio, spawn_video,
};
pub use image_source::{GifFrame, ImageSource, load_image_source};
pub use probe::{FfmpegPaths, ProbeInfo, bounded_dimensions, parse_frame_rate, probe};

use std::path::Path;

pub fn is_probably_image(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("png" | "jpg" | "jpeg" | "gif")
    )
}
