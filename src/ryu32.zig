// Copyright 2018 Ulf Adams
//
// The contents of this file may be used under the terms of the Apache License,
// Version 2.0.
//
//    (See accompanying file LICENSE-Apache or copy at
//     http://www.apache.org/licenses/LICENSE-2.0)
//
// Alternatively, the contents of this file may be used under the terms of
// the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE-Boost or copy at
//     https://www.boost.org/LICENSE_1_0.txt)
//
// Unless required by applicable law or agreed to in writing, this software
// is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.

const std = @import("std");

const common = @import("common.zig");
const helper = common;
const DIGIT_TABLE = common.DIGIT_TABLE;

const table = struct {
    // This table is generated by PrintFloatLookupTable.
    const float_pow5_inv_bitcount = 59;
    const float_pow5_inv_split = [_]u64{
        576460752303423489, 461168601842738791, 368934881474191033, 295147905179352826,
        472236648286964522, 377789318629571618, 302231454903657294, 483570327845851670,
        386856262276681336, 309485009821345069, 495176015714152110, 396140812571321688,
        316912650057057351, 507060240091291761, 405648192073033409, 324518553658426727,
        519229685853482763, 415383748682786211, 332306998946228969, 531691198313966350,
        425352958651173080, 340282366920938464, 544451787073501542, 435561429658801234,
        348449143727040987, 557518629963265579, 446014903970612463, 356811923176489971,
        570899077082383953, 456719261665907162, 365375409332725730,
    };

    const float_pow5_bitcount = 61;
    const float_pow5_split = [_]u64{
        1152921504606846976, 1441151880758558720, 1801439850948198400, 2251799813685248000,
        1407374883553280000, 1759218604441600000, 2199023255552000000, 1374389534720000000,
        1717986918400000000, 2147483648000000000, 1342177280000000000, 1677721600000000000,
        2097152000000000000, 1310720000000000000, 1638400000000000000, 2048000000000000000,
        1280000000000000000, 1600000000000000000, 2000000000000000000, 1250000000000000000,
        1562500000000000000, 1953125000000000000, 1220703125000000000, 1525878906250000000,
        1907348632812500000, 1192092895507812500, 1490116119384765625, 1862645149230957031,
        1164153218269348144, 1455191522836685180, 1818989403545856475, 2273736754432320594,
        1421085471520200371, 1776356839400250464, 2220446049250313080, 1387778780781445675,
        1734723475976807094, 2168404344971008868, 1355252715606880542, 1694065894508600678,
        2117582368135750847, 1323488980084844279, 1654361225106055349, 2067951531382569187,
        1292469707114105741, 1615587133892632177, 2019483917365790221,
    };
};

fn mulShift(m: u32, factor: u64, shift: i32) u32 {
    std.debug.assert(shift > 32);

    const factor_lo = @truncate(u32, factor);
    const factor_hi = @intCast(u32, factor >> 32);
    const bits0 = @as(u64, m) * factor_lo;
    const bits1 = @as(u64, m) * factor_hi;

    const sum = (bits0 >> 32) + bits1;
    const shifted_sum = sum >> @intCast(u6, shift - 32);
    return @intCast(u32, shifted_sum);
}

fn mulPow5InvDivPow2(m: u32, q: u32, j: i32) u32 {
    return mulShift(m, table.float_pow5_inv_split[q], j);
}

fn mulPow5DivPow2(m: u32, i: u32, j: i32) u32 {
    return mulShift(m, table.float_pow5_split[i], j);
}

const Decimal32 = struct {
    sign: bool,
    mantissa: u32,
    exponent: i32,
};

pub fn ryu16(f: f16, result: []u8) []u8 {
    std.debug.assert(result.len >= 11);
    const mantissa_bits = std.math.floatMantissaBits(f16);
    const exponent_bits = std.math.floatExponentBits(f16);

    const bits = @bitCast(u16, f);
    const v = floatToDecimal(bits, mantissa_bits, exponent_bits, false);
    const index = decimalToBuffer(v, result);
    return result[0..index];
}

pub fn ryu32(f: f32, result: []u8) []u8 {
    std.debug.assert(result.len >= 16);
    const mantissa_bits = std.math.floatMantissaBits(f32);
    const exponent_bits = std.math.floatExponentBits(f32);

    const bits = @bitCast(u32, f);
    const v = floatToDecimal(bits, mantissa_bits, exponent_bits, false);
    const index = decimalToBuffer(v, result);
    return result[0..index];
}

