/* ============================================================================
 * REZ3CHECK — чекер инвариантов I1–I4 для RESONANCE-3 (C89, без зависимостей)
 *
 * Вход: строчный IR, одна операция на строку:
 *   frame  NAME PARENT          — enter; PARENT = '-' означает корень (field)
 *   cell   NAME FRAME           — resonator: опора в рамке FRAME        (I1)
 *   link   NAME CELL ISSUER     — mediator: выдача прохода рамкой ISSUER (I2)
 *   casc   NAME L1,L2 > CELL FRAME — sync-каскад: все связи живы на входе(I3)
 *   acasc  NAME L1,L2 > CELL    — async-каскад: связи только в корень    (I3)
 *   raise  CELL FRAME           — подъём опоры: FRAME — строгий предок   (I4)
 *   leave  FRAME                — Decay: gen++, рамка и поддерево мертвы
 *   probe  LINK                 — alive? мягкая семантика (намерение)
 *   read   LINK                 — жёсткое чтение: DEAD = предупреждение
 *   # комментарий; пустые строки пропускаются
 *
 * Выход: список нарушений с номером строки и правилом. Exit code =
 * число нарушений (0 — программа легальна). Проверка — один проход, O(n).
 * ============================================================================
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define MAXF 256   /* рамок   */
#define MAXC 1024  /* ячеек   */
#define MAXL 1024  /* связей  */
#define MAXS 256   /* каскадов */
#define NAMESZ 64

typedef struct { char name[NAMESZ]; int parent; unsigned gen; int alive; } Frame;
typedef struct { char name[NAMESZ]; int frame; } Cell;
typedef struct { char name[NAMESZ]; int cell; unsigned gen; } Link;

static Frame  frames[MAXF]; static int nf = 0;
static Cell   cells [MAXC]; static int nc = 0;
static Link   links [MAXL]; static int nl = 0;
static unsigned g_gen = 1;          /* глобальный монотонный счётчик имён   */
static int violations = 0;
static int lineno = 0;

static unsigned next_gen(void) { return g_gen++; }

/* --- поиск по имени ------------------------------------------------------- */
static int find_frame(const char *n) {
    int i; for (i = 0; i < nf; i++) if (!strcmp(frames[i].name, n)) return i;
    return -1;
}
static int find_cell(const char *n) {
    int i; for (i = 0; i < nc; i++) if (!strcmp(cells[i].name, n)) return i;
    return -1;
}
static int find_link(const char *n) {
    int i; for (i = 0; i < nl; i++) if (!strcmp(links[i].name, n)) return i;
    return -1;
}

/* f2 — предок f1? (или та же рамка, если strict == 0) */
static int is_ancestor(int f1, int f2, int strict) {
    int cur = strict ? frames[f1].parent : f1;
    while (cur >= 0) {
        if (cur == f2) return 1;
        cur = frames[cur].parent;
    }
    return 0;
}

/* связь жива? — поколение связи совпадает с поколением рамки ячейки */
static int link_alive(int li) {
    int fr = cells[links[li].cell].frame;
    return frames[fr].alive && links[li].gen == frames[fr].gen;
}

static void report(const char *rule, const char *msg, const char *a, const char *b) {
    violations++;
    printf("VIOLATION line %d [%s]: %s %s %s\n", lineno, rule, msg, a, b);
}
static void warnx(const char *msg, const char *a) {
    printf("warn      line %d: %s %s\n", lineno, msg, a);
}

/* --- Decay: рамка + всё поддерево умирают одним переходом ----------------- */
static void decay(int f) {
    int i;
    frames[f].gen = next_gen();   /* все выданные связи мертвы (ABA закрыт) */
    frames[f].alive = 0;
    for (i = 0; i < nf; i++)
        if (frames[i].alive && frames[i].parent == f) decay(i);
}

/* --- операции ------------------------------------------------------------- */
static void op_frame(char *name, char *parent) {
    int p = 0;                 /* '-' = прямой ребёнок field */
    if (find_frame(name) >= 0) { report("DUP", "duplicate frame", name, ""); return; }
    if (strcmp(parent, "-")) {
        p = find_frame(parent);
        if (p < 0)               { report("I1", "unknown parent frame", parent, ""); return; }
        if (!frames[p].alive)    { report("I1", "enter under dead frame", parent, ""); return; }
    }
    if (nf >= MAXF) { report("LIMIT", "frames", name, ""); return; }
    strcpy(frames[nf].name, name);
    frames[nf].parent = p;
    frames[nf].gen = next_gen();
    frames[nf].alive = 1;
    nf++;
}

static void op_cell(char *name, char *fname) {
    int f = find_frame(fname);
    if (f < 0)            { report("I1", "cell in unknown frame", name, fname); return; }
    if (!frames[f].alive) { report("I1", "cell in dead frame", name, fname); return; }
    if (nc >= MAXC) { report("LIMIT", "cells", name, ""); return; }
    strcpy(cells[nc].name, name); cells[nc].frame = f; nc++;
}

static void op_link(char *name, char *cname, char *issuer) {
    int c = find_cell(cname), is;
    if (c < 0) { report("I2", "link to unknown cell", name, cname); return; }
    is = find_frame(issuer);
    if (is < 0) { report("I2", "unknown issuer frame", issuer, ""); return; }
    /* I2: выдаёт владелец ячейки или его предок */
    if (!is_ancestor(cells[c].frame, is, 0)) {
        report("I2", "link issued by non-owner non-ancestor", issuer, cname);
        return;
    }
    if (nl >= MAXL) { report("LIMIT", "links", name, ""); return; }
    strcpy(links[nl].name, name);
    links[nl].cell = c;
    links[nl].gen = frames[cells[c].frame].gen;
    nl++;
}

