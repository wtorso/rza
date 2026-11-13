/* REZ3CHECK: bounded C23 checker for RZA IR invariants I1-I4. */
#include <assert.h>
#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAXF 256u
#define MAXC 1024u
#define MAXL 1024u
#define NAMESZ 64u
#define LINE_TEXT_MAX 511u
#define SOURCE_BYTES_MAX 1048576u
#define CASC_LINK_MAX 64u

typedef struct {
    char name[NAMESZ];
    int32_t parent;
    uint32_t gen;
    bool alive;
} Frame;
typedef struct { char name[NAMESZ]; int32_t frame; int32_t home; } Cell;
typedef struct {
    char name[NAMESZ];
    int32_t cell;
    int32_t owner;
    int32_t home;
    uint32_t gen;
    uint32_t home_gen;
} Link;

static Frame frames[MAXF];
static Cell cells[MAXC];
static Link links[MAXL];
static uint32_t nf;
static uint32_t nc;
static uint32_t nl;
static uint32_t g_gen = 1;
static uint32_t violations;
static uint32_t lineno;
static char source[SOURCE_BYTES_MAX + 1u];
static uint32_t source_len;

static int32_t run(FILE *input);
static bool read_source(FILE *input);
static void check_source(void);
static void check_line(char *line);
static void check_casc_line(char *line, bool async);
static void op_frame(char *name, char *parent);
static void op_cell(char *name, char *fname);
static void op_link(char *name, char *cname, char *issuer);
static void op_casc(char *name, char *list, char *outcell, char *outframe, bool async);
static void op_raise(char *cname, char *fname);
static void op_leave(char *fname);
static void op_probe(char *lname);
static void op_read(char *lname);

static_assert(MAXF > 0);
static_assert(MAXC > 0);
static_assert(MAXL > 0);
static_assert(NAMESZ == 64);
static_assert(LINE_TEXT_MAX + 1 == 512);
static_assert(SOURCE_BYTES_MAX > LINE_TEXT_MAX);

// Annex K сохраняет строгие clang/MSVC warnings без глобального CRT define.
static FILE *open_input(const char *path) {
    assert(path != nullptr);
#if defined(_WIN32)
    FILE *input = nullptr;
    if (fopen_s(&input, path, "rb") != 0) return nullptr;
    return input;
#else
    return fopen(path, "rb");
#endif
}

static void copy_text(char *dest, size_t cap, const char *src) {
    assert(dest != nullptr);
    assert(src != nullptr);
    assert(cap > 0);
#if defined(_WIN32)
    errno_t error = strcpy_s(dest, cap, src);
    assert(error == 0);
#else
    size_t length = strlen(src);
    assert(length < cap);
    memcpy(dest, src, length + 1);
#endif
}

#define COPY_TEXT(dest, src) copy_text(dest, sizeof(dest), src)

static int scan_casc(char *line, char *name, char *rest) {
#if defined(_WIN32)
    return sscanf_s(line, "%*s %63s %511[^\n]",
                    name, (unsigned)NAMESZ, rest, (unsigned)LINE_TEXT_MAX + 1u);
#else
    return sscanf(line, "%*s %63s %511[^\n]", name, rest);
#endif
}

static int scan_out(char *line, char *cell, char *frame, int *consumed) {
#if defined(_WIN32)
    return sscanf_s(line, "%63s %63s %n", cell, (unsigned)NAMESZ,
                    frame, (unsigned)NAMESZ, consumed);
#else
    return sscanf(line, "%63s %63s %n", cell, frame, consumed);
#endif
}

static int scan_command(char *line, char *command) {
#if defined(_WIN32)
    return sscanf_s(line, "%63s", command, (unsigned)NAMESZ);
#else
    return sscanf(line, "%63s", command);
#endif
}

int main(int argc, char **argv) {
    FILE *input = stdin;
    int32_t status;
    if (argc > 2) {
        fprintf(stderr, "usage: rez3check [file.rz3]\n");
        return 2;
    }
    if (argc == 2) {
        input = open_input(argv[1]);
        if (input == nullptr) {
            fprintf(stderr, "cannot open %s\n", argv[1]);
            return 2;
        }
    }
    status = run(input);
    if (argc == 2 && fclose(input) != 0) {
        fprintf(stderr, "cannot close %s\n", argv[1]);
        return 2;
    }
    return status;
}