fn floatToDecimal(bits: u32, mantissa_bits: u5, exponent_bits: u5, explicit_leading_bit: bool) Decimal32 {
    const exponent_bias = (@as(u32, 1) << (exponent_bits - 1)) - 1;
    const sign = ((bits >> (mantissa_bits + exponent_bits)) & 1) != 0;
    const mantissa = bits & ((@as(u32, 1) << mantissa_bits) - 1);
    const exponent = (bits >> mantissa_bits) & ((@as(u32, 1) << exponent_bits) - 1);

    // Filter out special case nan and inf
    if (exponent == 0 and mantissa == 0) {
        return Decimal32{
            .sign = sign,
            .mantissa = 0,
            .exponent = 0,
        };
    }
    if (exponent == ((@as(u32, 1) << exponent_bits) - 1)) {
        return Decimal32{
            .sign = sign,
            .mantissa = if (explicit_leading_bit) mantissa & ((@as(u32, 1) << (mantissa_bits - 1)) - 1) else mantissa,
            .exponent = 0x7fffffff,
        };
    }

    var e2: i32 = undefined;
    var m2: u32 = undefined;

    // We subtract 2 so that the bounds computation has 2 additional bits.
    if (explicit_leading_bit) {
        // mantissa includes the explicit leading bit, so we need to correct for that here
        if (exponent == 0) {
            e2 = 1 - @intCast(i32, exponent_bias) - @intCast(i32, mantissa_bits) + 1 - 2;
        } else {
            e2 = @intCast(i32, exponent) - @intCast(i32, exponent_bias) - @intCast(i32, mantissa_bits) + 1 - 2;
        }
        m2 = mantissa;
    } else {
        if (exponent == 0) {
            e2 = 1 - @intCast(i32, exponent_bias) - @intCast(i32, mantissa_bits) - 2;
            m2 = mantissa;
        } else {
            e2 = @intCast(i32, exponent) - @intCast(i32, exponent_bias) - @intCast(i32, mantissa_bits) - 2;
            m2 = (@as(u32, 1) << mantissa_bits) | mantissa;
        }
    }

    const even = m2 & 1 == 0;
    const accept_bounds = even;

    // Step 2: Determine the interval of legal decimal representations.
    const mv = 4 * m2;
    const mp = 4 * m2 + 2;
    // Implicit bool -> int conversion. True is 1, false is 0.
    const mm_shift = mantissa != 0 or exponent <= 1;
    const mm = 4 * m2 - 1 - @boolToInt(mm_shift);

    // Step 3: Convert to a decimal power base using 64-bit arithmetic.
    var vr: u32 = undefined;
    var vp: u32 = undefined;
    var vm: u32 = undefined;
    var e10: i32 = undefined;
    var vm_is_trailing_zeros = false;
    var vr_is_trailing_zeros = false;
    var last_removed_digit: u8 = 0;

    if (e2 >= 0) {
        const q = helper.log10Pow2(e2);
        e10 = q;
        const k = table.float_pow5_inv_bitcount + helper.pow5Bits(q) - 1;
        const i = -e2 + @intCast(i32, q) + @intCast(i32, k);
        vr = mulPow5InvDivPow2(mv, @intCast(u32, q), i);
        vp = mulPow5InvDivPow2(mp, @intCast(u32, q), i);
        vm = mulPow5InvDivPow2(mm, @intCast(u32, q), i);

        if (q != 0 and ((vp - 1) / 10 <= vm / 10)) {
            // We need to know one removed digit even if we are not going to loop below. We could use
            // q = X - 1 above, except that would require 33 bits for the result, and we've found that
            // 32-bit arithmetic is faster even on 64-bit machines.
            const l = table.float_pow5_inv_bitcount + helper.pow5Bits(q - 1) - 1;
            last_removed_digit = @intCast(u8, (mulPow5InvDivPow2(mv, @intCast(u32, q - 1), -e2 + @intCast(i32, q) - 1 + @intCast(i32, l)) % 10));
        }
        if (q <= 9) {
            // The largest power of 5 that fits in 24 bits is 5^10, but q<=9 seems to be safe as well.
            // Only one of mp, mv, and mm can be a multiple of 5, if any.
            if (mv % 5 == 0) {
                vr_is_trailing_zeros = helper.multipleOfPowerOf5(mv, q);
            } else if (accept_bounds) {
                vm_is_trailing_zeros = helper.multipleOfPowerOf5(mm, q);
            } else {
                vp -= @boolToInt(helper.multipleOfPowerOf5(mp, q));
            }
        }
    } else {
        const q = helper.log10Pow5(-e2);
        e10 = q + e2;
        const i = -e2 - q;
        const k = @intCast(i32, helper.pow5Bits(i)) - table.float_pow5_bitcount;
        var j = q - @intCast(i32, k);
        vr = mulPow5DivPow2(mv, @intCast(u32, i), j);
        vp = mulPow5DivPow2(mp, @intCast(u32, i), j);
        vm = mulPow5DivPow2(mm, @intCast(u32, i), j);

        if (q != 0 and ((vp - 1) / 10 <= vm / 10)) {
            j = @intCast(i32, q) - 1 - (@intCast(i32, helper.pow5Bits(i + 1)) - @intCast(i32, table.float_pow5_bitcount));
            last_removed_digit = @intCast(u8, mulPow5DivPow2(mv, @intCast(u32, i + 1), j) % 10);
        }
        if (q <= 1) {
            // {vr,vp,vm} is trailing zeros if {mv,mp,mm} has at least q trailing 0 bits.
            // mv = 4 * m2, so it always has at least two trailing 0 bits.
            vr_is_trailing_zeros = true;
            if (accept_bounds) {
                // mm = mv - 1 - mmShift, so it has 1 trailing 0 bit iff mmShift == 1.
                vm_is_trailing_zeros = mm_shift;
            } else {
                // mp = mv + 2, so it always has at least one trailing 0 bit.
                vp -= 1;
            }
        } else if (q < 31) { // TODO(ulfjack): Use a tighter bound here.
            vr_is_trailing_zeros = (mv & ((@as(u32, 1) << @intCast(u5, (q - 1))) - 1)) == 0;
        }
    }

    // Step 4: Find the shortest decimal representation in the interval of legal representations.
    var removed: u32 = 0;
    var output: u32 = undefined;
    if (vm_is_trailing_zeros or vr_is_trailing_zeros) {
        // General case, which happens rarely.
        while (vp / 10 > vm / 10) {
            vm_is_trailing_zeros = vm_is_trailing_zeros and vm % 10 == 0;
            vr_is_trailing_zeros = vr_is_trailing_zeros and last_removed_digit == 0;
            last_removed_digit = @intCast(u8, vr % 10);
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed += 1;
        }
        if (vm_is_trailing_zeros) {
            while (vm % 10 == 0) {
                vr_is_trailing_zeros = vr_is_trailing_zeros and last_removed_digit == 0;
                last_removed_digit = @intCast(u8, vr % 10);
                vr /= 10;
                vp /= 10;
                vm /= 10;
                removed += 1;
            }
        }
        if (vr_is_trailing_zeros and (last_removed_digit == 5) and (vr % 2 == 0)) {
            // Round even if the exact number is .....50..0.
            last_removed_digit = 4;
        }
        // We need to take vr+1 if vr is outside bounds or we need to round up.
        output = vr +
            @boolToInt((vr == vm and (!accept_bounds or !vm_is_trailing_zeros)) or (last_removed_digit >= 5));
    } else {
        // Common case.
        while (vp / 10 > vm / 10) {
            last_removed_digit = @intCast(u8, vr % 10);
            vr /= 10;
            vp /= 10;
            vm /= 10;
            removed += 1;
        }
        // We need to take vr+1 if vr is outside bounds or we need to round up.
        output = vr + @boolToInt((vr == vm) or (last_removed_digit >= 5));
    }

    return Decimal32{
        .sign = sign,
        .mantissa = output,
        .exponent = e10 + @intCast(i32, removed),
    };
}

