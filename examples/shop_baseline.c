#include <stdint.h>
#include <stdio.h>

static int64_t cart[4] = {7, 0, 0, 0};
static int64_t order[4];
static int64_t result;

static void add_item(int64_t price) {
    if (cart[3] != 0) {
        result = 3;
        return;
    }
    cart[1]++;
    cart[2] += price;
    result = 1;
}

static void checkout(void) {
    if (cart[3] != 0) {
        result = 3;
        return;
    }
    if (cart[1] == 0) {
        result = 2;
        return;
    }
    order[0] = cart[0];
    order[1] = cart[1];
    order[2] = cart[2];
    order[3] = 1;
    cart[3] = 1;
    result = 1;
}

static void show(const char *reason, int64_t value) {
    (void)reason;
    printf("%lld\n", (long long)value);
}

static void show_state(int64_t result_value) {
    show("result", result_value);
    show("cart_id", cart[0]);
    show("cart_count", cart[1]);
    show("cart_total", cart[2]);
    show("cart_status", cart[3]);
    show("order_cart_id", order[0]);
    show("order_count", order[1]);
    show("order_total", order[2]);
    show("order_status", order[3]);
}

int main(void) {
    checkout();
    show_state(result);
    add_item(10);
    add_item(20);
    add_item(30);
    show("cart_count", cart[1]);
    show("cart_total", cart[2]);
    checkout();
    show("result", result);
    show("order_cart_id", order[0]);
    show("order_count", order[1]);
    show("order_total", order[2]);
    show("cart_status", cart[3]);
    checkout();
    show_state(result);
    add_item(40);
    show_state(result);
    puts("DEAD");
    return 0;
}