static void op_casc(char *name, char *list, char *outcell, char *outframe, int async) {
    char buf[512]; char *tok; int of; char *e;
    strcpy(buf, list);
    tok = strtok(buf, ",");
    while (tok) {
        int li;
        while (*tok == ' ' || *tok == '\t') tok++;          /* trim left  */
        e = tok + strlen(tok);
        while (e > tok && (e[-1]==' '||e[-1]=='\t')) --e;   /* trim right */
        *e = 0;
        li = find_link(tok);
        if (li < 0) { report("I3", "cascade uses unknown link", name, tok); }
        else if (async) {
            /* async: связь обязана указывать в ячейку САМОГО field (index 0) */
            int fr = cells[links[li].cell].frame;
            if (fr != 0)
                report("I3", "async cascade holds non-root link", name, tok);
        } else {
            /* sync: все связи живы на входе — одна проверка на границе */
            if (!link_alive(li))
                report("I3", "sync cascade aborted: dead link on entry", name, tok);
        }
        tok = strtok(NULL, ",");
    }
    /* out-ячейка (названный потребитель): async — обязана быть в корне */
    if (async) {
        op_cell(outcell, "field");
    } else {
        of = find_frame(outframe);
        if (of < 0) { report("I3", "out cell in unknown frame", outcell, outframe); return; }
        op_cell(outcell, outframe);
    }
}

static void op_raise(char *cname, char *fname) {
    int c = find_cell(cname), f;
    if (c < 0) { report("I4", "raise of unknown cell", cname, ""); return; }
    f = find_frame(fname);
    if (f < 0) { report("I4", "raise to unknown frame", fname, ""); return; }
    /* I4: подъём — только вверх, строгий предок */
    if (!is_ancestor(cells[c].frame, f, 1)) {
        report("I4", "raise to non-ancestor (sideways/down forbidden)", cname, fname);
        return;
    }
    if (!frames[f].alive) { report("I4", "raise into dead frame", cname, fname); return; }
    cells[c].frame = f;   /* опора переприбита; старые связи на неё мертвы,
                             т.к. проверка идёт по поколению рамки-владельца */
}

static void op_leave(char *fname) {
    int f = find_frame(fname);
    if (f < 0)            { report("DECAY", "leave of unknown frame", fname, ""); return; }
    if (!frames[f].alive) { report("DECAY", "double leave", fname, ""); return; }
    if (f == 0)           { report("DECAY", "leave of root (field) forbidden", fname, ""); return; }
    decay(f);
}

static void op_probe(char *lname) {
    int li = find_link(lname);
    if (li < 0) { warnx("probe of unknown link", lname); return; }
    printf("probe     line %d: %s -> %s\n", lineno, lname,
           link_alive(li) ? "ALIVE" : "DEAD (no-op + log)");
}

static void op_read(char *lname) {
    int li = find_link(lname);
    if (li < 0) { warnx("read of unknown link", lname); return; }
    if (link_alive(li)) printf("read      line %d: %s -> OK\n", lineno, lname);
    else warnx("read through dead link (would be fault DeadMediator)", lname);
}

/* --- драйвер: один проход по строкам -------------------------------------- */
static void check_line(char *line) {
    char cmd[NAMESZ], a[NAMESZ], b[512], c[NAMESZ], d[NAMESZ];
    char *gt;
    a[0] = b[0] = c[0] = d[0] = 0;
    if (sscanf(line, "%63s", cmd) != 1) return;
    if (cmd[0] == '#') return;

    if (!strcmp(cmd, "frame")) {
        if (sscanf(line, "%*s %63s %63s", a, c) == 2) op_frame(a, c);
    } else if (!strcmp(cmd, "cell")) {
        if (sscanf(line, "%*s %63s %63s", a, c) == 2) op_cell(a, c);
    } else if (!strcmp(cmd, "link")) {
        if (sscanf(line, "%*s %63s %63s %63s", a, b, c) == 3) op_link(a, b, c);
    } else if (!strcmp(cmd, "casc") || !strcmp(cmd, "acasc")) {
        int async = (cmd[0] == 'a');
        /* формат: casc NAME L1,L2 > OUTCELL [FRAME] */
        if (sscanf(line, "%*s %63s %[^\n]", a, b) == 2) {
            gt = strchr(b, '>');
            if (gt) {
                *gt = 0;
                if (sscanf(gt + 1, "%63s %63s", c, d) >= 1)
                    op_casc(a, b, c, d, async);
            }
        }
    } else if (!strcmp(cmd, "raise")) {
        if (sscanf(line, "%*s %63s %63s", a, c) == 2) op_raise(a, c);
    } else if (!strcmp(cmd, "leave")) {
        if (sscanf(line, "%*s %63s", a) == 1) op_leave(a);
    } else if (!strcmp(cmd, "probe")) {
        if (sscanf(line, "%*s %63s", a) == 1) op_probe(a);
    } else if (!strcmp(cmd, "read")) {
        if (sscanf(line, "%*s %63s", a) == 1) op_read(a);
    } else {
        warnx("unknown op", cmd);
    }
}

int main(int argc, char **argv) {
    char line[512];
    FILE *f = stdin;
    if (argc > 1) {
        f = fopen(argv[1], "r");
        if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    }
    /* корень: field, бессмертен по определению (leave запрещён выше) */
    strcpy(frames[0].name, "field");
    frames[0].parent = -1; frames[0].gen = next_gen(); frames[0].alive = 1;
    nf = 1;

    while (fgets(line, sizeof line, f)) {
        lineno++;
        check_line(line);
    }
    if (argc > 1) fclose(f);

    printf("---\nframes=%d cells=%d links=%d violations=%d\n",
           nf, nc, nl, violations);
    return violations ? 1 : 0;
}
