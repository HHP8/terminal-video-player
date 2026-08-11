use std::mem::size_of;
use std::process::Child;

use anyhow::{Context, Result};
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject, TerminateJobObject,
};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};
use windows::core::PCWSTR;

#[derive(Debug)]
pub struct Job {
    handle: Option<HANDLE>,
}

impl Job {
    pub fn new() -> Result<Self> {
        let handle = unsafe { CreateJobObjectW(None, PCWSTR::null()) }
            .context("creating Windows Job Object")?;
        let mut information = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let configure_result = unsafe {
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                std::ptr::from_ref(&information).cast(),
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        if let Err(error) = configure_result {
            let _ = unsafe { CloseHandle(handle) };
            return Err(error).context("configuring kill-on-close Job Object");
        }
        Ok(Self {
            handle: Some(handle),
        })
    }

    pub fn assign(&self, child: &mut Child) -> Result<()> {
        let job = self
            .handle
            .context("decoder Job Object is already closed")?;
        let process = match unsafe {
            OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, child.id())
        } {
            Ok(process) => process,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error).context("opening decoder process for Job Object assignment");
            }
        };
        let assigned = unsafe { AssignProcessToJobObject(job, process) };
        let _ = unsafe { CloseHandle(process) };
        if let Err(error) = assigned {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error).context("assigning decoder process to Job Object");
        }
        Ok(())
    }

    pub fn terminate(&mut self) {
        if let Some(handle) = self.handle.take() {
            let _ = unsafe { TerminateJobObject(handle, 1) };
            let _ = unsafe { CloseHandle(handle) };
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        self.terminate();
    }
}