static void report(const char *rule, const char *msg, const char *left, const char *right) {
    assert(rule != nullptr);
    assert(msg != nullptr);
    violations++;
    printf("VIOLATION line %u [%s]: %s %s %s\n",
           (unsigned)lineno, rule, msg, left, right);
}

static void warnx(const char *msg, const char *name) {
    assert(msg != nullptr);
    assert(name != nullptr);
    printf("warn      line %u: %s %s\n", (unsigned)lineno, msg, name);
}

static uint32_t next_gen(void) {
    assert(g_gen != 0);
    return g_gen++;
}

static int32_t find_frame(const char *name) {
    assert(name != nullptr);
    for (uint32_t index = 0; index < nf; index++) {
        if (strcmp(frames[index].name, name) == 0) return (int32_t)index;
    }
    return -1;
}

static int32_t find_cell(const char *name) {
    assert(name != nullptr);
    for (uint32_t index = 0; index < nc; index++) {
        if (strcmp(cells[index].name, name) == 0) return (int32_t)index;
    }
    return -1;
}

static int32_t find_link(const char *name) {
    assert(name != nullptr);
    for (uint32_t index = 0; index < nl; index++) {
        if (strcmp(links[index].name, name) == 0) return (int32_t)index;
    }
    return -1;
}

static bool is_ancestor(int32_t first, int32_t second, bool strict) {
    int32_t current;
    assert(first >= 0);
    assert((uint32_t)first < nf);
    assert(second >= 0);
    current = strict ? frames[first].parent : first;
    for (uint32_t steps = 0; steps < MAXF && current >= 0; steps++) {
        assert((uint32_t)current < nf);
        if (current == second) return true;
        current = frames[current].parent;
    }
    return false;
}

static bool link_alive(int32_t link_index) {
    int32_t owner;
    int32_t home;
    assert(link_index >= 0);
    assert((uint32_t)link_index < nl);
    owner = links[link_index].owner;
    home = links[link_index].home;
    assert(owner >= 0);
    assert((uint32_t)owner < nf);
    assert(home >= 0);
    assert((uint32_t)home < nf);
    if (!frames[owner].alive) return false;
    if (!frames[home].alive) return false;
    if (links[link_index].gen != frames[owner].gen) return false;
    return links[link_index].home_gen == frames[home].gen;
}

static void decay(int32_t frame_index) {
    assert(frame_index > 0);
    assert((uint32_t)frame_index < nf);
    frames[frame_index].gen = g_gen;
    if (g_gen != 0) g_gen++;
    frames[frame_index].alive = false;
    for (uint32_t index = (uint32_t)frame_index + 1; index < nf; index++) {
        int32_t parent = frames[index].parent;
        if (!frames[index].alive) continue;
        assert(parent >= 0);
        assert((uint32_t)parent < index);
        if (frames[parent].alive) continue;
        frames[index].gen = g_gen;
        if (g_gen != 0) g_gen++;
        frames[index].alive = false;
    }
}

static void op_frame(char *name, char *parent) {
    int32_t parent_index = 0;
    assert(name != nullptr);
    assert(parent != nullptr);
    if (find_frame(name) >= 0) {
        report("DUP", "duplicate frame", name, "");
        return;
    }
    if (strcmp(parent, "-") != 0) {
        parent_index = find_frame(parent);
        if (parent_index < 0) {
            report("I1", "unknown parent frame", parent, "");
            return;
        }
        if (!frames[parent_index].alive) {
            report("I1", "enter under dead frame", parent, "");
            return;
        }
    }
    if (nf >= MAXF) {
        report("LIMIT", "frames", name, "");
        return;
    }
    if (g_gen == 0) {
        report("LIMIT", "generation exhausted", name, "");
        return;
    }
    COPY_TEXT(frames[nf].name, name);
    frames[nf].parent = parent_index;
    frames[nf].gen = next_gen();
    frames[nf].alive = true;
    nf++;
}

