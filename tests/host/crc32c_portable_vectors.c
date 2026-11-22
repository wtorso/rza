#include <stdint.h>
#include "rez3ext.h"

#if REZ_CRC32C_X86
#error "portable vector test requires a non-x86 target"
#endif

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

int main(void) {
    const uint64_t word = UINT64_C(0x3837363534333231);
    const uint64_t expected = UINT64_C(1619493018) ^ UINT32_MAX;
    static_assert(REZ3EXT_ABI == 5);
    CHECK(!rez_crc32c_hardware());
    CHECK(rez_crc32c_u64_fallback(0, 0) == 0);
    CHECK(rez_crc32c_u64(0, 0) == 0);
    CHECK(rez_crc32c_u64_fallback(UINT32_MAX, word) == expected);
    CHECK(rez_crc32c_u64(UINT32_MAX, word) == expected);
    return 0;
}
