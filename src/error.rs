use std::path::PathBuf;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error(
        "bundled FFmpeg tools were not found under {searched}. Reinstall the package or pass --ffmpeg-dir <DIR>"
    )]
    FfmpegMissing { searched: PathBuf },

    #[error("ffprobe could not inspect {path}: {details}")]
    ProbeFailed { path: PathBuf, details: String },

    #[error("media has no decodable video stream: {0}")]
    NoVideo(PathBuf),

    #[error("unsupported image format: {0}")]
    UnsupportedImage(PathBuf),

    #[error("audio output is unavailable: {0}")]
    AudioUnavailable(String),
}
