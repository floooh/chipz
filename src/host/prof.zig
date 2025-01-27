/// simple value history for profiling data
const assert = @import("std").debug.assert;

pub const Bucket = enum {
    FRAME,
    EMU,
};
const NUM_BUCKETS = 2;

pub const Stats = struct {
    count: usize = 0,
    avg_val: f32 = 0.0,
    min_val: f32 = 0.0,
    max_val: f32 = 0.0,
};

const RING_SIZE = 128;

const Ring = struct {
    head: usize = 0,
    tail: usize = 0,
    values: [RING_SIZE]f32 = [_]f32{0.0} ** RING_SIZE,

    fn index(i: usize) usize {
        return i % RING_SIZE;
    }

    fn count(self: *const Ring) usize {
        if (self.head >= self.tail) {
            return self.head - self.tail;
        } else {
            return (self.head + RING_SIZE) - self.tail;
        }
    }

    fn empty(self: *const Ring) bool {
        return self.count() == 0;
    }

    fn put(self: *Ring, val: f32) void {
        self.values[self.head] = val;
        self.head = index(self.head + 1);
        if (self.head == self.tail) {
            self.tail = index(self.tail + 1);
        }
    }

    fn get(self: *Ring, idx: usize) f32 {
        assert(!self.empty());
        return self.values[index(self.tail + idx)];
    }
};

const state = struct {
    var valid: bool = false;
    var buckets: [NUM_BUCKETS]Ring = undefined;
};

fn bucketRing(bucket: Bucket) *Ring {
    return &state.buckets[@intFromEnum(bucket)];
}

pub fn init() void {
    assert(!state.valid);
    state.valid = true;
    state.buckets = [_]Ring{.{}} ** NUM_BUCKETS;
}

pub fn shutdown() void {
    assert(state.valid);
    state.valid = false;
}

pub fn push(bucket: Bucket, val: f32) void {
    assert(state.valid);
    bucketRing(bucket).put(val);
}

pub fn pushMicroSeconds(bucket: Bucket, val: u32) void {
    push(bucket, @as(f32, @floatFromInt(val)) * 0.001);
}

pub fn count(bucket: Bucket) usize {
    return bucketRing(bucket).count();
}

pub fn value(bucket: Bucket, index: usize) f32 {
    assert(state.valid);
    return bucketRing(bucket).get(index);
}

pub fn stats(bucket: Bucket) Stats {
    var res = Stats{};
    const ring = bucketRing(bucket);
    res.count = ring.count();
    if (res.count > 0) {
        res.min_val = 1000.0;
        for (0..res.count) |i| {
            const val = ring.get(i);
            res.avg_val += val;
            if (val < res.min_val) {
                res.min_val = val;
            } else if (val > res.max_val) {
                res.max_val = val;
            }
        }
        res.avg_val /= @floatFromInt(res.count);
    }
    return res;
}
