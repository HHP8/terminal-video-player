use std::sync::Mutex;
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEventKind,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputEvent {
    None,
    Quit,
    TogglePause,
    ToggleMute,
    SeekRelative(i64),
    Resize(u16, u16),
    Confirm,
    SelectDisplayMode(u8),
    InvalidSelection,
}

static PENDING_EVENT: Mutex<Option<InputEvent>> = Mutex::new(None);

pub fn poll_event(timeout: Duration) -> Result<InputEvent> {
    if let Ok(mut pending) = PENDING_EVENT.lock()
        && let Some(event) = pending.take()
    {
        return Ok(event);
    }
    if !event::poll(timeout).context("polling terminal input")? {
        return Ok(InputEvent::None);
    }

    let first = map_event(event::read().context("reading terminal input")?);
    let InputEvent::Resize(mut columns, mut rows) = first else {
        return Ok(first);
    };

    while event::poll(Duration::ZERO).context("polling queued terminal input")? {
        match map_event(event::read().context("reading queued terminal input")?) {
            InputEvent::Resize(next_columns, next_rows) => {
                columns = next_columns;
                rows = next_rows;
            }
            InputEvent::None => {}
            other => {
                if let Ok(mut pending) = PENDING_EVENT.lock() {
                    *pending = Some(other);
                }
                break;
            }
        }
    }
    Ok(InputEvent::Resize(columns, rows))
}

fn map_event(event: Event) -> InputEvent {
    match event {
        Event::Resize(columns, rows) => InputEvent::Resize(columns, rows),
        Event::Key(key) => map_key(key),
        Event::Mouse(mouse) if matches!(mouse.kind, MouseEventKind::ScrollUp) => {
            InputEvent::SeekRelative(5)
        }
        Event::Mouse(mouse) if matches!(mouse.kind, MouseEventKind::ScrollDown) => {
            InputEvent::SeekRelative(-5)
        }
        _ => InputEvent::None,
    }
}

fn map_key(key: KeyEvent) -> InputEvent {
    if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
        return InputEvent::None;
    }
    if key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(key.code, KeyCode::Char('c') | KeyCode::Char('C'))
    {
        return InputEvent::Quit;
    }
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('Q') => InputEvent::Quit,
        KeyCode::Enter => InputEvent::Confirm,
        KeyCode::Char(value @ '1'..='5') => InputEvent::SelectDisplayMode(value as u8 - b'0'),
        KeyCode::Char(' ') => InputEvent::TogglePause,
        KeyCode::Char('m') | KeyCode::Char('M') => InputEvent::ToggleMute,
        KeyCode::Left => InputEvent::SeekRelative(-5),
        KeyCode::Right => InputEvent::SeekRelative(5),
        _ => InputEvent::InvalidSelection,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_menu_number_keys_and_enter() {
        for number in 1..=5 {
            let key = KeyEvent::new(KeyCode::Char(char::from(b'0' + number)), KeyModifiers::NONE);
            assert_eq!(map_key(key), InputEvent::SelectDisplayMode(number));
        }
        assert_eq!(
            map_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
            InputEvent::Confirm
        );
    }

    #[test]
    fn maps_invalid_menu_key_and_cancellation() {
        assert_eq!(
            map_key(KeyEvent::new(KeyCode::Char('9'), KeyModifiers::NONE)),
            InputEvent::InvalidSelection
        );
        assert_eq!(
            map_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE)),
            InputEvent::Quit
        );
        assert_eq!(
            map_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            InputEvent::Quit
        );
    }
}
