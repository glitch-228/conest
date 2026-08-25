//! Desktop webcam capture and QR decoding for Conest Beam.
//!
//! Camera ownership stays on a dedicated native thread. Flutter only polls a
//! bounded queue of decoded `cb1:` text frames, keeping raw camera images and
//! decoder allocations outside the Dart heap.

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use nokhwa::{
    Camera,
    pixel_format::RgbFormat,
    utils::{CameraIndex, RequestedFormat, RequestedFormatType},
};
use rxing::{
    BinaryBitmap, Luma8LuminanceSource, Reader, common::HybridBinarizer, qrcode::QRCodeReader,
};

use crate::beam::BeamFrameHeader;

const FRAME_QUEUE_CAPACITY: usize = 128;
const MIN_DECODE_INTERVAL: Duration = Duration::from_millis(70);

pub(crate) struct DesktopBeamCamera {
    receiver: Receiver<String>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl DesktopBeamCamera {
    pub(crate) fn start(camera_index: u32) -> Result<Self> {
        let (sender, receiver) = sync_channel(FRAME_QUEUE_CAPACITY);
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let worker = thread::Builder::new()
            .name("conest-beam-camera".to_owned())
            .spawn(move || run_camera(camera_index, worker_stop, sender))
            .context("start desktop Beam camera thread")?;
        Ok(Self {
            receiver,
            stop,
            worker: Some(worker),
        })
    }

    pub(crate) fn try_next(&self) -> Option<String> {
        self.receiver.try_recv().ok()
    }

    pub(crate) fn stop(mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn run_camera(camera_index: u32, stop: Arc<AtomicBool>, sender: SyncSender<String>) {
    if let Err(error) = capture_loop(camera_index, &stop, &sender) {
        let _ = sender.try_send(format!("error:{error:#}"));
    }
}

fn capture_loop(camera_index: u32, stop: &AtomicBool, sender: &SyncSender<String>) -> Result<()> {
    let requested =
        RequestedFormat::new::<RgbFormat>(RequestedFormatType::AbsoluteHighestFrameRate);
    let mut camera =
        Camera::new(CameraIndex::Index(camera_index), requested).context("open desktop camera")?;
    camera
        .open_stream()
        .context("start desktop camera stream")?;
    let mut reader = QRCodeReader;
    let mut previous_text = String::new();
    let mut last_decode = Instant::now()
        .checked_sub(MIN_DECODE_INTERVAL)
        .unwrap_or_else(Instant::now);

    while !stop.load(Ordering::Acquire) {
        let elapsed = last_decode.elapsed();
        if elapsed < MIN_DECODE_INTERVAL {
            thread::sleep(MIN_DECODE_INTERVAL - elapsed);
        }
        let frame = camera.frame().context("capture desktop camera frame")?;
        last_decode = Instant::now();
        let rgb = frame
            .decode_image::<RgbFormat>()
            .context("decode desktop camera frame as RGB")?;
        let (width, height) = rgb.dimensions();
        let raw = rgb.into_raw();
        if raw.len() != width as usize * height as usize * 3 {
            return Err(anyhow!("desktop camera returned an invalid RGB frame"));
        }
        let luma = raw
            .as_chunks::<3>()
            .0
            .iter()
            .map(|pixel| {
                // Integer BT.601 luma, rounded and bounded to u8.
                ((77_u32 * pixel[0] as u32
                    + 150_u32 * pixel[1] as u32
                    + 29_u32 * pixel[2] as u32
                    + 128)
                    >> 8) as u8
            })
            .collect::<Vec<_>>();
        let Ok(source) = Luma8LuminanceSource::new(luma, width, height) else {
            continue;
        };
        let mut bitmap = BinaryBitmap::new(HybridBinarizer::new(source));
        let Ok(result) = reader.decode(&mut bitmap) else {
            continue;
        };
        let text = result.getText();
        if text == previous_text || BeamFrameHeader::parse_text(text).is_err() {
            continue;
        }
        previous_text.clear();
        previous_text.push_str(text);
        // A saturated queue means Dart is already behind. Beam fountain
        // frames are redundant, so dropping the newest frame is safe.
        let _ = sender.try_send(text.to_owned());
    }
    camera.stop_stream().context("stop desktop camera stream")?;
    Ok(())
}