static void op_cell(char *name, char *fname) {
    int32_t frame_index;
    assert(name != nullptr);
    assert(fname != nullptr);
    frame_index = find_frame(fname);
    if (frame_index < 0) {
        report("I1", "cell in unknown frame", name, fname);
        return;
    }
    if (!frames[frame_index].alive) {
        report("I1", "cell in dead frame", name, fname);
        return;
    }
    if (nc >= MAXC) {
        report("LIMIT", "cells", name, "");
        return;
    }
    COPY_TEXT(cells[nc].name, name);
    cells[nc].frame = frame_index;
    cells[nc].home = frame_index;
    nc++;
}

static void op_link(char *name, char *cname, char *issuer) {
    int32_t cell_index;
    int32_t issuer_index;
    assert(name != nullptr);
    assert(cname != nullptr);
    cell_index = find_cell(cname);
    if (cell_index < 0) {
        report("I2", "link to unknown cell", name, cname);
        return;
    }
    issuer_index = find_frame(issuer);
    if (issuer_index < 0) {
        report("I2", "unknown issuer frame", issuer, "");
        return;
    }
    if (!is_ancestor(cells[cell_index].frame, issuer_index, false)) {
        report("I2", "link issued by non-owner non-ancestor", issuer, cname);
        return;
    }
    if (nl >= MAXL) {
        report("LIMIT", "links", name, "");
        return;
    }
    COPY_TEXT(links[nl].name, name);
    links[nl].cell = cell_index;
    links[nl].owner = cells[cell_index].frame;
    links[nl].home = cells[cell_index].home;
    links[nl].gen = frames[links[nl].owner].gen;
    links[nl].home_gen = frames[links[nl].home].gen;
    nl++;
}

static char *trim(char *text) {
    char *end;
    assert(text != nullptr);
    while (isspace((unsigned char)*text) != 0) text++;
    end = text + strlen(text);
    while (end > text && isspace((unsigned char)end[-1]) != 0) end--;
    *end = '\0';
    return text;
}

static void check_casc_link(char *name, char *token, bool async) {
    int32_t link_index;
    assert(name != nullptr);
    assert(token != nullptr);
    link_index = find_link(token);
    if (link_index < 0) {
        report("I3", "cascade uses unknown link", name, token);
        return;
    }
    if (async) {
        int32_t frame_index = cells[links[link_index].cell].home;
        if (frame_index != 0) report("I3", "async cascade holds non-root link", name, token);
        return;
    }
    if (!link_alive(link_index)) {
        report("I3", "sync cascade aborted: dead link on entry", name, token);
    }
}

static void op_casc(char *name, char *list, char *outcell, char *outframe, bool async) {
    char buffer[LINE_TEXT_MAX + 1u];
    char *cursor;
    uint32_t count = 0;
    assert(name != nullptr);
    assert(list != nullptr);
    assert(strlen(list) <= LINE_TEXT_MAX);
    COPY_TEXT(buffer, list);
    cursor = buffer;
    for (;;) {
        char *comma = strchr(cursor, ',');
        char *token;
        if (comma != nullptr) *comma = '\0';
        token = trim(cursor);
        if (*token == '\0') {
            report("STRUCT", "empty cascade link", name, "");
            return;
        }
        if (count >= CASC_LINK_MAX) {
            report("LIMIT", "cascade links", name, "");
            return;
        }
        check_casc_link(name, token, async);
        count++;
        if (comma == nullptr) break;
        cursor = comma + 1;
    }
    assert(count > 0);
    if (async) {
        op_cell(outcell, "field");
        return;
    }
    if (find_frame(outframe) < 0) {
        report("I3", "out cell in unknown frame", outcell, outframe);
        return;
    }
    op_cell(outcell, outframe);
}

