const std = @import("std");
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const intel8255 = @import("chipz").chips.intel8255;

const Bus = u64;
const Intel8255 = intel8255.Type(.{ .pins = intel8255.DefaultPins, .bus = Bus });
const CTRL = Intel8255.CTRL;
const setData = Intel8255.setData;
const getData = Intel8255.getData;
const setABUS = Intel8255.setABUS;
const getABUS = Intel8255.getABUS;
const setPort = Intel8255.setPort;
const setPortCLO = Intel8255.setPortCLO;
const setPortCHI = Intel8255.setPortCHI;
const getPort = Intel8255.getPort;
const getPortCLO = Intel8255.getPortCLO;
const getPortCHI = Intel8255.getPortCHI;
const PORT = Intel8255.PORT;
const CS = Intel8255.CS;
const RD = Intel8255.RD;
const WR = Intel8255.WR;
const ABUS = Intel8255.ABUS;
const ABUS_MODE = Intel8255.ABUS_MODE;
const A0 = Intel8255.A0;
const A1 = Intel8255.A1;

test "init PPI" {
    const sut = Intel8255.init();
    try expect(sut.reset_active);
    try expect(sut.control == CTRL.RESET);
    for (&sut.ports) |*p| {
        try expect(p.output == 0);
    }
}

test "set/get port" {
    var bus: u64 = 0;
    bus = setPort(PORT.A, bus, 0x12);
    bus = setPort(PORT.B, bus, 0x34);
    bus = setPort(PORT.C, bus, 0x56);
    try expect(getPort(PORT.A, bus) == 0x12);
    try expect(getPort(PORT.B, bus) == 0x34);
    try expect(getPort(PORT.C, bus) == 0x56);
}

test "set/get port C half" {
    var bus: u64 = 0;
    bus = setPort(PORT.C, bus, 0x56);
    try expect(getPort(PORT.C, bus) == 0x56);
    bus = setPortCLO(bus, 0x0a);
    try expect(getPort(PORT.C, bus) == 0x5a);
    try expect(getPortCLO(bus) == 0x0a);
    bus = setPortCHI(bus, 0xb0);
    try expect(getPort(PORT.C, bus) == 0xba);
    try expect(getPortCHI(bus) == 0xb0);
}

test "write A out" {
    const data: u8 = 0xab;
    var sut = Intel8255.init();
    var bus: u64 = CS | WR;
    bus = setABUS(bus, ABUS_MODE.PORT_A);
    bus = setData(bus, data);
    try expect(getData(bus) == data);
    sut.control = CTRL.A_OUTPUT;
    sut.write(bus);
    try expect(sut.ports[PORT.A].output == data);
}

test "write B out" {
    const data: u8 = 0xab;
    var sut = Intel8255.init();
    var bus: u64 = CS | WR;
    bus = setABUS(bus, ABUS_MODE.PORT_B);
    bus = setData(bus, data);
    try expect(getData(bus) == data);
    sut.control = CTRL.B_OUTPUT;
    sut.write(bus);
    try expect(sut.ports[PORT.B].output == data);
}

test "write C out" {
    const data: u8 = 0xab;
    var sut = Intel8255.init();
    var bus: u64 = CS | WR;
    bus = setABUS(bus, ABUS_MODE.PORT_C);
    bus = setData(bus, data);
    try expect(getData(bus) == data);
    sut.write(bus);
    try expect(sut.ports[PORT.C].output == data);
}

test "write control out" {
    const data: u8 = 0x1b | CTRL.CONTROL_MODE;
    var sut = Intel8255.init();
    var bus: u64 = CS | WR;
    bus = setABUS(bus, ABUS_MODE.CTRL);
    bus = setData(bus, data);
    try expect(getData(bus) == data);
    sut.control = 0;
    sut.write(bus);
    try expect(sut.control == data);
}

test "mode select" {
    // configure mode:
    // Port A: input
    // Port B: output
    // Port C: upper half: output, lower half: input
    // all on 'basic input/output' (the only one supported)
    var sut = Intel8255.init();
    const ctrl = CTRL.CONTROL_MODE | CTRL.A_INPUT | CTRL.B_OUTPUT | CTRL.CHI_OUTPUT | CTRL.CLO_INPUT | CTRL.B_CLO_MODE0 | CTRL.A_CHI_MODE0;
    var bus: Bus = 0;

    bus = CS | WR | (ABUS & ABUS_MODE.CTRL);
    bus = setPort(PORT.A, bus, 0x12);
    bus = setPort(PORT.B, bus, 0x34);
    bus = setPort(PORT.C, bus, 0x45);
    bus = setData(bus, ctrl);
    const result_bus = sut.tick(bus);
    try expect(!sut.reset_active);
    try expect(sut.control == ctrl);

    try expect(bus != result_bus);

    try expect(getPort(PORT.A, result_bus) == 0x12);
    try expect(getPort(PORT.B, result_bus) == 0x00);
    try expect(getPort(PORT.C, result_bus) == 0x05);

    // Test reading control word back
    bus = CS | RD | ABUS;
    const result_bus2 = sut.tick(bus);
    try expect(bus != result_bus2);
    const result_ctrl = getData(result_bus2);
    try expect(result_ctrl == ctrl);
}

