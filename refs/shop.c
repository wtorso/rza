/* ============================================================================
 * SHOP.C — магазин на RESONANCE-3, чистый C89. Тот же сценарий, что в
 * shop.rz3 (прогнан чекером): сессия, экран, корзина, «кнопка назад».
 *
 * Стилистика парадигмы: код состоит из рождений (enter/cell/issue) и работы.
 * Смерть — один rez_leave на полость. Ни одного free в прикладном коде.
 * ============================================================================
 */
#include <stdio.h>
#include "rez3.h"

/* --- предметная область ---------------------------------------------------- */

/* Корзина — полость с состоянием в собственной арене (опора) */
typedef struct { int count; double total; } Cart;

typedef struct { RezCavity *base; Cart *cart; } CartCavity;

static CartCavity *cart_enter(RezCavity *parent) {
    CartCavity *cc = (CartCavity*)malloc(sizeof(CartCavity));  /* имя — вне арены */
    cc->base = rez_enter(parent, 4096);
    cc->cart = (Cart*)rez_cell(cc->base, sizeof(Cart));        /* тело — в арене */
    cc->cart->count = 0; cc->cart->total = 0.0;
    return cc;
}
static void cart_leave(CartCavity *cc) { rez_leave(cc->base); }

/* Резонатор: эфемерное UI-состояние экрана */
typedef struct { int scroll; int expanded; } UiState;

/* --- каскад LOAD: чтение корзины по проходу -> запись ---------------------- */
/* Первый мёртвый проход = атомарный abort. Возврат 0 — ок, -1 — abort.      */
static int cart_load(RezMediator cart_med, RezCavity *screen) {
    RezCavity *cart_cv;
    Cart *cart;
    char *view;                          /* out-ячейка каскада: живёт в полости экрана */
    double prices[3]; int i;

    cart_cv = rez_deref(cart_med);
    REZ_TRY(cart_cv);                    /* шаг 1: проход; мёртв — весь каскад мёртв */
    cart = (Cart*)rez_cell(cart_cv, sizeof(Cart));
    REZ_TRY(cart);                       /* шаг 2: место в полости */
    view = (char*)rez_cell(screen, 256); /* названный потребитель результата */
    REZ_TRY(view);

    prices[0] = 10.0; prices[1] = 20.0; prices[2] = 30.0;   /* внешний эффект */
    for (i = 0; i < 3; i++) { cart->count++; cart->total += prices[i]; } /* шаг 3 */
    printf("cascade LOAD: %d items, total=%.1f\n", cart->count, cart->total);
    return 0;
}

/* --- экран: полость + резонатор; «назад» = выход из функции ---------------- */
static void run_screen(RezCavity *session, RezMediator cart_med) {
    RezCavity *screen = rez_enter(session, 4096);   /* enter */
    UiState *ui = (UiState*)rez_cell(screen, sizeof(UiState));

    ui->scroll = 340; ui->expanded = 1;             /* эфемерное: умрёт с экраном */

    if (cart_load(cart_med, screen) != 0)
        printf("screen: cascade aborted (dead mediator)\n");

    /* имитация «назад»: корзина переживает экран */
    if (cart_load(cart_med, screen) != 0)
        printf("screen: cascade aborted (dead mediator)\n");

    rez_leave(screen);                              /* Decay: экран, ui — одно событие */
}

int main(void) {
    /* Field: корень. В C — просто полость без leave. */
    RezCavity *field  = rez_enter(0, 65536);
    RezCavity *session = rez_enter(field, 16384);   /* enter: сессия */

    CartCavity *cart = cart_enter(session);
    RezMediator cart_med = rez_issue(cart->base);   /* полномочие выдано */

    run_screen(session, cart_med);                  /* экран родился и умер */

    /* После «назад»: корзина жива (владелец — сессия, не экран) */
    printf("after back: mediator %s\n",
           rez_deref(cart_med) ? "ALIVE (cart survived screen)" : "DEAD");

    cart_leave(cart);
    rez_leave(session);                             /* Decay сессии */

    /* После Decay: проход мёртв — мягкая семантика (no-op + лог) */
    if (rez_deref(cart_med))
        printf("unexpected: alive after decay\n");
    else
        printf("after decay: mediator DEAD (intent would be dropped + logged)\n");

    return 0;
}
