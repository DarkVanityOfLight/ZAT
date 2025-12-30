const std = @import("std");

pub const LubyGenerator = struct {
    k: u64 = 1,

    pub fn next(self: *LubyGenerator) u64 {
        var k = self.k;
        self.k += 1;

        while (true) {
            // Find the highest bit set in (k + 1)
            // This is effectively finding the 'i' from the formula
            const bits = 64 - @clz(k);
            const size = (@as(u64, 1) << @intCast(bits - 1));

            // If k is 2^bits - 1
            if (k == (size << 1) - 1) {
                return size;
            }

            // Otherwise, reduce k and continue
            k = k - (size - 1);
        }
    }
};
