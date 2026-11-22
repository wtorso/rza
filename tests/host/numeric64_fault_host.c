#include <stdint.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

int main(void) {
    RzaResult result = rza_boot();
#ifdef NUMERIC64_DATA_CELL
    uint64_t value = 0;
    CHECK(NUMERIC64_DATA_CELL != NULL);
    memcpy(&value, NUMERIC64_DATA_CELL, 8);
    CHECK(value == 0);
#endif
#ifdef NUMERIC64_GUARD_OFFSET
    memcpy(&value, (char *)NUMERIC64_DATA_CELL + NUMERIC64_GUARD_OFFSET, 8);
    CHECK(value == 0);
#endif
#ifdef NUMERIC64_OUT_CELL
    CHECK(NUMERIC64_OUT_CELL != NULL);
    memcpy(&value, NUMERIC64_OUT_CELL, 8);
    CHECK(value == 0);
#endif
    CHECK(result.code == NUMERIC64_EXPECTED_CODE);
    CHECK(result.line == NUMERIC64_EXPECTED_LINE);
    return 0;
}
