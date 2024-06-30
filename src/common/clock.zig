///! clock helper functions
/// convert micro seconds to number of tick
pub fn microSecondsToTicks(freq_hz: u64, micro_seconds: u32) u32 {
    return @truncate((freq_hz * micro_seconds) / 1000000);
}
