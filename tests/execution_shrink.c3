module rza_tests;

alias OraclePredicate = fn bool(OracleWorld world);

enum OracleDimension : char {
    PREFIX,
    FORWARD,
    LOOP,
    SUFFIX,
    TRIPS,
    PROC_COUNT,
    PROC_CALLS,
}

fn int oracle_dimension_get(OracleWorld world, OracleDimension dimension) {
    switch (dimension) {
        case OracleDimension.PREFIX: return world.prefix_ops;
        case OracleDimension.FORWARD: return world.forward_ops;
        case OracleDimension.LOOP: return world.loop_ops;
        case OracleDimension.SUFFIX: return world.suffix_ops;
        case OracleDimension.TRIPS: return world.loop_trips;
        case OracleDimension.PROC_COUNT: return world.proc_count;
        default: return world.proc_calls;
    }
}

fn void oracle_dimension_set(OracleWorld* world, OracleDimension dimension, int value) {
    assert(value >= 0);
    switch (dimension) {
        case OracleDimension.PREFIX: world.prefix_ops = value;
        case OracleDimension.FORWARD: world.forward_ops = value;
        case OracleDimension.LOOP: world.loop_ops = value;
        case OracleDimension.SUFFIX: world.suffix_ops = value;
        case OracleDimension.TRIPS:
            assert(value > 0);
            world.loop_trips = value;
        case OracleDimension.PROC_COUNT:
            assert(value <= PROC_ORACLE_PROCS_MAX);
            world.proc_count = value;
            if (value < PROC_ORACLE_PROCS_MAX) world.nested_calls = false;
        case OracleDimension.PROC_CALLS: world.proc_calls = value;
    }
}

fn bool oracle_lower_dimension(OracleWorld* best, OracleDimension dimension,
        int floor, OraclePredicate fails) {
    int current = oracle_dimension_get(*best, dimension);
    if (current <= floor) return false;
    bool improved = false;
    OracleWorld candidate = *best;
    oracle_dimension_set(&candidate, dimension, floor);
    if (fails(candidate)) {
        *best = candidate;
        return true;
    }
    int value = floor + (current - floor) / 2;
    int steps = 0;
    while (value > floor && value < oracle_dimension_get(*best, dimension)) {
        assert(steps < 32);
        steps++;
        candidate = *best;
        oracle_dimension_set(&candidate, dimension, value);
        if (fails(candidate)) {
            *best = candidate;
            improved = true;
            value = floor + (value - floor) / 2;
        } else {
            value = value + (oracle_dimension_get(*best, dimension) - value) / 2 + 1;
            if (value >= oracle_dimension_get(*best, dimension)) break;
        }
    }
    assert(oracle_dimension_get(*best, dimension) >= floor);
    assert(oracle_dimension_get(*best, dimension) <= current);
    if (improved) assert(oracle_dimension_get(*best, dimension) < current);
    return improved;
}

fn void oracle_lower_features(OracleWorld* best, OraclePredicate fails) {
    if (best.forward_branch) {
        OracleWorld candidate = *best;
        candidate.forward_branch = false;
        if (fails(candidate)) *best = candidate;
    }
    if (best.backward_loop) {
        OracleWorld candidate = *best;
        candidate.backward_loop = false;
        if (fails(candidate)) *best = candidate;
    }
    if (best.nested_calls) {
        OracleWorld candidate = *best;
        candidate.nested_calls = false;
        if (fails(candidate)) *best = candidate;
    }
    if (best.proc_fault != ProcFaultMode.NONE) {
        OracleWorld candidate = *best;
        candidate.proc_fault = ProcFaultMode.NONE;
        if (fails(candidate)) *best = candidate;
    }
}

fn OracleWorld oracle_shrink(OracleWorld world, OraclePredicate fails) {
    assert(fails(world));
    OracleWorld best = world;
    oracle_lower_features(&best, fails);
    bool settled = false;
    for (int round = 0; round < 64; round++) {
        bool improved = false;
        if (oracle_lower_dimension(&best, OracleDimension.PREFIX, 0, fails)) improved = true;
        if (oracle_lower_dimension(&best, OracleDimension.FORWARD, 0, fails)) improved = true;
        if (oracle_lower_dimension(&best, OracleDimension.LOOP, 0, fails)) improved = true;
        if (oracle_lower_dimension(&best, OracleDimension.SUFFIX, 0, fails)) improved = true;
        if (oracle_lower_dimension(&best, OracleDimension.TRIPS, 1, fails)) improved = true;
        if (oracle_lower_dimension(&best, OracleDimension.PROC_COUNT, 0, fails)) improved = true;
        if (oracle_lower_dimension(&best, OracleDimension.PROC_CALLS, 0, fails)) improved = true;
        if (!improved) {
            settled = true;
            break;
        }
    }
    assert(settled);
    assert(fails(best));
    assert(best.seed == world.seed);
    return best;
}

fn bool oracle_synthetic_failure(OracleWorld world) {
    return world.prefix_ops >= 2;
}

fn int? oracle_shrink_selftest() {
    OracleWorld world = oracle_world(0x5A17);
    world.prefix_ops = 4;
    OracleWorld reduced = oracle_shrink(world, &oracle_synthetic_failure);
    if (!expect(reduced.prefix_ops == 2 && reduced.seed == world.seed,
            "deterministic shrink preserves failure and seed")) return 1;
    return 0;
}
