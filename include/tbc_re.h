/* A native matcher for the regular expressions of a small, exactly defined subset, with a state cache that lives as long as the program.
 *
 * Why: Tcl's matcher builds the states of its DFA again for every match (`miss` and `getVacantSS` are 17% to 25% of the instructions of the JSON and tokenizer
 * programs), and cannot keep them between matches without changes to Tcl.  A matcher of our own can: its states are made as the input needs them and kept.
 *
 * Exactness: the pattern text is parsed here only as far as its structure goes (alternation, groups, quantifiers, the anchors at its ends).  Every atom that matches
 * one character (a literal, an escape, a bracket expression, `.`) is given to Tcl's own matcher, once for each of the characters 0 to 127, and the answer is what the
 * atom is.  The longest match from the leftmost start is what Tcl's matcher gives for an expression without non-greedy quantifiers (its choice is by preference, and the
 * only preference an expression of this subset can have is the longest), and what a DFA computes.
 *
 * The subset: literal ASCII characters, `.`, bracket expressions, the escapes \n \t \r \f \v and an escaped punctuation character, \d \D \s \S \w \W, non-capturing groups
 * (?:...), alternation, the greedy quantifiers * + ? {m} {m,} {m,n}, and an anchor at the start (\A or ^) and one at the end ($ or \Z) of the whole expression.  Not in it:
 * capturing groups, back references, lookahead, non-greedy quantifiers, embedded options, other escapes (\b \m \y \u \x ...), non-ASCII characters in the pattern, collating
 * elements, anchors elsewhere, an empty branch.  A pattern outside it is left to Tcl, and so is any call with another option than -indices, -start, --.
 *
 * Characters: the subject is a sequence of characters (Tcl's, so a character above U+007F is one symbol, OTHER).  An expression whose classes treat all of them alike
 * (a plain bracket expression, `.`, a negation) is matched on any subject; one with a class of Unicode (\d \s \w, [:alpha:] ...) only on a subject of ASCII characters
 * (needascii), since what those classes hold above U+007F is Tcl's table, not ours.
 *
 * Not thread safe, like the rest of the hook.  Memory is bounded: an expression of more than TBC_RE_MAXNODES nodes or TBC_RE_MAXDFA states is left to Tcl. */
#ifndef TBC_RE_H
#define TBC_RE_H
#include <ctype.h>

#define TBC_RE_OTHER 128
#define TBC_RE_NSYM 129
#define TBC_RE_MAXNODES 3000
#define TBC_RE_MAXSETS 300
#define TBC_RE_MAXDFA 300
#define TBC_RE_MAXREP 64

typedef struct { uint64_t w[3]; } tbc_reset;
TBC_INLINE int tbc_re_has(const tbc_reset *s, int c) { return (int) ((s->w[c >> 6] >> (c & 63)) & 1); }
TBC_INLINE void tbc_re_put(tbc_reset *s, int c) { s->w[c >> 6] |= (uint64_t) 1 << (c & 63); }

typedef struct { int kind, a, b, min, max; } tbc_rean;			/* 0 set (a: index), 1 concatenation (a b), 2 alternation (a b), 3 repetition of a */
typedef struct { unsigned char kind; int o1, o2, set; } tbc_renode;	/* 0 one character of a set, 1 either way, 2 match */

typedef struct tbc_re {
    int anchor_start;		/* 0 none, 1 \A, 2 ^ */
    int anchor_end;		/* 1: the match must end at the end of the subject */
    int needascii;		/* subjects of ASCII characters only */
    int nn, nodes_start;
    tbc_renode *nodes;
    int nsets;
    tbc_reset *sets;
    int ncls;
    unsigned char cls[TBC_RE_NSYM];
    unsigned char rep[TBC_RE_NSYM];	/* a symbol of each class */
    /* the DFA, made as it is needed */
    int nd, dcap, bad;
    int32_t *next;		/* nd * ncls: -1 not made yet, 0 the dead state, else a state */
    unsigned char *acc;
    int **dnodes;		/* the NFA nodes of each state (sorted, a SET or MATCH node each) */
    int *dcount;
    int *dtab, dtcap;		/* hash of states: index + 1, 0 empty */
    int s0;
    unsigned *mark; unsigned gen;
    int *stackbuf, *tmpbuf;
} tbc_re;

/* ---- the atoms: asked of Tcl's own matcher, once for each character, and kept ---- */
typedef struct { tbc_reset set; int uniform; } tbc_reatom;
static Tcl_HashTable tbc_re_atoms;
static int tbc_re_atoms_init;
/* the set of the characters (0..127, and OTHER for the characters above that) that one atom matches: 1, or 0 when the atom is not one of one character.  *uniform tells whether the
 * characters above U+007F that were tried agree (then OTHER is what they say); a class of Unicode does not, and is for subjects of ASCII characters only */
