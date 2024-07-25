const expect = @import("std").testing.expect;
const keybuf = @import("chipz").common.keybuf;

const KeyBuf = keybuf.Type(.{ .num_slots = 4 });

test "single key" {
    var kb = KeyBuf.init(.{ .sticky_time = 1000 });
    try expect(kb.sticky_time == 1000);
    kb.update(250);
    try expect(kb.cur_time == 250);
    kb.keyDown('A', 0x1234);
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].mask == 0x1234);
    try expect(kb.slots[0].pressed_time == 250);
    try expect(kb.slots[0].released == false);
    try expect(kb.slots[1].key == 0);
    kb.keyUp('A');
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].released);
    kb.update(250);
    try expect(kb.cur_time == 500);
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].released);
    kb.update(250);
    try expect(kb.cur_time == 750);
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].released);
    kb.update(250);
    try expect(kb.cur_time == 1000);
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].released);
    kb.update(250);
    try expect(kb.cur_time == 1250);
    try expect(kb.slots[0].key == 0);
    try expect(kb.slots[0].mask == 0);
    try expect(kb.slots[0].pressed_time == 0);
    try expect(kb.slots[0].released == false);
}

test "update existing key" {
    var kb = KeyBuf.init(.{ .sticky_time = 1000 });
    try expect(kb.sticky_time == 1000);
    kb.update(250);
    try expect(kb.cur_time == 250);
    kb.keyDown('A', 0x1234);
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].mask == 0x1234);
    try expect(kb.slots[0].pressed_time == 250);
    try expect(kb.slots[0].released == false);
    kb.update(250);
    try expect(kb.cur_time == 500);
    kb.keyDown('A', 0x1234);
    try expect(kb.slots[0].key == 'A');
    try expect(kb.slots[0].mask == 0x1234);
    try expect(kb.slots[0].pressed_time == 500);
    try expect(kb.slots[0].released == false);
    try expect(kb.slots[1].key == 0);
    kb.update(500);
    try expect(kb.slots[0].key == 'A');
    kb.keyUp('A');
    kb.update(500);
    try expect(kb.cur_time == 1500);
    try expect(kb.slots[0].key == 0);
    try expect(kb.slots[0].mask == 0);
    try expect(kb.slots[0].pressed_time == 0);
    try expect(kb.slots[0].released == false);
}

// FIXME: multiple pressed keys