test "bit set clear" {
    var sut = Intel8255.init();
    var ctrl = CTRL.CONTROL_MODE | CTRL.CHI_OUTPUT | CTRL.CLO_OUTPUT;
    var bus: Bus = 0;
    bus = CS | WR | (ABUS & ABUS_MODE.CTRL);
    bus = setPort(PORT.A, bus, 0x12);
    bus = setPort(PORT.B, bus, 0x34);
    bus = setPort(PORT.C, bus, 0x45);
    bus = setData(bus, ctrl);
    bus = sut.tick(bus);

    // Set bit 3 on port C
    ctrl = CTRL.CONTROL_BIT | CTRL.CTRL_BIT_SET | (3 << 1);
    bus = setData(bus, ctrl);
    bus = sut.tick(bus);
    // Bit 3 must be set
    try expect(getPort(PORT.C, bus) == (1 << 3));

    // Set bit 5 on port C
    ctrl = CTRL.CONTROL_BIT | CTRL.CTRL_BIT_SET | (5 << 1);
    bus = setData(bus, ctrl);
    bus = sut.tick(bus);
    // Bits 3 and 5 must be set
    try expect(getPort(PORT.C, bus) == ((1 << 5) | (1 << 3)));

    // Clear bit 5 on port C
    ctrl = CTRL.CONTROL_BIT | CTRL.CTRL_BIT_RESET | (5 << 1);
    bus = setData(bus, ctrl);
    bus = sut.tick(bus);
    // Bits 3 and 5 must be set
    try expect(getPort(PORT.C, bus) == (1 << 3));
}

test "in/out" {
    var sut = Intel8255.init();
    const ctrl = CTRL.CONTROL_MODE | CTRL.A_INPUT | CTRL.B_OUTPUT | CTRL.CHI_OUTPUT | CTRL.CLO_INPUT | CTRL.A_CHI_MODE0 | CTRL.B_CLO_MODE0;
    var bus: Bus = 0;
    bus = CS | WR | (ABUS & ABUS_MODE.CTRL);
    bus = setPort(PORT.A, bus, 0x12);
    bus = setPort(PORT.B, bus, 0x34);
    bus = setPort(PORT.C, bus, 0x45);
    bus = setData(bus, ctrl);
    bus = sut.tick(bus);

    // Writing to input port A should do nothing
    bus &= ~ABUS | ABUS_MODE.PORT_A;
    bus = setPort(PORT.A, bus, 0x12);
    bus = setPort(PORT.B, bus, 0x34);
    bus = setPort(PORT.C, bus, 0x45);
    bus = setData(bus, 0x33);
    bus = sut.tick(bus);
    try expect(getPort(PORT.A, bus) == 0x12);

    // Writing to output port B should set the output latch
    bus &= ~ABUS;
    bus |= ABUS_MODE.PORT_B;
    bus = setData(bus, 0xaa);
    bus = sut.tick(bus);
    try expect(getPort(PORT.B, bus) == 0xaa);
    try expect(sut.ports[PORT.B].output == 0xaa);

    // Writing to port C should only affect the 'output half' and set all the 'input half' bits.
    bus &= ~ABUS;
    bus |= ABUS_MODE.PORT_C;
    bus = setData(bus, 0x77);
    bus = setPortCLO(bus, 0xf);
    bus = sut.tick(bus);
    try expect(getPort(PORT.C, bus) == 0x7f);
    try expect(sut.ports[PORT.C].output == 0x77);

    // Reading from input port A should return value on bus
    bus &= ~(ABUS | RD | WR);
    bus |= RD;
    bus = setPort(PORT.A, bus, 0xab);
    bus = sut.tick(bus);
    try expect(getData(bus) == 0xab);

    // Reading from output port B should return last output value
    bus &= ~(ABUS | RD | WR);
    bus |= RD | ABUS_MODE.PORT_B;
    bus = setPort(PORT.B, bus, 0x23);
    bus = sut.tick(bus);
    try expect(getData(bus) == 0xaa);

    // Reading from mixed input/output port C should return a mixed latched/input result
    bus &= ~(ABUS | RD | WR);
    bus |= RD | ABUS_MODE.PORT_C;
    bus = setPort(PORT.C, bus, 0x34);
    bus = sut.tick(bus);
    try expect(sut.ports[PORT.C].output == 0x77);
    try expect(getData(bus) == 0x74);
}