static int tbc_re_atomset(const char *atom, int len, tbc_reset *out, int *uniform) {
    static const int others[] = { 0x80, 0xA0, 0xE9, 0x100, 0x2003, 0x20AC, 0x3042, 0xD83D, 0xFFFF };
    Tcl_Obj *pat; Tcl_RegExp re; int c, first = 1, ov = 0, i, isnew, uni = 1, ok = 1;
    Tcl_HashEntry *h;
    tbc_reatom *ra;
    char *key;
    if (!tbc_re_atoms_init) { Tcl_InitHashTable(&tbc_re_atoms, TCL_STRING_KEYS); tbc_re_atoms_init = 1; }
    key = (char *) malloc((size_t) len + 1);
    if (!key) return 0;
    memcpy(key, atom, (size_t) len); key[len] = 0;
    h = Tcl_CreateHashEntry(&tbc_re_atoms, key, &isnew);
    free(key);
    if (!isnew) {
        ra = (tbc_reatom *) Tcl_GetHashValue(h);
        if (!ra) return 0;
        *out = ra->set; *uniform = ra->uniform;
        return 1;
    }
    Tcl_SetHashValue(h, NULL);
    {
        char *buf = (char *) malloc((size_t) len + 12);
        if (!buf) return 0;
        memcpy(buf, "\\A(?:", 5); memcpy(buf + 5, atom, (size_t) len); memcpy(buf + 5 + len, ")\\Z", 3);
        pat = Tcl_NewStringObj(buf, len + 8);
        free(buf);
    }
    Tcl_IncrRefCount(pat);
    re = Tcl_GetRegExpFromObj(NULL, pat, TCL_REG_ADVANCED);
    if (!re) { Tcl_DecrRefCount(pat); return 0; }
    memset(out, 0, sizeof *out);
    for (c = 0; c < 128; c++) {
        Tcl_UniChar u = (Tcl_UniChar) c;
        Tcl_Obj *s = Tcl_NewUnicodeObj(&u, 1);
        Tcl_IncrRefCount(s);
        if (Tcl_RegExpExecObj(NULL, re, s, 0, 0, 0) == 1) tbc_re_put(out, c);
        Tcl_DecrRefCount(s);
    }
    for (i = 0; i < (int) (sizeof others / sizeof others[0]); i++) {
        Tcl_UniChar u = (Tcl_UniChar) others[i];
        Tcl_Obj *s = Tcl_NewUnicodeObj(&u, 1);
        int m;
        Tcl_IncrRefCount(s);
        m = Tcl_RegExpExecObj(NULL, re, s, 0, 0, 0) == 1;
        Tcl_DecrRefCount(s);
        if (first) { ov = m; first = 0; } else if (m != ov) uni = 0;
    }
    /* (a string of two characters must not match: the atom is of one character) */
    {
        Tcl_UniChar u2[2] = { 'a', 'a' };
        Tcl_Obj *s = Tcl_NewUnicodeObj(u2, 2);
        Tcl_IncrRefCount(s);
        if (Tcl_RegExpExecObj(NULL, re, s, 0, 0, 0) != 0) ok = 0;
        Tcl_DecrRefCount(s);
    }
    Tcl_DecrRefCount(pat);
    if (!ok) return 0;
    if (uni && ov) tbc_re_put(out, TBC_RE_OTHER);
    ra = (tbc_reatom *) malloc(sizeof *ra);
    if (!ra) return 0;
    ra->set = *out; ra->uniform = uni;
    Tcl_SetHashValue(h, ra);
    *uniform = uni;
    return 1;
}

/* ---- the parser ---- */
typedef struct {
    const char *p; int n, i, fail;
    tbc_rean *an; int nan, can;
    tbc_reset *sets; int ns;
    int needascii, nodes;
} tbc_reparse;