static void op_raise(char *cname, char *fname) {
    int32_t cell_index;
    int32_t frame_index;
    assert(cname != nullptr);
    assert(fname != nullptr);
    cell_index = find_cell(cname);
    if (cell_index < 0) {
        report("I4", "raise of unknown cell", cname, "");
        return;
    }
    frame_index = find_frame(fname);
    if (frame_index < 0) {
        report("I4", "raise to unknown frame", cname, fname);
        return;
    }
    if (!is_ancestor(cells[cell_index].frame, frame_index, true)) {
        report("I4", "raise to non-ancestor (sideways/down forbidden)", cname, fname);
        return;
    }
    if (!frames[frame_index].alive) {
        report("I4", "raise into dead frame", cname, fname);
        return;
    }
    if (!frames[cells[cell_index].frame].alive) {
        report("I4", "raise of cell in dead frame", cname,
               frames[cells[cell_index].frame].name);
        return;
    }
    cells[cell_index].frame = frame_index;
}

static void op_leave(char *fname) {
    int32_t frame_index;
    assert(fname != nullptr);
    frame_index = find_frame(fname);
    if (frame_index < 0) {
        report("DECAY", "leave of unknown frame", fname, "");
        return;
    }
    if (!frames[frame_index].alive) {
        report("DECAY", "double leave", fname, "");
        return;
    }
    if (frame_index == 0) {
        report("DECAY", "leave of root (field) forbidden", fname, "");
        return;
    }
    decay(frame_index);
}

static void op_probe(char *lname) {
    int32_t link_index;
    assert(lname != nullptr);
    link_index = find_link(lname);
    if (link_index < 0) {
        warnx("probe of unknown link", lname);
        return;
    }
    printf("probe     line %u: %s -> %s\n", (unsigned)lineno, lname,
           link_alive(link_index) ? "ALIVE" : "DEAD (no-op + log)");
}

static void op_read(char *lname) {
    int32_t link_index;
    assert(lname != nullptr);
    link_index = find_link(lname);
    if (link_index < 0) {
        warnx("read of unknown link", lname);
        return;
    }
    if (link_alive(link_index)) {
        printf("read      line %u: %s -> OK\n", (unsigned)lineno, lname);
        return;
    }
    warnx("read through dead link (would be fault DeadMediator)", lname);
}

static bool trailing_space(const char *text) {
    assert(text != nullptr);
    while (*text != '\0') {
        if (isspace((unsigned char)*text) == 0) return false;
        text++;
    }
    return true;
}

static void malformed(void) {
    report("STRUCT", "malformed operation", "", "");
}

static void check_casc_line(char *line, bool async) {
    char name[NAMESZ];
    char rest[LINE_TEXT_MAX + 1u];
    char outcell[NAMESZ];
    char outframe[NAMESZ];
    char *gt;
    int consumed = 0;
    int fields;
    assert(line != nullptr);
    outframe[0] = '\0';
    if (scan_casc(line, name, rest) != 2) {
        malformed();
        return;
    }
    gt = strchr(rest, '>');
    if (gt == nullptr) {
        malformed();
        return;
    }
    *gt = '\0';
    fields = scan_out(gt + 1, outcell, outframe, &consumed);
    if ((!async && fields != 2) || (async && fields != 1)) {
        malformed();
        return;
    }
    if (consumed == 0 || !trailing_space(gt + 1 + consumed)) {
        malformed();
        return;
    }
    op_casc(name, rest, outcell, outframe, async);
}

static uint32_t split_tokens(char *line, char **tokens, uint32_t capacity) {
    char *cursor = line;
    uint32_t count = 0;
    assert(line != nullptr);
    assert(tokens != nullptr);
    assert(capacity > 0);
    for (uint32_t steps = 0; steps < LINE_TEXT_MAX; steps++) {
        while (isspace((unsigned char)*cursor) != 0) cursor++;
        if (*cursor == '\0') break;
        if (count < capacity) tokens[count] = cursor;
        count++;
        while (*cursor != '\0' && isspace((unsigned char)*cursor) == 0) cursor++;
        if (*cursor == '\0') break;
        *cursor = '\0';
        cursor++;
    }
    assert(*cursor == '\0');
    return count;
}

static bool operands_valid(char **tokens, uint32_t count, uint32_t expected) {
    assert(tokens != nullptr);
    assert(expected > 0);
    if (count != expected + 1) return false;
    for (uint32_t index = 1; index < count; index++) {
        if (strlen(tokens[index]) >= NAMESZ) return false;
    }
    return true;
}