fn decimalToBuffer(v: Decimal32, result: []u8) usize {
    if (v.exponent == 0x7fffffff) {
        return common.copySpecialString(result, v);
    }

    // Step 5: Print the decimal representation.
    var index: usize = 0;
    if (v.sign) {
        result[index] = '-';
        index += 1;
    }

    var output = v.mantissa;
    const olength = common.decimalLength(true, 9, output);

    // Print the decimal digits. The following code is equivalent to:
    //
    // var i: usize = 0;
    // while (i < olength - 1) : (i += 1) {
    //     const c = output % 10;
    //     output /= 10;
    //     result[index + olength - i] = @intCast(u8, '0' + c);
    // }
    // result[index] = @intCast(u8, '0' + output % 10);
    var i: usize = 0;
    while (output >= 10000) {
        const c = output % 10000;
        output /= 10000;
        const c0 = (c % 100) << 1;
        const c1 = (c / 100) << 1;

        // TODO: See https://github.com/ziglang/zig/issues/1329
        result[index + olength - i - 1 + 0] = DIGIT_TABLE[c0 + 0];
        result[index + olength - i - 1 + 1] = DIGIT_TABLE[c0 + 1];
        result[index + olength - i - 3 + 0] = DIGIT_TABLE[c1 + 0];
        result[index + olength - i - 3 + 1] = DIGIT_TABLE[c1 + 1];
        i += 4;
    }
    if (output >= 100) {
        const c = (output % 100) << 1;
        output /= 100;

        result[index + olength - i - 1 + 0] = DIGIT_TABLE[c + 0];
        result[index + olength - i - 1 + 1] = DIGIT_TABLE[c + 1];
        i += 2;
    }
    if (output >= 10) {
        const c = output << 1;
        result[index + olength - i] = DIGIT_TABLE[c + 1];
        result[index] = DIGIT_TABLE[c];
    } else {
        result[index] = @intCast(u8, '0' + output);
    }

    // Print decimal point if needed.
    if (olength > 1) {
        result[index + 1] = '.';
        index += olength + 1;
    } else {
        index += 1;
    }

    // Print the exponent.
    result[index] = 'E';
    var exp = v.exponent + @intCast(i32, olength) - 1;
    index += 1;
    if (exp < 0) {
        result[index] = '-';
        index += 1;
        exp = -exp;
    }

    var expu = @intCast(usize, exp);

    if (exp >= 10) {
        result[index + 0] = DIGIT_TABLE[2 * expu + 0];
        result[index + 1] = DIGIT_TABLE[2 * expu + 1];
        index += 2;
    } else {
        result[index] = @intCast(u8, '0' + expu);
        index += 1;
    }

    return index;
}