static int tbc_re_node(tbc_reparse *ps, int kind, int a, int b, int mn, int mx) {
    if (ps->nan == ps->can) {
        int nc = ps->can ? ps->can * 2 : 64;
        tbc_rean *na = (tbc_rean *) realloc(ps->an, (size_t) nc * sizeof *na);
        if (!na) { ps->fail = 1; return 0; }
        ps->an = na; ps->can = nc;
    }
    ps->an[ps->nan].kind = kind; ps->an[ps->nan].a = a; ps->an[ps->nan].b = b; ps->an[ps->nan].min = mn; ps->an[ps->nan].max = mx;
    return ps->nan++;
}
static int tbc_re_setindex(tbc_reparse *ps, const tbc_reset *s) {
    int i;
    for (i = 0; i < ps->ns; i++) if (!memcmp(&ps->sets[i], s, sizeof *s)) return i;
    if (ps->ns >= TBC_RE_MAXSETS) { ps->fail = 1; return 0; }
    ps->sets[ps->ns] = *s;
    return ps->ns++;
}
/* uniclass: the atom is, or holds, a class of Unicode (the caller saw it): the characters above U+007F need not agree, and the pattern is for subjects of ASCII characters only */
static int tbc_re_atomnode(tbc_reparse *ps, const char *atom, int len, int uniclass) {
    tbc_reset s; int uniform = 1;
    if (!tbc_re_atomset(atom, len, &s, &uniform) || (!uniform && !uniclass)) { ps->fail = 1; return 0; }
    return tbc_re_node(ps, 0, tbc_re_setindex(ps, &s), 0, 0, 0);
}
static int tbc_re_alt(tbc_reparse *ps, int depth);
/* one atom followed by its quantifier */
static int tbc_re_piece(tbc_reparse *ps, int depth) {
    const char *p = ps->p; int n = ps->n, i = ps->i, a = 0, mn = 1, mx = 1;
    unsigned char c;
    if (i >= n) { ps->fail = 1; return 0; }
    c = (unsigned char) p[i];
    if (c == 0 || c >= 0x80) { ps->fail = 1; return 0; }
    if (c == '(') {
        if (i + 2 >= n || p[i + 1] != '?' || p[i + 2] != ':' || depth > 20) { ps->fail = 1; return 0; }
        ps->i = i + 3;
        a = tbc_re_alt(ps, depth + 1);
        if (ps->fail) return 0;
        if (ps->i >= n || p[ps->i] != ')') { ps->fail = 1; return 0; }
        ps->i++;
    } else if (c == '[') {
        int j = i + 1, buni = 0;
        if (j < n && p[j] == '^') j++;
        if (j < n && p[j] == ']') j++;
        for (;;) {
            if (j >= n) { ps->fail = 1; return 0; }
            if (p[j] == '\\') {
                unsigned char e;
                if (j + 1 >= n) { ps->fail = 1; return 0; }
                e = (unsigned char) p[j + 1];
                if (strchr("dDsSwW", e)) ps->needascii = buni = 1;
                else if (e >= 0x80 || (isalnum(e) && !strchr("ntrfv", e))) { ps->fail = 1; return 0; }
                j += 2; continue;
            }
            if (p[j] == '[' && j + 1 < n && (p[j + 1] == ':' || p[j + 1] == '.' || p[j + 1] == '=')) {
                int k = j + 2, st = j + 2;
                char kind = p[j + 1];
                while (k + 1 < n && !(p[k] == kind && p[k + 1] == ']')) k++;
                if (k + 1 >= n || kind != ':') { ps->fail = 1; return 0; }
                if (!((k - st == 6 && !strncmp(p + st, "xdigit", 6)) || (k - st == 5 && !strncmp(p + st, "blank", 5)) || (k - st == 5 && !strncmp(p + st, "ascii", 5)))) ps->needascii = buni = 1;
                j = k + 2; continue;
            }
            if (p[j] == ']') break;
            if ((unsigned char) p[j] >= 0x80 || p[j] == 0) { ps->fail = 1; return 0; }
            j++;
        }
        a = tbc_re_atomnode(ps, p + i, j - i + 1, buni);
        ps->i = j + 1;
    } else if (c == '\\') {
        unsigned char e;
        if (i + 1 >= n) { ps->fail = 1; return 0; }
        e = (unsigned char) p[i + 1];
        if (strchr("dDsSwW", e)) ps->needascii = 1;
        else if (!(strchr("ntrfv", e) || (e < 0x80 && e > 0 && !isalnum(e)))) { ps->fail = 1; return 0; }
        a = tbc_re_atomnode(ps, p + i, 2, strchr("dDsSwW", e) != NULL);
        ps->i = i + 2;
    } else if (c == '.') {
        a = tbc_re_atomnode(ps, p + i, 1, 0);
        ps->i = i + 1;
    } else if (strchr("*+?{|)^$", c)) {
        ps->fail = 1; return 0;
    } else {
        tbc_reset s;
        memset(&s, 0, sizeof s); tbc_re_put(&s, c);
        a = tbc_re_node(ps, 0, tbc_re_setindex(ps, &s), 0, 0, 0);
        ps->i = i + 1;
    }
    if (ps->fail) return 0;
    /* the quantifier */
    i = ps->i;
    if (i < n) {
        c = (unsigned char) p[i];
        if (c == '*') { mn = 0; mx = -1; i++; }
        else if (c == '+') { mn = 1; mx = -1; i++; }
        else if (c == '?') { mn = 0; mx = 1; i++; }
        else if (c == '{') {
            int m = 0, x = -1, d = 0;
            i++;
            while (i < n && isdigit((unsigned char) p[i]) && d < 4) { m = m * 10 + (p[i] - '0'); i++; d++; }
            if (!d) { ps->fail = 1; return 0; }
            if (i < n && p[i] == '}') { x = m; i++; }
            else if (i < n && p[i] == ',') {
                i++;
                d = 0; x = 0;
                while (i < n && isdigit((unsigned char) p[i]) && d < 4) { x = x * 10 + (p[i] - '0'); i++; d++; }
                if (!d) x = -1;
                if (i >= n || p[i] != '}') { ps->fail = 1; return 0; }
                i++;
            } else { ps->fail = 1; return 0; }
            if (m > TBC_RE_MAXREP || x > TBC_RE_MAXREP || (x >= 0 && x < m)) { ps->fail = 1; return 0; }
            mn = m; mx = x;
        }
        if (mn != 1 || mx != 1 || (i > ps->i)) {
            if (i < n && (p[i] == '?' || p[i] == '*' || p[i] == '+' || p[i] == '{')) { ps->fail = 1; return 0; }   /* non-greedy, or a second quantifier */
            ps->i = i;
            return tbc_re_node(ps, 3, a, 0, mn, mx);
        }
    }
    return a;
}
static int tbc_re_branch(tbc_reparse *ps, int depth) {
    int first = tbc_re_piece(ps, depth), cur;
    if (ps->fail) return 0;
    cur = first;
    while (ps->i < ps->n && ps->p[ps->i] != '|' && ps->p[ps->i] != ')') {
        int nx = tbc_re_piece(ps, depth);
        if (ps->fail) return 0;
        cur = tbc_re_node(ps, 1, cur, nx, 0, 0);
        if (ps->fail) return 0;
    }
    return cur;
}
static int tbc_re_alt(tbc_reparse *ps, int depth) {
    int left = tbc_re_branch(ps, depth);
    if (ps->fail) return 0;
    while (ps->i < ps->n && ps->p[ps->i] == '|') {
        int right;
        ps->i++;
        right = tbc_re_branch(ps, depth);
        if (ps->fail) return 0;
        left = tbc_re_node(ps, 2, left, right, 0, 0);
        if (ps->fail) return 0;
    }
    return left;
}