static bool await_register_valid(char *token) {
    int32_t value = 0;
    assert(token != nullptr);
    if (token[0] != '%' || token[1] != 'r' || token[2] == '\0') return false;
    for (uint32_t i = 2; token[i] != '\0'; i++) {
        if (!isdigit((unsigned char)token[i])) return false;
        value = value * 10 + (token[i] - '0');
        if (value > 15) return false;
    }
    return true;
}

static void check_line(char *line) {
    char command[NAMESZ];
    char *tokens[4];
    char *comment;
    uint32_t count;
    assert(line != nullptr);
    comment = strchr(line, '#');
    if (comment != nullptr) *comment = '\0';
    if (scan_command(line, command) != 1) return;
    if (strcmp(command, "casc") == 0 || strcmp(command, "acasc") == 0) {
        check_casc_line(line, command[0] == 'a');
        return;
    }
    count = split_tokens(line, tokens, 4);
    assert(count > 0);
    if (strcmp(command, "frame") == 0) {
        if (!operands_valid(tokens, count, 2)) malformed();
        else op_frame(tokens[1], tokens[2]);
        return;
    }
    if (strcmp(command, "cell") == 0) {
        if (!operands_valid(tokens, count, 2)) malformed();
        else op_cell(tokens[1], tokens[2]);
        return;
    }
    if (strcmp(command, "link") == 0) {
        if (!operands_valid(tokens, count, 3)) malformed();
        else op_link(tokens[1], tokens[2], tokens[3]);
        return;
    }
    if (strcmp(command, "raise") == 0) {
        if (!operands_valid(tokens, count, 2)) malformed();
        else op_raise(tokens[1], tokens[2]);
        return;
    }
    if (strcmp(command, "leave") == 0) {
        if (!operands_valid(tokens, count, 1)) malformed();
        else op_leave(tokens[1]);
        return;
    }
    if (strcmp(command, "probe") == 0) {
        if (!operands_valid(tokens, count, 1)) malformed();
        else op_probe(tokens[1]);
        return;
    }
    if (strcmp(command, "read") == 0) {
        if (!operands_valid(tokens, count, 1)) malformed();
        else op_read(tokens[1]);
        return;
    }
    if (strcmp(command, "await") == 0) {
        if (!operands_valid(tokens, count, 1) || !await_register_valid(tokens[1])) {
            malformed();
        }
        return;
    }
    warnx("unknown op", command);
}

static bool read_source(FILE *input) {
    size_t count;
    assert(input != nullptr);
    count = fread(source, 1, SOURCE_BYTES_MAX + 1u, input);
    if (ferror(input) != 0) {
        fprintf(stderr, "cannot read input\n");
        return false;
    }
    if (count > SOURCE_BYTES_MAX) {
        report("LIMIT", "source bytes", "", "");
        source_len = 0;
        return true;
    }
    if (memchr(source, '\0', count) != nullptr) {
        report("STRUCT", "NUL in source", "", "");
        source_len = 0;
        return true;
    }
    source[count] = '\0';
    source_len = (uint32_t)count;
    assert(source_len <= SOURCE_BYTES_MAX);
    return true;
}

static void check_source(void) {
    uint32_t offset = 0;
    COPY_TEXT(frames[0].name, "field");
    frames[0].parent = -1;
    frames[0].gen = next_gen();
    frames[0].alive = true;
    nf = 1;
    while (offset < source_len) {
        uint32_t end = offset;
        uint32_t length;
        while (end < source_len && source[end] != '\n') end++;
        length = end - offset;
        lineno++;
        if (length > LINE_TEXT_MAX) {
            report("STRUCT", "line too long", "", "");
        } else {
            source[end] = '\0';
            if (length > 0 && source[end - 1] == '\r') source[end - 1] = '\0';
            check_line(&source[offset]);
        }
        assert(end <= source_len);
        offset = end < source_len ? end + 1 : source_len;
    }
}

static int32_t run(FILE *input) {
    if (!read_source(input)) return 2;
    check_source();
    printf("---\nframes=%u cells=%u links=%u violations=%u\n",
           (unsigned)nf, (unsigned)nc, (unsigned)nl, (unsigned)violations);
    return violations != 0 ? 1 : 0;
}
