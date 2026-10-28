/* RESONANCE-3 shop example using only static C23 storage. */
#include <stdio.h>
#include "rez3ext.h"

typedef struct {
    int32_t count;
    double total;
} Cart;

typedef struct {
    RezCavity *base;
    Cart *cart;
} CartCavity;

typedef struct {
    int32_t scroll;
    bool expanded;
} UiState;

static RezCavity field_cavity;
static RezCavity session_cavity;
static RezCavity cart_cavity;
static RezCavity screen_cavity;
static char field_arena[65536];
static char session_arena[16384];
static char cart_arena[4096];
static char screen_arena[4096];
static CartCavity cart_instance;

static int cart_load(RezCellMed cart_med, RezCavity *screen) {
    Cart *cart = rez_deref_cell(cart_med);
    char *view;
    double prices[3] = {10.0, 20.0, 30.0};
    REZ_TRY(cart);
    view = rez_cell_z(screen, 256);
    REZ_TRY(view);
    assert(screen->arena.used >= 256);
    for (int32_t index = 0; index < 3; index++) {
        cart->count++;
        cart->total += prices[index];
    }
    /* Two passes derive 3/60 then 6/120 from three prices per pass. */
    printf("cascade LOAD: %d items, total=%.1f\n", cart->count, cart->total);
    return 0;
}

static void cart_enter(RezCavity *parent) {
    assert(parent != nullptr);
    cart_instance.base = rez_cav_enter(&cart_cavity, parent, cart_arena, 4096);
    assert(cart_instance.base != nullptr);
    cart_instance.cart = rez_cell_z(cart_instance.base, sizeof(Cart));
    assert(cart_instance.cart != nullptr);
}

static void run_screen(RezCavity *session, RezCellMed cart_med) {
    RezCavity *screen;
    UiState *ui;
    assert(session != nullptr);
    screen = rez_cav_enter(&screen_cavity, session, screen_arena, 4096);
    assert(screen != nullptr);
    ui = rez_cell_z(screen, sizeof(UiState));
    assert(ui != nullptr);
    ui->scroll = 340;
    ui->expanded = true;
    if (cart_load(cart_med, screen) != 0) {
        printf("screen: cascade aborted (dead mediator)\n");
    }
    if (cart_load(cart_med, screen) != 0) {
        printf("screen: cascade aborted (dead mediator)\n");
    }
    rez_decay(screen);
}

int main(void) {
    RezCellMed cart_med;
    assert(rez_cav_enter(&field_cavity, nullptr, field_arena, 65536) != nullptr);
    assert(rez_cav_enter(
        &session_cavity,
        &field_cavity,
        session_arena,
        16384
    ) != nullptr);
    cart_enter(&session_cavity);
    cart_med = rez_issue_cell(
        cart_instance.base,
        cart_instance.base,
        cart_instance.cart,
        sizeof(Cart)
    );
    run_screen(&session_cavity, cart_med);
    printf(
        "after back: mediator %s\n",
        rez_deref_cell(cart_med) != nullptr ? "ALIVE (cart survived screen)" : "DEAD"
    );
    rez_decay(cart_instance.base);
    rez_decay(&session_cavity);
    if (rez_deref_cell(cart_med) != nullptr) {
        printf("unexpected: alive after decay\n");
    } else {
        printf("after decay: mediator DEAD (intent would be dropped + logged)\n");
    }
    return 0;
}