/* ---- the NFA: a fragment is made to go on at `next`, and its first node is returned ---- */
typedef struct { tbc_renode *nodes; int nn, cap, fail; } tbc_renfa;
static int tbc_re_nn(tbc_renfa *nf, int kind, int o1, int o2, int set) {
    if (nf->nn >= TBC_RE_MAXNODES) { nf->fail = 1; return 0; }
    if (nf->nn == nf->cap) {
        int nc = nf->cap ? nf->cap * 2 : 128;
        tbc_renode *nn = (tbc_renode *) realloc(nf->nodes, (size_t) nc * sizeof *nn);
        if (!nn) { nf->fail = 1; return 0; }
        nf->nodes = nn; nf->cap = nc;
    }
    nf->nodes[nf->nn].kind = (unsigned char) kind; nf->nodes[nf->nn].o1 = o1; nf->nodes[nf->nn].o2 = o2; nf->nodes[nf->nn].set = set;
    return nf->nn++;
}
static int tbc_re_emit(tbc_renfa *nf, const tbc_rean *an, int ix, int next) {
    const tbc_rean *a = &an[ix];
    int t, i;
    if (nf->fail) return 0;
    switch (a->kind) {
    case 0: return tbc_re_nn(nf, 0, next, 0, a->a);
    case 1: { int r = tbc_re_emit(nf, an, a->b, next); return tbc_re_emit(nf, an, a->a, r); }
    case 2: { int l = tbc_re_emit(nf, an, a->a, next), r = tbc_re_emit(nf, an, a->b, next); return tbc_re_nn(nf, 1, l, r, 0); }
    default:
        t = next;
        if (a->max < 0) {
            int loop = tbc_re_nn(nf, 1, 0, next, 0), body;
            if (nf->fail) return 0;
            body = tbc_re_emit(nf, an, a->a, loop);
            nf->nodes[loop].o1 = body;
            t = loop;
        } else {
            for (i = 0; i < a->max - a->min; i++) {
                int body = tbc_re_emit(nf, an, a->a, t);
                t = tbc_re_nn(nf, 1, body, next, 0);
                if (nf->fail) return 0;
            }
        }
        for (i = 0; i < a->min; i++) { t = tbc_re_emit(nf, an, a->a, t); if (nf->fail) return 0; }
        return t;
    }
}

/* ---- the DFA ---- */
static void tbc_re_free(tbc_re *re) {
    int i;
    if (!re) return;
    free(re->nodes); free(re->sets); free(re->next); free(re->acc); free(re->dcount); free(re->dtab); free(re->mark); free(re->stackbuf); free(re->tmpbuf);
    for (i = 0; i < re->nd; i++) free(re->dnodes ? re->dnodes[i] : NULL);
    free(re->dnodes);
    free(re);
}
/* the SET and MATCH nodes that the nodes in `in` lead to without a character, sorted, in out (a buffer of nn entries); the count.  A node is marked when it is put on the
 * stack, so that the stack never holds more than nn of them */
