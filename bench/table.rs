use std::cell::RefCell;

const TABLE_SLOTS: usize = 512;
const REQUEST_COUNT: u64 = 1024;

#[derive(Clone, Copy)]
struct Entry {
    key: u64,
    value: u64,
}

pub struct Table {
    slots: [Entry; TABLE_SLOTS],
}

thread_local! {
    static TABLE: RefCell<Table> = const {
        RefCell::new(Table { slots: [Entry { key: 0, value: 0 }; TABLE_SLOTS] })
    };
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub fn table_step(table: &mut Table) -> u64 {
    table.slots.fill(Entry { key: 0, value: 0 });
    'requests: for request in 0..REQUEST_COUNT {
        let key = ((request * 37 + 11) & 255) + 1;
        let mut slot = ((key * 2_654_435_761) & 511) as usize;
        for _ in 0..TABLE_SLOTS {
            if table.slots[slot].key == 0 {
                table.slots[slot] = Entry { key, value: request & 7 };
                continue 'requests;
            }
            if table.slots[slot].key == key {
                table.slots[slot].value += request & 7;
                continue 'requests;
            }
            slot = (slot + 1) & (TABLE_SLOTS - 1);
        }
        return 0;
    }
    table.slots.iter()
        .filter(|entry| entry.key != 0)
        .map(|entry| entry.key * entry.value)
        .sum()
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_prepare() {
    TABLE.with(|_| {});
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_step() -> u64 {
    TABLE.with_borrow_mut(table_step)
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub extern "C" fn workload_backend() -> u32 {
    0
}