fn T(expected: []const u8, input: f32) void {
    var buffer: [53]u8 = undefined;
    const converted = ryu32(input, buffer[0..]);
    std.debug.assert(std.mem.eql(u8, expected, converted));
}

test "ryu32 basic" {
    T("0E0", 0.0);
    T("-0E0", -@as(f32, 0.0));
    T("1E0", 1.0);
    T("-1E0", -1.0);
    T("NaN", std.math.nan(f32));
    T("Infinity", std.math.inf(f32));
    T("-Infinity", -std.math.inf(f32));
}

test "ryu32 switch to subnormal" {
    T("1.1754944E-38", 1.1754944e-38);
}

test "ryu32 min and max" {
    T("3.4028235E38", @bitCast(f32, @as(u32, 0x7f7fffff)));
    T("1E-45", @bitCast(f32, @as(u32, 1)));
}

// Check that we return the exact boundary if it is the shortest
// representation, but only if the original floating point number is even.
test "ryu32 boundary round even" {
    T("3.355445E7", 3.355445e7);
    T("9E9", 8.999999e9);
    T("3.436672E10", 3.4366717e10);
}

// If the exact value is exactly halfway between two shortest representations,
// then we round to even. It seems like this only makes a difference if the
// last two digits are ...2|5 or ...7|5, and we cut off the 5.
test "ryu32 exact value round even" {
    T("3.0540412E5", 3.0540412E5);
    T("8.0990312E3", 8.0990312E3);
}

test "ryu32 lots of trailing zeros" {
    // Pattern for the first test: 00111001100000000000000000000000
    T("2.4414062E-4", 2.4414062E-4);
    T("2.4414062E-3", 2.4414062E-3);
    T("4.3945312E-3", 4.3945312E-3);
    T("6.3476562E-3", 6.3476562E-3);
}

test "ryu32 looks like pow5" {
    // These numbers have a mantissa that is the largest power of 5 that fits,
    // and an exponent that causes the computation for q to result in 10, which is a corner
    // case for Ryu.
    T("6.7108864E17", @bitCast(f32, @as(u32, 0x5D1502F9)));
    T("1.3421773E18", @bitCast(f32, @as(u32, 0x5D9502F9)));
    T("2.6843546E18", @bitCast(f32, @as(u32, 0x5E1502F9)));
}

test "ryu32 regression" {
    T("4.7223665E21", 4.7223665E21);
    T("8.388608E6", 8388608.0);
    T("1.6777216E7", 1.6777216E7);
    T("3.3554436E7", 3.3554436E7);
    T("6.7131496E7", 6.7131496E7);
    T("1.9310392E-38", 1.9310392E-38);
    T("-2.47E-43", -2.47E-43);
    T("1.993244E-38", 1.993244E-38);
    T("4.1039004E3", 4103.9003);
    T("5.3399997E9", 5.3399997E9);
    T("6.0898E-39", 6.0898E-39);
    T("1.0310042E-3", 0.0010310042);
    T("2.882326E17", 2.8823261E17);
    T("7.038531E-26", 7.0385309E-26);
    T("9.223404E17", 9.2234038E17);
    T("6.710887E7", 6.7108872E7);
    T("1E-44", 1.0E-44);
    T("2.816025E14", 2.816025E14);
    T("9.223372E18", 9.223372E18);
    T("1.5846086E29", 1.5846085E29);
    T("1.1811161E19", 1.1811161E19);
    T("5.368709E18", 5.368709E18);
    T("4.6143166E18", 4.6143165E18);
    T("7.812537E-3", 0.007812537);
    T("1E-45", 1.4E-45);
    T("1.18697725E20", 1.18697724E20);
    T("1.00014165E-36", 1.00014165E-36);
    T("2E2", 200.0);
    T("3.3554432E7", 3.3554432E7);
}
