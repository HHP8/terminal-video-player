use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::Result;

use super::{InputEvent, TerminalSession, poll_event};
use crate::render::DisplayMode;

const MENU_POLL: Duration = Duration::from_millis(50);
const INVALID_MESSAGE: &str = "Invalid selection. Press 1, 2, 3, 4, or 5.";
const CLEAR_SCREEN: &[u8] = b"\x1b[0m\x1b[2J\x1b[H";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayModePolicy {
    Use(DisplayMode),
    Prompt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuOutcome {
    Selected(DisplayMode),
    Cancelled,
}

pub fn selection_policy(
    explicit: Option<DisplayMode>,
    is_video: bool,
    stdin_is_terminal: bool,
) -> DisplayModePolicy {
    if let Some(mode) = explicit {
        DisplayModePolicy::Use(mode)
    } else if is_video && stdin_is_terminal {
        DisplayModePolicy::Prompt
    } else {
        DisplayModePolicy::Use(DisplayMode::Default)
    }
}

pub trait DisplayModeMenu {
    fn size(&self) -> Result<(u16, u16)>;
    fn write(&mut self, bytes: &[u8]) -> Result<()>;
    fn poll(&mut self, timeout: Duration) -> Result<InputEvent>;
}

impl DisplayModeMenu for TerminalSession {
    fn size(&self) -> Result<(u16, u16)> {
        TerminalSession::size(self)
    }

    fn write(&mut self, bytes: &[u8]) -> Result<()> {
        self.write_frame(bytes)
    }

    fn poll(&mut self, timeout: Duration) -> Result<InputEvent> {
        poll_event(timeout)
    }
}

pub fn select_display_mode<T: DisplayModeMenu>(
    terminal: &mut T,
    cancelled: &AtomicBool,
) -> Result<MenuOutcome> {
    let mut invalid = false;
    let mut dirty = true;

    loop {
        if cancelled.load(Ordering::Relaxed) {
            return Ok(MenuOutcome::Cancelled);
        }
        if dirty {
            let (columns, rows) = terminal.size()?;
            terminal.write(&menu_bytes(columns, rows, invalid))?;
            dirty = false;
        }

        match terminal.poll(MENU_POLL)? {
            InputEvent::None => {}
            InputEvent::Quit => return Ok(MenuOutcome::Cancelled),
            InputEvent::Confirm => {
                terminal.write(CLEAR_SCREEN)?;
                return Ok(MenuOutcome::Selected(DisplayMode::Default));
            }
            InputEvent::SelectDisplayMode(number) => {
                if let Some(mode) = DisplayMode::from_menu_number(number) {
                    terminal.write(CLEAR_SCREEN)?;
                    return Ok(MenuOutcome::Selected(mode));
                }
                invalid = true;
                dirty = true;
            }
            InputEvent::Resize(_, _) => {
                dirty = true;
            }
            InputEvent::InvalidSelection
            | InputEvent::TogglePause
            | InputEvent::ToggleMute
            | InputEvent::SeekRelative(_) => {
                invalid = true;
                dirty = true;
            }
        }
    }
}

fn menu_bytes(columns: u16, rows: u16, invalid: bool) -> Vec<u8> {
    let mut output = CLEAR_SCREEN.to_vec();
    let options = [
        "1. Default",
        "2. Classic ASCII",
        "3. Detailed ASCII",
        "4. Gradient",
        "5. Colored Half-Block",
    ];
    let instruction = "Press 1-5. Enter = Default. Q/Esc = cancel.";
    let status = if invalid {
        INVALID_MESSAGE
    } else {
        instruction
    };
    let available = usize::from(rows.max(1));
    let mut visible_lines = Vec::with_capacity(available.min(10));

    if available >= 10 {
        visible_lines.extend(["Select display mode", ""]);
        visible_lines.extend(options);
        visible_lines.extend(["", instruction, if invalid { INVALID_MESSAGE } else { "" }]);
    } else if available >= 7 {
        visible_lines.push("Select display mode");
        visible_lines.extend(options);
        visible_lines.push(status);
    } else if available >= 6 {
        visible_lines.extend(options);
        visible_lines.push(status);
    } else if invalid {
        visible_lines.extend(options.into_iter().take(available.saturating_sub(1)));
        visible_lines.push(INVALID_MESSAGE);
    } else {
        visible_lines.extend(options.into_iter().take(available));
    }

    for (index, line) in visible_lines.iter().take(available).enumerate() {
        append_truncated_line(&mut output, line, columns.max(1));
        if index + 1 < visible_lines.len().min(available) {
            output.extend_from_slice(b"\r\n");
        }
    }
    output
}

fn append_truncated_line(output: &mut Vec<u8>, line: &str, columns: u16) {
    output.extend(
        line.chars()
            .take(usize::from(columns))
            .collect::<String>()
            .as_bytes(),
    );
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[derive(Debug)]
    struct FakeMenu {
        size: (u16, u16),
        events: VecDeque<InputEvent>,
        writes: Vec<Vec<u8>>,
    }

    impl FakeMenu {
        fn new(events: impl IntoIterator<Item = InputEvent>) -> Self {
            Self {
                size: (80, 24),
                events: events.into_iter().collect(),
                writes: Vec::new(),
            }
        }
    }

    impl DisplayModeMenu for FakeMenu {
        fn size(&self) -> Result<(u16, u16)> {
            Ok(self.size)
        }

        fn write(&mut self, bytes: &[u8]) -> Result<()> {
            self.writes.push(bytes.to_vec());
            Ok(())
        }

        fn poll(&mut self, _timeout: Duration) -> Result<InputEvent> {
            Ok(self.events.pop_front().unwrap_or(InputEvent::Quit))
        }
    }

    #[test]
    fn menu_selects_each_number_directly() {
        for (number, expected) in [
            (1, DisplayMode::Default),
            (2, DisplayMode::ClassicAscii),
            (3, DisplayMode::DetailedAscii),
            (4, DisplayMode::Gradient),
            (5, DisplayMode::HalfBlock),
        ] {
            let mut terminal = FakeMenu::new([InputEvent::SelectDisplayMode(number)]);
            let outcome = select_display_mode(&mut terminal, &AtomicBool::new(false))
                .expect("select display mode");
            assert_eq!(outcome, MenuOutcome::Selected(expected));
            assert_eq!(
                terminal.writes.last().map(Vec::as_slice),
                Some(CLEAR_SCREEN)
            );
        }
    }

    #[test]
    fn enter_without_a_selection_chooses_default() {
        let mut terminal = FakeMenu::new([InputEvent::Confirm]);
        assert_eq!(
            select_display_mode(&mut terminal, &AtomicBool::new(false)).expect("default"),
            MenuOutcome::Selected(DisplayMode::Default)
        );
    }

    #[test]
    fn invalid_input_prints_a_concise_message_and_waits_for_valid_input() {
        let mut terminal = FakeMenu::new([
            InputEvent::InvalidSelection,
            InputEvent::SelectDisplayMode(2),
        ]);
        assert_eq!(
            select_display_mode(&mut terminal, &AtomicBool::new(false)).expect("selection"),
            MenuOutcome::Selected(DisplayMode::ClassicAscii)
        );
        let output = terminal
            .writes
            .iter()
            .map(|write| String::from_utf8_lossy(write))
            .collect::<String>();
        assert!(output.contains(INVALID_MESSAGE));
    }

    #[test]
    fn quit_and_existing_atomic_cancellation_are_clean_cancellations() {
        let mut terminal = FakeMenu::new([InputEvent::Quit]);
        assert_eq!(
            select_display_mode(&mut terminal, &AtomicBool::new(false)).expect("quit"),
            MenuOutcome::Cancelled
        );

        let cancelled = AtomicBool::new(true);
        let mut terminal = FakeMenu::new([]);
        assert_eq!(
            select_display_mode(&mut terminal, &cancelled).expect("signal cancellation"),
            MenuOutcome::Cancelled
        );
        assert!(terminal.writes.is_empty());
    }

    #[test]
    fn explicit_and_noninteractive_policies_never_prompt() {
        assert_eq!(
            selection_policy(Some(DisplayMode::Gradient), true, true),
            DisplayModePolicy::Use(DisplayMode::Gradient)
        );
        assert_eq!(
            selection_policy(Some(DisplayMode::HalfBlock), true, true),
            DisplayModePolicy::Use(DisplayMode::HalfBlock)
        );
        assert_eq!(
            selection_policy(None, true, false),
            DisplayModePolicy::Use(DisplayMode::Default)
        );
        assert_eq!(
            selection_policy(None, false, true),
            DisplayModePolicy::Use(DisplayMode::Default)
        );
        assert_eq!(
            selection_policy(None, true, true),
            DisplayModePolicy::Prompt
        );
    }

    #[test]
    fn menu_layout_handles_tiny_terminals_without_panicking() {
        let bytes = menu_bytes(4, 2, true);
        assert!(bytes.starts_with(CLEAR_SCREEN));
        assert!(bytes.len() < 32);
        assert!(String::from_utf8(bytes).expect("UTF-8").contains("Inva"));

        let bytes = menu_bytes(80, 2, true);
        let text = String::from_utf8(bytes).expect("UTF-8");
        assert!(text.contains(INVALID_MESSAGE));
        assert!(!text.ends_with("\r\n"));

        for rows in [6, 7, 9, 10] {
            let bytes = menu_bytes(80, rows, true);
            let text = String::from_utf8(bytes).expect("UTF-8");
            assert!(text.contains("5. Colored Half-Block"), "{rows} rows");
            assert!(text.contains(INVALID_MESSAGE), "{rows} rows");
            assert!(!text.ends_with("\r\n"), "{rows} rows");
        }
    }
}
