use std::io::{self, Write};
use std::panic;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, Once, OnceLock};

use anyhow::{Context, Result};
use crossterm::cursor::{Hide, Show};
use crossterm::execute;
use crossterm::style::ResetColor;
use crossterm::terminal::{
    Clear, ClearType, DisableLineWrap, EnableLineWrap, EnterAlternateScreen, LeaveAlternateScreen,
    disable_raw_mode, enable_raw_mode,
};

static TERMINAL_ACTIVE: AtomicBool = AtomicBool::new(false);
static RESTORE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static PANIC_HOOK: Once = Once::new();

#[derive(Debug)]
pub struct TerminalSession {
    active: bool,
}

impl TerminalSession {
    pub fn enter() -> Result<Self> {
        let mut session = Self { active: false };
        enable_raw_mode().context("enabling raw input mode")?;
        session.active = true;
        TERMINAL_ACTIVE.store(true, Ordering::SeqCst);
        let enter_result = execute!(
            io::stdout(),
            EnterAlternateScreen,
            ResetColor,
            DisableLineWrap,
            Hide,
            Clear(ClearType::All)
        );
        if let Err(error) = enter_result {
            session.restore();
            return Err(error).context("entering alternate screen");
        }
        Ok(session)
    }

    pub fn size(&self) -> Result<(u16, u16)> {
        crossterm::terminal::size().context("reading terminal size")
    }

    pub fn write_frame(&mut self, bytes: &[u8]) -> Result<()> {
        let mut stdout = io::stdout().lock();
        stdout.write_all(bytes).context("writing terminal frame")?;
        stdout.flush().context("flushing terminal frame")
    }

    pub fn restore(&mut self) {
        if self.active {
            restore_terminal();
            self.active = false;
        }
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        self.restore();
    }
}

pub fn install_panic_hook() {
    PANIC_HOOK.call_once(|| {
        let terminal_thread = std::thread::current().id();
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            // A worker panic is reported back to the playback loop, which still
            // owns the terminal session. Restoring from that worker would expose
            // the main buffer while the owner can still render one final frame.
            if std::thread::current().id() == terminal_thread {
                restore_terminal();
            }
            previous(info);
        }));
    });
}

pub fn restore_terminal() {
    restore_terminal_impl(false);
}

pub fn force_restore_terminal() {
    restore_terminal_impl(true);
}

fn restore_terminal_impl(force: bool) {
    let lock = RESTORE_LOCK.get_or_init(|| Mutex::new(()));
    let Ok(_guard) = lock.lock() else {
        return;
    };

    let was_active = TERMINAL_ACTIVE.swap(false, Ordering::SeqCst);
    let raw_mode = crossterm::terminal::is_raw_mode_enabled().unwrap_or(false);
    if force || was_active {
        let _ = execute!(
            io::stdout(),
            ResetColor,
            Show,
            EnableLineWrap,
            LeaveAlternateScreen
        );
    }
    if force || was_active || raw_mode {
        let _ = disable_raw_mode();
    }
    if force || was_active {
        let _ = io::stdout().flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restoration_is_idempotent_without_active_session() {
        restore_terminal();
        restore_terminal();
        assert!(!TERMINAL_ACTIVE.load(Ordering::SeqCst));
    }
}
