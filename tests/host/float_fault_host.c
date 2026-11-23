#include <stdint.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) return __LINE__; } while (0)

static uint32_t float_diagnostics;
static RzaDiagnostic float_last_diagnostic;

static void float_diagnostic(RzaDiagnostic diagnostic, void *context) {
    (void)context;
    float_diagnostics++;
    float_last_diagnostic = diagnostic;
}

int main(void) {
    rza_set_diagnostic_handler(float_diagnostic, NULL);
    RzaResult result = rza_boot();
#ifdef FLOAT_DATA_CELL
    CHECK(FLOAT_DATA_CELL != NULL);
    CHECK(FLOAT_DATA_SIZE >= 8 && FLOAT_DATA_SIZE <= 16);
    unsigned char data[16];
    memcpy(data, FLOAT_DATA_CELL, FLOAT_DATA_SIZE);
    uint64_t value;
    memcpy(&value, data, sizeof(value));
    CHECK(value == FLOAT_DATA_EXPECTED);
    for (uint32_t index = 8; index < FLOAT_DATA_SIZE; index++) {
        CHECK(data[index] == 0);
    }
#ifdef FLOAT_CALLBACK_OFFSET
    uint32_t marker;
    memcpy(&marker, data + FLOAT_CALLBACK_OFFSET, sizeof(marker));
    CHECK(marker == 0);
#endif
#endif
#ifdef FLOAT_OUT_CELL
    CHECK(FLOAT_OUT_CELL != NULL);
#ifdef FLOAT_OUT_MEDIATOR
    RezCellMed out_mediator = FLOAT_OUT_MEDIATOR();
    CHECK(out_mediator.cell == NULL);
#endif
    memcpy(&value, FLOAT_OUT_CELL, sizeof(value));
    CHECK(value == 0);
#endif
    CHECK(result.code == FLOAT_EXPECTED_CODE);
    CHECK(result.line == FLOAT_EXPECTED_LINE);
    CHECK(float_diagnostics == 1);
    CHECK(float_last_diagnostic.fault == FLOAT_EXPECTED_CODE);
    CHECK(float_last_diagnostic.line == FLOAT_EXPECTED_LINE);
    CHECK(strcmp(float_last_diagnostic.operation, "invalid conversion") == 0);
    return 0;
}
