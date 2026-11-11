static mut CART: [i64; 4] = [7, 0, 0, 0];
static mut ORDER: [i64; 4] = [0; 4];
static mut RESULT: i64 = 0;

fn add_item(price: i64) {
    unsafe {
        if CART[3] != 0 {
            RESULT = 3;
            return;
        }
        CART[1] += 1;
        CART[2] += price;
        RESULT = 1;
    }
}

fn checkout() {
    unsafe {
        if CART[3] != 0 {
            RESULT = 3;
            return;
        }
        if CART[1] == 0 {
            RESULT = 2;
            return;
        }
        ORDER[0] = CART[0];
        ORDER[1] = CART[1];
        ORDER[2] = CART[2];
        ORDER[3] = 1;
        CART[3] = 1;
        RESULT = 1;
    }
}

fn show(_reason: &str, value: i64) {
    println!("{}", value);
}

fn show_state(result_value: i64) {
    unsafe {
        show("result", result_value);
        show("cart_id", CART[0]);
        show("cart_count", CART[1]);
        show("cart_total", CART[2]);
        show("cart_status", CART[3]);
        show("order_cart_id", ORDER[0]);
        show("order_count", ORDER[1]);
        show("order_total", ORDER[2]);
        show("order_status", ORDER[3]);
    }
}

fn main() {
    checkout();
    unsafe { show_state(RESULT) };
    add_item(10);
    add_item(20);
    add_item(30);
    unsafe {
        show("cart_count", CART[1]);
        show("cart_total", CART[2]);
    }
    checkout();
    unsafe {
        show("result", RESULT);
        show("order_cart_id", ORDER[0]);
        show("order_count", ORDER[1]);
        show("order_total", ORDER[2]);
        show("cart_status", CART[3]);
    }
    checkout();
    unsafe { show_state(RESULT) };
    add_item(40);
    unsafe { show_state(RESULT) };
    println!("DEAD");
}