static int tbc_re_closure(tbc_re *re, const int *in, int nin, int *out) {
    int sp = 0, n = 0, i;
    int *stk = re->stackbuf;
    re->gen++;
    if (!re->gen) { memset(re->mark, 0, (size_t) re->nn * sizeof *re->mark); re->gen = 1; }
#define TBC_RE_PUSH(x) do { int x_ = (x); if (re->mark[x_] != re->gen) { re->mark[x_] = re->gen; stk[sp++] = x_; } } while (0)
    for (i = 0; i < nin; i++) TBC_RE_PUSH(in[i]);
    while (sp) {
        int x = stk[--sp];
        if (re->nodes[x].kind == 1) { TBC_RE_PUSH(re->nodes[x].o1); TBC_RE_PUSH(re->nodes[x].o2); }
        else out[n++] = x;
    }
#undef TBC_RE_PUSH
    for (i = 1; i < n; i++) { int v = out[i], j = i - 1; while (j >= 0 && out[j] > v) { out[j + 1] = out[j]; j--; } out[j + 1] = v; }
    return n;
}
static int tbc_re_dfind(tbc_re *re, const int *set, int n) {
    uint32_t h = 2166136261u;
    int i, pos;
    for (i = 0; i < n; i++) h = (h ^ (uint32_t) set[i]) * 16777619u;
    h ^= (uint32_t) n;
    pos = (int) (h & (uint32_t) (re->dtcap - 1));
    while (re->dtab[pos]) {
        int d = re->dtab[pos] - 1;
        if (re->dcount[d] == n && !memcmp(re->dnodes[d], set, (size_t) n * sizeof(int))) return d;
        pos = (pos + 1) & (re->dtcap - 1);
    }
    /* a new state */
    if (re->nd >= TBC_RE_MAXDFA) return -1;
    if (re->nd == re->dcap) {
        int nc = re->dcap ? re->dcap * 2 : 16, k;
        int32_t *nx = (int32_t *) realloc(re->next, (size_t) nc * (size_t) re->ncls * sizeof *nx);
        unsigned char *na = (unsigned char *) realloc(re->acc, (size_t) nc);
        int **nd = (int **) realloc(re->dnodes, (size_t) nc * sizeof *nd);
        int *ncn = (int *) realloc(re->dcount, (size_t) nc * sizeof *ncn);
        if (nx) re->next = nx; if (na) re->acc = na; if (nd) re->dnodes = nd; if (ncn) re->dcount = ncn;
        if (!nx || !na || !nd || !ncn) return -1;
        re->dcap = nc;
        for (k = re->nd * re->ncls; k < nc * re->ncls; k++) re->next[k] = -1;
    }
    {
        int d = re->nd, acc = 0, k;
        int *copy = (int *) malloc((size_t) (n ? n : 1) * sizeof(int));
        if (!copy) return -1;
        memcpy(copy, set, (size_t) n * sizeof(int));
        for (k = 0; k < n; k++) if (re->nodes[set[k]].kind == 2) acc = 1;
        re->dnodes[d] = copy; re->dcount[d] = n; re->acc[d] = (unsigned char) acc;
        for (k = 0; k < re->ncls; k++) re->next[d * re->ncls + k] = -1;
        re->nd++;
        re->dtab[pos] = d + 1;
        return d;
    }
}
/* the state after class k from state d: made and kept; -1 when memory or the limit gives out */
static int tbc_re_step(tbc_re *re, int d, int k) {
    int i, n = 0, r;
    int *tmp = re->tmpbuf, *out = re->tmpbuf + re->nn;
    int sym = re->rep[k];
    for (i = 0; i < re->dcount[d]; i++) {
        const tbc_renode *nd = &re->nodes[re->dnodes[d][i]];
        if (nd->kind == 0 && tbc_re_has(&re->sets[nd->set], sym)) tmp[n++] = nd->o1;
    }
    if (!n) r = 0;
    else {
        int m = tbc_re_closure(re, tmp, n, out);
        r = m ? tbc_re_dfind(re, out, m) : 0;
        if (r >= 0 && m) r += 1;      /* (state 0 is the dead state: the table's states are shifted by one) */
    }
    if (r < 0) return -1;
    re->next[d * re->ncls + k] = r;
    return r;
}

