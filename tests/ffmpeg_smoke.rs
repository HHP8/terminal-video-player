use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use terminal_video_player::audio::{AUDIO_CHANNELS, AUDIO_SAMPLE_RATE};
use terminal_video_player::media::{FfmpegPaths, VideoEvent, probe, spawn_audio, spawn_video};
use terminal_video_player::platform::windows::Job;

static FFMPEG_TEST_LOCK: Mutex<()> = Mutex::new(());

fn serialize_ffmpeg_test() -> MutexGuard<'static, ()> {
    FFMPEG_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[test]
#[ignore = "requires pinned FFmpeg and TERMINAL_VIDEO_PLAYER_TEST_MEDIA"]
fn decodes_unicode_path_through_bounded_video_and_audio_workers() {
    let _serial = serialize_ffmpeg_test();
    let source_media = std::env::var_os("TERMINAL_VIDEO_PLAYER_TEST_MEDIA")
        .map(PathBuf::from)
        .expect("set TERMINAL_VIDEO_PLAYER_TEST_MEDIA");
    let temporary = tempfile::tempdir().expect("create temporary media directory");
    let unicode_directory = temporary.path().join(
        "\u{631}\u{633}\u{627}\u{646}\u{647} \u{647}\u{627}\u{6cc} \u{645}\u{646} \u{1f39e}\u{fe0f}",
    );
    std::fs::create_dir(&unicode_directory).expect("create Unicode media directory");
    let media = unicode_directory
        .join("\u{646}\u{645}\u{648}\u{646}\u{647} \u{641}\u{6cc}\u{644}\u{645} 1080p.mp4");
    std::fs::copy(&source_media, &media).expect("copy fixture to Unicode media path");
    let ffmpeg = FfmpegPaths::resolve(None).expect("resolve pinned FFmpeg");
    ffmpeg.validate_runtime().expect("validate pinned FFmpeg");
    let info = probe(&ffmpeg, &media).expect("probe Unicode-path media");
    assert!(info.has_audio);

    let cancelled = Arc::new(AtomicBool::new(false));
    let mut job = Job::new().expect("create Job Object");
    let (video, mut video_worker) = spawn_video(
        &ffmpeg,
        &media,
        Duration::ZERO,
        30.0,
        160,
        90,
        7,
        &job,
        Arc::clone(&cancelled),
    )
    .expect("spawn video worker");
    let (audio, mut audio_worker) = spawn_audio(
        &ffmpeg,
        &media,
        Duration::ZERO,
        AUDIO_SAMPLE_RATE,
        AUDIO_CHANNELS,
        &job,
        Arc::clone(&cancelled),
    )
    .expect("spawn audio worker");

    let mut decoded = 0;
    while decoded < 5 {
        match video
            .events
            .recv_timeout(Duration::from_secs(5))
            .expect("receive video event")
        {
            VideoEvent::Frame(frame) => {
                assert_eq!(frame.generation, 7);
                assert_eq!((frame.width, frame.height), (160, 90));
                assert!(frame.validate());
                decoded += 1;
            }
            VideoEvent::End => panic!("video ended before five frames"),
            VideoEvent::Error(error) => panic!("video decoder error: {error}"),
        }
    }
    let pcm = audio
        .samples
        .recv_timeout(Duration::from_secs(5))
        .expect("receive PCM chunk");
    assert!(!pcm.is_empty());
    assert_eq!(pcm.len() % usize::from(AUDIO_CHANNELS), 0);

    cancelled.store(true, Ordering::Release);
    job.terminate();
    video_worker.join();
    audio_worker.join();
}

#[test]
#[ignore = "requires pinned FFmpeg and TERMINAL_VIDEO_PLAYER_TEST_MEDIA"]
fn full_video_queue_can_still_be_cancelled_and_joined() {
    let _serial = serialize_ffmpeg_test();
    let media = std::env::var_os("TERMINAL_VIDEO_PLAYER_TEST_MEDIA")
        .map(PathBuf::from)
        .expect("set TERMINAL_VIDEO_PLAYER_TEST_MEDIA");
    let ffmpeg = FfmpegPaths::resolve(None).expect("resolve pinned FFmpeg");
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut job = Job::new().expect("create Job Object");
    let (video, mut worker) = spawn_video(
        &ffmpeg,
        &media,
        Duration::ZERO,
        30.0,
        160,
        90,
        9,
        &job,
        Arc::clone(&cancelled),
    )
    .expect("spawn video worker");

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while video.events.len() < 2 && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(video.events.len(), 2, "bounded channel should fill");
    cancelled.store(true, Ordering::Release);
    job.terminate();
    worker.join();
}

#[test]
#[ignore = "requires pinned FFmpeg and 1080p TERMINAL_VIDEO_PLAYER_TEST_MEDIA"]
fn decodes_1080p_rgb_pipe_faster_than_real_time() {
    let _serial = serialize_ffmpeg_test();
    let media = std::env::var_os("TERMINAL_VIDEO_PLAYER_TEST_MEDIA")
        .map(PathBuf::from)
        .expect("set TERMINAL_VIDEO_PLAYER_TEST_MEDIA");
    let ffmpeg = FfmpegPaths::resolve(None).expect("resolve pinned FFmpeg");
    let info = probe(&ffmpeg, &media).expect("probe 1080p media");
    assert!(info.width >= 1920 && info.height >= 1080);
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut job = Job::new().expect("create Job Object");
    let (video, mut worker) = spawn_video(
        &ffmpeg,
        &media,
        Duration::ZERO,
        30.0,
        640,
        360,
        11,
        &job,
        Arc::clone(&cancelled),
    )
    .expect("spawn video worker");

    let started = std::time::Instant::now();
    let mut frames = 0_u64;
    loop {
        match video
            .events
            .recv_timeout(Duration::from_secs(10))
            .expect("receive complete video stream")
        {
            VideoEvent::Frame(frame) => {
                assert!(frame.validate());
                frames += 1;
            }
            VideoEvent::End => break,
            VideoEvent::Error(error) => panic!("video decoder error: {error}"),
        }
    }
    let elapsed = started.elapsed();
    job.terminate();
    worker.join();
    eprintln!("decoded {frames} 640x360 RGB24 frames in {elapsed:?}");

    assert!(
        frames >= 290,
        "expected approximately 300 frames, got {frames}"
    );
    assert!(
        elapsed < Duration::from_secs(10),
        "10-second fixture decoded in {elapsed:?}"
    );
}
