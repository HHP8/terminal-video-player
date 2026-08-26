use std::env;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::error::AppError;
#[cfg(windows)]
use crate::platform::windows::configure_hidden;

const FFMPEG_ARTIFACT_MANIFEST: &str = include_str!("../../third-party/ffmpeg-artifact.json");

#[derive(Debug, Deserialize)]
struct FfmpegArtifactManifest {
    ffmpeg: FfmpegIdentity,
    build: FfmpegBuildPolicy,
}

#[derive(Debug, Deserialize)]
struct FfmpegIdentity {
    version: String,
    rejected_flags: Vec<String>,
    rejected_configuration_terms: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct FfmpegBuildPolicy {
    configuration_flags: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct FfmpegPaths {
    pub directory: PathBuf,
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
}

impl FfmpegPaths {
    pub fn resolve(explicit: Option<&Path>) -> Result<Self> {
        let directory = if let Some(explicit) = explicit {
            explicit.to_path_buf()
        } else if let Some(development) = env::var_os("TERMINAL_VIDEO_PLAYER_FFMPEG_DIR") {
            PathBuf::from(development)
        } else {
            let executable =
                env::current_exe().context("resolving the application executable path")?;
            executable
                .parent()
                .context("application executable has no parent directory")?
                .join("tools")
                .join("ffmpeg")
        };
        let ffmpeg = directory.join("ffmpeg.exe");
        let ffprobe = directory.join("ffprobe.exe");
        if !ffmpeg.is_file() || !ffprobe.is_file() {
            return Err(AppError::FfmpegMissing {
                searched: directory,
            }
            .into());
        }
        Ok(Self {
            directory,
            ffmpeg,
            ffprobe,
        })
    }

    pub fn version(&self) -> Result<String> {
        let output = tool_output(&self.ffmpeg, "-version").context("running ffmpeg -version")?;
        if !output.status.success() {
            anyhow::bail!("ffmpeg -version exited with {}", output.status);
        }
        Ok(String::from_utf8_lossy(&output.stdout)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned())
    }

    pub fn validate_runtime(&self) -> Result<()> {
        let ffmpeg_version =
            tool_output(&self.ffmpeg, "-version").context("validating ffmpeg.exe")?;
        let ffprobe_version =
            tool_output(&self.ffprobe, "-version").context("validating ffprobe.exe")?;
        let build = tool_output(&self.ffmpeg, "-buildconf")
            .context("reading FFmpeg build configuration")?;
        for (name, output) in [
            ("ffmpeg.exe", &ffmpeg_version),
            ("ffprobe.exe", &ffprobe_version),
            ("ffmpeg.exe -buildconf", &build),
        ] {
            if !output.status.success() {
                anyhow::bail!(
                    "{name} exited with {} during runtime validation",
                    output.status
                );
            }
        }
        let ffmpeg_text = String::from_utf8_lossy(&ffmpeg_version.stdout);
        let ffprobe_text = String::from_utf8_lossy(&ffprobe_version.stdout);
        let manifest: FfmpegArtifactManifest = serde_json::from_str(FFMPEG_ARTIFACT_MANIFEST)
            .context("parsing embedded FFmpeg artifact manifest")?;
        let expected_version = format!("ffmpeg version {}", manifest.ffmpeg.version);
        if !ffmpeg_text.contains(&expected_version) || !ffprobe_text.contains(&expected_version)
        {
            anyhow::bail!(
                "FFmpeg version mismatch; expected {}. Install the supported build or pass the matching --ffmpeg-dir",
                manifest.ffmpeg.version
            );
        }
        let mut build_text = String::from_utf8_lossy(&build.stdout).into_owned();
        build_text.push_str(&String::from_utf8_lossy(&build.stderr));
        let mut rejected = manifest.ffmpeg.rejected_flags;
        rejected.extend(manifest.ffmpeg.rejected_configuration_terms);
        validate_build_configuration(
            &build_text,
            &manifest.build.configuration_flags,
            &rejected,
        )
    }
}

fn tool_output(executable: &Path, argument: &str) -> Result<std::process::Output> {
    let mut command = Command::new(executable);
    command
        .arg(argument)
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .stdout(Stdio::piped());
    #[cfg(windows)]
    configure_hidden(&mut command);
    command.output().map_err(Into::into)
}

fn validate_build_configuration(
    configuration: &str,
    expected_flags: &[String],
    rejected_flags: &[String],
) -> Result<()> {
    let normalized = configuration.to_ascii_lowercase();
    for required in expected_flags {
        if !normalized.contains(required) {
            anyhow::bail!("FFmpeg is missing required build flag {required}");
        }
    }
    for rejected in rejected_flags {
        if normalized.contains(rejected) {
            anyhow::bail!("FFmpeg contains rejected build flag {rejected}");
        }
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct ProbeInfo {
    pub width: u32,
    pub height: u32,
    pub frame_rate: f64,
    pub duration: Option<Duration>,
    pub has_audio: bool,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RawProbe {
    #[serde(default)]
    streams: Vec<RawStream>,
    #[serde(default)]
    format: RawFormat,
}

#[derive(Debug, Deserialize)]
struct RawStream {
    codec_type: Option<String>,
    codec_name: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
    avg_frame_rate: Option<String>,
    r_frame_rate: Option<String>,
    duration: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawFormat {
    duration: Option<String>,
}

pub fn probe(paths: &FfmpegPaths, path: &Path) -> Result<ProbeInfo> {
    let mut command = build_probe_command(paths, path);
    let output = command.output().with_context(|| {
        format!(
            "starting ffprobe for {}. Install the supported FFmpeg build or verify --ffmpeg-dir",
            path.display()
        )
    })?;
    if !output.status.success() {
        return Err(AppError::ProbeFailed {
            path: path.to_path_buf(),
            details: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        }
        .into());
    }

    parse_probe_json(&output.stdout, path)
}

fn build_probe_command(paths: &FfmpegPaths, path: &Path) -> Command {
    let mut command = Command::new(&paths.ffprobe);
    command
        .arg("-v")
        .arg("error")
        .arg("-show_entries")
        .arg("stream=index,codec_name,codec_type,width,height,avg_frame_rate,r_frame_rate,start_time,duration:format=duration,start_time")
        .arg("-of")
        .arg("json")
        .arg("-protocol_whitelist")
        .arg("file,pipe")
        .arg("-i")
        .arg(path)
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .stdout(Stdio::piped());
    #[cfg(windows)]
    configure_hidden(&mut command);
    command
}

fn parse_probe_json(json: &[u8], path: &Path) -> Result<ProbeInfo> {
    let raw: RawProbe = serde_json::from_slice(json)
        .with_context(|| format!("parsing ffprobe JSON for {}", path.display()))?;
    let video = raw
        .streams
        .iter()
        .find(|stream| stream.codec_type.as_deref() == Some("video"))
        .ok_or_else(|| AppError::NoVideo(path.to_path_buf()))?;
    let audio = raw
        .streams
        .iter()
        .find(|stream| stream.codec_type.as_deref() == Some("audio"));
    let frame_rate = video
        .avg_frame_rate
        .as_deref()
        .and_then(parse_frame_rate)
        .filter(|rate| *rate > 0.0)
        .or_else(|| {
            video
                .r_frame_rate
                .as_deref()
                .and_then(parse_frame_rate)
                .filter(|rate| *rate > 0.0)
        })
        .unwrap_or(30.0);
    let duration = raw
        .format
        .duration
        .as_deref()
        .or(video.duration.as_deref())
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
        .map(Duration::from_secs_f64);

    Ok(ProbeInfo {
        width: video.width.unwrap_or_default(),
        height: video.height.unwrap_or_default(),
        frame_rate,
        duration,
        has_audio: audio.is_some(),
        video_codec: video.codec_name.clone(),
        audio_codec: audio.and_then(|stream| stream.codec_name.clone()),
    })
}

pub fn parse_frame_rate(value: &str) -> Option<f64> {
    let (numerator, denominator) = value.split_once('/')?;
    let numerator: f64 = numerator.parse().ok()?;
    let denominator: f64 = denominator.parse().ok()?;
    if denominator == 0.0 {
        return None;
    }
    let rate = numerator / denominator;
    rate.is_finite().then_some(rate)
}

pub fn bounded_dimensions(width: u32, height: u32, max_width: u32, max_height: u32) -> (u32, u32) {
    if width == 0 || height == 0 || max_width == 0 || max_height == 0 {
        return (0, 0);
    }
    let scale = (max_width as f64 / width as f64)
        .min(max_height as f64 / height as f64)
        .min(1.0);
    let output_width = (width as f64 * scale).round().max(1.0) as u32;
    let output_height = (height as f64 * scale).round().max(1.0) as u32;
    (output_width, output_height)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::*;

    #[test]
    fn parses_fractional_frame_rates() {
        let rate = parse_frame_rate("30000/1001").expect("valid rate");
        assert!((rate - 29.970_029_97).abs() < 0.000_001);
        assert_eq!(parse_frame_rate("0/0"), None);
    }

    #[test]
    fn bounds_landscape_and_portrait_frames() {
        assert_eq!(bounded_dimensions(1920, 1080, 640, 360), (640, 360));
        assert_eq!(bounded_dimensions(3840, 2160, 640, 360), (640, 360));
        assert_eq!(bounded_dimensions(1080, 1920, 640, 360), (203, 360));
    }

    #[test]
    fn parses_minimal_probe_json() {
        let info = parse_probe_json(
            br#"{
                "streams": [
                    {"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001"},
                    {"codec_type":"audio","codec_name":"aac"}
                ],
                "format":{"duration":"10.5"}
            }"#,
            Path::new("movie.mp4"),
        )
        .expect("probe");
        assert_eq!(info.width, 1920);
        assert!(info.has_audio);
        assert_eq!(info.duration, Some(Duration::from_secs_f64(10.5)));
    }

    #[test]
    fn validates_expected_license_flags() {
        let manifest: FfmpegArtifactManifest =
            serde_json::from_str(FFMPEG_ARTIFACT_MANIFEST).expect("embedded manifest");
        let valid_configuration = manifest.build.configuration_flags.join(" ");
        let mut rejected = manifest.ffmpeg.rejected_flags.clone();
        rejected.extend(manifest.ffmpeg.rejected_configuration_terms.clone());
        validate_build_configuration(
            &valid_configuration,
            &manifest.build.configuration_flags,
            &rejected,
        )
        .expect("valid minimal LGPL configuration");
        assert!(
            validate_build_configuration(
                &format!("{valid_configuration} --enable-gpl"),
                &manifest.build.configuration_flags,
                &rejected,
            )
            .is_err()
        );
        let incomplete_configuration = valid_configuration.replace("--enable-static", "");
        assert!(
            validate_build_configuration(
                &incomplete_configuration,
                &manifest.build.configuration_flags,
                &rejected,
            )
            .is_err()
        );
    }

    #[test]
    fn probe_command_restricts_nested_input_protocols_and_binds_the_input() {
        let directory = Path::new("C:\\ffmpeg");
        let paths = FfmpegPaths {
            directory: directory.to_path_buf(),
            ffmpeg: directory.join("ffmpeg.exe"),
            ffprobe: directory.join("ffprobe.exe"),
        };
        let path = Path::new("-playlist.m3u8");
        let command = build_probe_command(&paths, path);
        let arguments = command.get_args().map(OsString::from).collect::<Vec<_>>();
        let expected = [
            OsString::from("-protocol_whitelist"),
            OsString::from("file,pipe"),
            OsString::from("-i"),
            OsString::from(path),
        ];
        assert!(
            arguments
                .windows(expected.len())
                .any(|window| window == expected),
            "probe input is missing the local-only policy or explicit binding: {arguments:?}"
        );
    }
}