/* the classes of symbols: those that no set tells apart are one column of the table */
static void tbc_re_classes(tbc_re *re) {
    int c, d, k;
    re->ncls = 0;
    for (c = 0; c < TBC_RE_NSYM; c++) {
        for (k = 0; k < re->ncls; k++) {
            int same = 1;
            for (d = 0; d < re->nsets && same; d++) if (tbc_re_has(&re->sets[d], c) != tbc_re_has(&re->sets[d], re->rep[k])) same = 0;
            if (same) break;
        }
        if (k == re->ncls) { re->rep[k] = (unsigned char) c; re->ncls++; }
        re->cls[c] = (unsigned char) k;
    }
}
/* a compiled expression for the pattern, or NULL when it is outside the subset (or its size is) */
static tbc_re *tbc_re_compile(const char *pat, int len) {
    tbc_reparse ps; tbc_renfa nf; tbc_re *re = NULL;
    int root, anchor_start = 0, anchor_end = 0, i, matchnode, startnode, bodylen;
    const char *body;
    memset(&ps, 0, sizeof ps); memset(&nf, 0, sizeof nf);
    body = pat; bodylen = len;
    if (len >= 2 && pat[0] == '\\' && pat[1] == 'A') { anchor_start = 1; body += 2; bodylen -= 2; }
    else if (len >= 1 && pat[0] == '^') { anchor_start = 2; body += 1; bodylen -= 1; }
    if (bodylen >= 2 && body[bodylen - 2] == '\\' && body[bodylen - 1] == 'Z') {
        int bs = 0, k = bodylen - 3;
        while (k >= 0 && body[k] == '\\') { bs++; k--; }
        if (!(bs & 1)) { anchor_end = 1; bodylen -= 2; }
    } else if (bodylen >= 1 && body[bodylen - 1] == '$') {
        int bs = 0, k = bodylen - 2;
        while (k >= 0 && body[k] == '\\') { bs++; k--; }
        if (!(bs & 1)) { anchor_end = 1; bodylen -= 1; }
    }
    if (bodylen < 1) return NULL;
    ps.p = body; ps.n = bodylen; ps.i = 0;
    ps.sets = (tbc_reset *) malloc(TBC_RE_MAXSETS * sizeof(tbc_reset));
    if (!ps.sets) return NULL;
    root = tbc_re_alt(&ps, 0);
    if (ps.fail || ps.i != ps.n || (ps.an[root].kind == 2 && (anchor_start || anchor_end))) { free(ps.an); free(ps.sets); return NULL; }
    matchnode = tbc_re_nn(&nf, 2, 0, 0, 0);
    startnode = tbc_re_emit(&nf, ps.an, root, matchnode);
    if (nf.fail) { free(nf.nodes); free(ps.an); free(ps.sets); return NULL; }
    re = (tbc_re *) calloc(1, sizeof *re);
    if (!re) { free(nf.nodes); free(ps.an); free(ps.sets); return NULL; }
    re->anchor_start = anchor_start; re->anchor_end = anchor_end; re->needascii = ps.needascii;
    re->nodes = nf.nodes; re->nn = nf.nn; re->nodes_start = startnode;
    re->sets = ps.sets; re->nsets = ps.ns;
    free(ps.an);
    tbc_re_classes(re);
    re->mark = (unsigned *) calloc((size_t) re->nn, sizeof(unsigned));
    re->stackbuf = (int *) malloc((size_t) re->nn * sizeof(int) + 8);
    re->tmpbuf = (int *) malloc(2 * (size_t) re->nn * sizeof(int) + 8);
    re->dtcap = 1024;
    re->dtab = (int *) calloc((size_t) re->dtcap, sizeof(int));
    if (!re->mark || !re->stackbuf || !re->tmpbuf || !re->dtab) { tbc_re_free(re); return NULL; }
    {
        int in = startnode, m, *out = re->tmpbuf + re->nn;
        m = tbc_re_closure(re, &in, 1, out);
        re->s0 = m ? tbc_re_dfind(re, out, m) : -1;
        if (re->s0 < 0) { tbc_re_free(re); return NULL; }
    }
    (void) i;
    return re;
}

/* ---- matching: the leftmost longest match at or after `from`.  1 and [*ms, *me), 0 no match, -1 gave up (state limit or memory; the caller asks Tcl) ---- */
#define TBC_RE_EXEC(NAME, CHAR) \
static int NAME(tbc_re *re, const CHAR *s, int n, int from, int caretok, int *ms, int *me) { \
    int st, p; \
    int ncls = re->ncls; \
    if (re->bad) return -1; \
    for (st = from; st <= n; st++) { \
        int d, last = -1; \
        if (re->anchor_start && st != from) break; \
        if (re->anchor_start == 2 && !caretok) break; \
        d = re->s0; \
        if (re->acc[d] && (!re->anchor_end || st == n)) last = st; \
        for (p = st; p < n; p++) { \
            unsigned c = (unsigned) s[p]; \
            int k = re->cls[c < 128 ? c : TBC_RE_OTHER]; \
            int v = re->next[d * ncls + k]; \
            if (v < 0) { v = tbc_re_step(re, d, k); if (v < 0) { re->bad = 1; return -1; } } \
            if (v == 0) break; \
            d = v - 1; \
            if (re->acc[d] && (!re->anchor_end || p + 1 == n)) last = p + 1; \
        } \
        if (last >= 0) { *ms = st; *me = last; return 1; } \
    } \
    return 0; \
}
TBC_RE_EXEC(tbc_re_exec8, unsigned char)
TBC_RE_EXEC(tbc_re_exec16, Tcl_UniChar)

