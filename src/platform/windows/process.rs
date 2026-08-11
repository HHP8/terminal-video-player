use std::os::windows::process::CommandExt;
use std::process::Command;

use windows::Win32::System::Threading::CREATE_NO_WINDOW;

pub fn configure_hidden(command: &mut Command) {
    command.creation_flags(CREATE_NO_WINDOW.0);
}