/* ---- the expressions that were made, by pattern text; a pattern outside the subset is remembered too (a NULL) ---- */
static Tcl_HashTable tbc_re_cache;
static int tbc_re_cache_init;
static tbc_re *tbc_re_get(const char *pat, int len) {
    Tcl_HashEntry *h; int isnew; char *key; tbc_re *re;
    if (!tbc_re_cache_init) { Tcl_InitHashTable(&tbc_re_cache, TCL_STRING_KEYS); tbc_re_cache_init = 1; }
    if (len > 400) return NULL;
    key = (char *) malloc((size_t) len + 1);
    if (!key) return NULL;
    memcpy(key, pat, (size_t) len); key[len] = 0;
    h = Tcl_CreateHashEntry(&tbc_re_cache, key, &isnew);
    free(key);
    if (!isnew) return (tbc_re *) Tcl_GetHashValue(h);
    re = tbc_re_compile(pat, len);
    Tcl_SetHashValue(h, re);
    return re;
}

/* ---- the glue ---- */
#define TBC_RE_PASS (-100)
/* the subject, read the way Tcl's matcher reads it: its characters */
typedef struct { const char *s8; const Tcl_UniChar *s16; int len; } tbc_resubj;
/* 1 when the subject can be matched by this expression (an object of ASCII characters, or any when the classes of the expression do not tell the other characters apart) */
static int tbc_re_subject(const tbc_re *re, Tcl_Obj *subj, tbc_resubj *sj) {
    sj->len = 0; sj->s16 = NULL;
    sj->s8 = tbc_ascii(subj, &sj->len);
    if (!sj->s8) {
        if (re->needascii) return 0;
        sj->s16 = Tcl_GetUnicodeFromObj(subj, &sj->len);
        if (!sj->s16 && sj->len) return 0;
    }
    return 1;
}
/* one search from `offset` (Tcl's rule for ^: at the start, or after a newline when offset > 0): 1 with [*ms, *me), 0, or TBC_RE_PASS */
static int tbc_re_find(tbc_re *re, const tbc_resubj *sj, int offset, int *ms, int *me) {
    int caretok = offset == 0 || (sj->s8 ? sj->s8[offset - 1] : (int) sj->s16[offset - 1]) == '\n';
    int r = sj->s8 ? tbc_re_exec8(re, (const unsigned char *) sj->s8, sj->len, offset, caretok, ms, me) : tbc_re_exec16(re, sj->s16, sj->len, offset, caretok, ms, me);
    return r < 0 ? TBC_RE_PASS : r;
}
/* Does the pattern match the subject from -start on (hasstart: the value in startObj)?  1 with [*ms, *me) in characters, 0, or TBC_RE_PASS for whatever this matcher does not take:
 * the caller then asks Tcl, which has not been touched. */
static int tbc_re_search(Tcl_Obj *patObj, Tcl_Obj *subj, int hasstart, Tcl_Obj *startObj, int *ms, int *me, int *off) {
    const char *pat; int plen, offset = 0;
    tbc_re *re; tbc_resubj sj;
    pat = Tcl_GetStringFromObj(patObj, &plen);
    re = tbc_re_get(pat, plen);
    if (!re || !tbc_re_subject(re, subj, &sj)) return TBC_RE_PASS;
    if (hasstart) {
        Tcl_WideInt w;
        if (Tcl_GetWideIntFromObj(NULL, startObj, &w) != TCL_OK) return TBC_RE_PASS;
        if (w < 0) offset = 0; else if (w > sj.len) return TBC_RE_PASS; else offset = (int) w;
    }
    *off = offset;
    return tbc_re_find(re, &sj, offset, ms, me);
}
/* `regexp ?-all? ?-inline? ?-indices? ?-start n? ?--? exp string ?matchVar?` for what the matcher takes, as Tcl_RegexpObjCmd does it (tclCmdMZ.c), and TBC_RE_PASS for the rest */
static int tbc_regexp_fast(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int i, indices = 0, hasstart = 0, all = 0, doinline = 0, ms = 0, me = 0, offset = 0, rest, plen;
    Tcl_Obj *startObj = NULL, *resultPtr = NULL;
    tbc_re *re; tbc_resubj sj; const char *pat;
    (void) cd;
    for (i = 1; i < objc; i++) {
        const char *w = Tcl_GetString(objv[i]);
        if (w[0] != '-') break;
        if (!strcmp(w, "-indices")) indices = 1;
        else if (!strcmp(w, "-all")) all = 1;
        else if (!strcmp(w, "-inline")) doinline = 1;
        else if (!strcmp(w, "-start")) { if (++i >= objc) return TBC_RE_PASS; hasstart = 1; startObj = objv[i]; }
        else if (!strcmp(w, "--")) { i++; break; }
        else return TBC_RE_PASS;
    }
    rest = objc - i;
    if (rest < 2 || rest > 3 || (doinline && rest != 2)) return TBC_RE_PASS;
    pat = Tcl_GetStringFromObj(objv[i], &plen);
    re = tbc_re_get(pat, plen);
    if (!re || !tbc_re_subject(re, objv[i + 1], &sj)) return TBC_RE_PASS;
    if (hasstart) {
        Tcl_WideInt w;
        if (Tcl_GetWideIntFromObj(NULL, startObj, &w) != TCL_OK) return TBC_RE_PASS;
        if (w < 0) offset = 0; else if (w > sj.len) return TBC_RE_PASS; else offset = (int) w;
    }
    for (;;) {
        int r = tbc_re_find(re, &sj, offset, &ms, &me);
        if (r == TBC_RE_PASS) { if (resultPtr) Tcl_DecrRefCount(resultPtr); return TBC_RE_PASS; }   /* (only before anything was set: the first search, or the same expression on the same subject, which cannot give up later) */
        if (r == 0) {
            if (all <= 1) {
                if (!doinline) Tcl_SetObjResult(interp, Tcl_NewIntObj(0));
                return TCL_OK;
            }
            break;
        }
        {
            Tcl_Obj *v;
            if (doinline && all <= 1 && !resultPtr) resultPtr = Tcl_NewObj();
            if (indices) {
                Tcl_Obj *two[2];
                two[0] = Tcl_NewIntObj(ms); two[1] = Tcl_NewIntObj(me >= offset ? me - 1 : me);
                v = Tcl_NewListObj(2, two);
            } else if (me - offset > 0 && me > ms) v = Tcl_GetRange(objv[i + 1], ms, me - 1);
            else v = Tcl_NewObj();
            if (doinline) {
                if (Tcl_ListObjAppendElement(interp, resultPtr, v) != TCL_OK) { Tcl_DecrRefCount(v); Tcl_DecrRefCount(resultPtr); return TCL_ERROR; }
            } else if (rest == 3) {
                if (Tcl_ObjSetVar2(interp, objv[i + 2], NULL, v, TCL_LEAVE_ERR_MSG) == NULL) return TCL_ERROR;
            } else Tcl_DecrRefCount(v);
        }
        if (all == 0) break;
        {
            int matchLength = me - ms;
            offset = me;
            if (matchLength == 0) offset++;
            all++;
            if (offset >= sj.len) break;
        }
    }
    if (doinline) Tcl_SetObjResult(interp, resultPtr);
    else Tcl_SetObjResult(interp, Tcl_NewIntObj(all ? all - 1 : 1));
    return TCL_OK;
}
/* tbc::re pattern string ?start? -- what the native matcher says: "pass", 0, or {1 first last} (for the tests, which compare it with `regexp -indices`) */
static int tbc_re_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int ms = 0, me = 0, off = 0, r;
    (void) cd;
    if (objc != 3 && objc != 4) { Tcl_WrongNumArgs(interp, 1, objv, "pattern string ?start?"); return TCL_ERROR; }
    r = tbc_re_search(objv[1], objv[2], objc == 4, objc == 4 ? objv[3] : NULL, &ms, &me, &off);
    if (r == TBC_RE_PASS) Tcl_SetObjResult(interp, Tcl_NewStringObj("pass", -1));
    else if (r == 0) Tcl_SetObjResult(interp, Tcl_NewIntObj(0));
    else Tcl_SetObjResult(interp, Tcl_ObjPrintf("1 %d %d", ms, me - 1));
    return TCL_OK;
}
/* A call of `regexp` from compiled code, as Tcl_EvalObjv would make it: the command is looked up by the function the dispatch uses (Tcl_GetCommandFromObj: the namespace rules, cached in the
 * literal), and if it is Tcl's own `regexp`, with nothing the dispatch would act on (a trace on the command or the interpreter, a limit, a cancel, an async handler, the nesting
 * depth), the native matcher answers, and Tcl's own procedure for what it does not take; the command is counted as the dispatch counts it.  Anything else is the dispatch itself. */
static int tbc_evre(Tcl_Interp *interp, int objc, Tcl_Obj **ov, int flags) {
    Interp *iPtr = (Interp *) interp;
    Command *c = (Command *) Tcl_GetCommandFromObj(interp, ov[0]);
    if (TBC_LIKELY(c && c->objProc == Tcl_RegexpObjCmd && !c->nreProc && !(c->flags & (CMD_IS_DELETED | CMD_HAS_EXEC_TRACES))
            && !(iPtr->flags & (DELETED | CANCELED | TCL_CANCEL_UNWIND)) && !iPtr->execEnvPtr->rewind && !iPtr->tracePtr && !iPtr->limit.active && !iPtr->limit.exceeded
            && iPtr->numLevels + 1 <= iPtr->maxNestingDepth && !TclAsyncReady(iPtr))) {
        int rc;
        Tcl_ResetResult(interp);
        iPtr->cmdCount++;
        rc = tbc_regexp_fast(NULL, interp, objc, ov);
        if (rc == TBC_RE_PASS) rc = Tcl_RegexpObjCmd(NULL, interp, objc, ov);
        return rc;
    }
    return Tcl_EvalObjv(interp, objc, ov, flags);
}
#endif
