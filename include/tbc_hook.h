/* tbc_hook.h -- attaching compiled procs to the procs of an unmodified Tcl 8.6 (statically linked, so Tcl's internal headers are available).
 *
 * A compiled body is attached to the proc itself.  The program defines and calls its procs exactly as before: Tcl builds the call
 * frame and binds the arguments (defaults, `args`, wrong-# errors, namespaces, info level/body/args, rename, return codes are all
 * Tcl's own), and the proc's bytecode is replaced -- in place, as a precompiled body, which Tcl never recompiles -- by three
 * instructions that call a command of ours inside that frame:
 *
 *      push1 ::tbc::eN ; invokeStk1 1 ; done
 *
 * The command runs the compiled body.  Procs are noticed when they are defined: the C function behind `proc` is wrapped, and the wrapper looks
 * at what the original defined.  A compiled body is used only while the bytecode the interpreter would run is the one it was compiled from (a
 * fingerprint test, repeated whenever Tcl's compile epoch changes); otherwise the body is evaluated by the interpreter in the same frame. */
#ifndef TBC_HOOK_H
#define TBC_HOOK_H
#define TBC_HOOK

#include "tclInt.h"
#include "tclCompile.h"
#include "tclTomMath.h"
#include "tbc_runtime.h"

typedef struct TbcEntry {
    const char *name;			/* ::ns::proc, as compiled */
    const char *ns;			/* namespace the proc was defined in */
    const char *args;			/* canonical argument list (see tbc_canon_args) */
    const char *body;			/* body, verbatim */
    uint64_t fp;			/* fingerprint of the bytecode compiled from it */
    int (*fn)(Tcl_Interp *, Proc *);	/* the compiled body */
    int *valid;				/* flag read by direct calls from other compiled procs (may be NULL) */
    int id;				/* number in the name of the command that runs it */
    struct TbcEntry *sameName;		/* the entry registered before this one under the same name (a module can hold several definitions of a name) */
} TbcEntry;

typedef struct TbcRec {			/* one attached proc */
    TbcEntry *e;
    Proc *p;
    char *name;				/* full command name at attach time */
    int epoch;				/* compile epoch at the last fingerprint test */
    int fresh;				/* not entered yet: the interpreter compiles a body on its first call, which leaves errorLine at 1 */
    int demoted;			/* the interpreter's bytecode is no longer the compiled one */
    Tcl_Obj *bodyObj;			/* the body, for the interpreter fallback */
    unsigned char *origCode;		/* the proc's bytecode before the entry stub overwrote its first bytes */
    unsigned long calls;		/* entries that ran the compiled body */
    unsigned long fallbacks;		/* entries that ran the interpreter's bytecode instead (demoted, or inside a coroutine) */
} TbcRec;

/* a proc the translator saw and left to the interpreter, with the reason */
typedef struct TbcRefused {
    const char *name, *ns, *args, *body, *reason;
} TbcRefused;

/* what became of each proc definition the module was told about (tbc::report) */
enum { TBC_DEF_COMPILED = 1, TBC_DEF_NOCODE, TBC_DEF_CHANGED, TBC_DEF_DIFFERS, TBC_DEF_REFUSED, TBC_DEF_EARLY, TBC_DEF_TRIVIAL, TBC_DEF_PENDING };
typedef struct TbcDef {
    char *name;				/* full command name */
    int status;				/* TBC_DEF_* */
    const char *reason;			/* for the report; static text, or the translator's for a refused proc */
    unsigned long icalls;		/* calls of the interpreter's version seen while profiling */
    struct TbcRec *rec;			/* the attached record, when compiled */
    struct TbcEntry *lazyEntry;		/* armed: the compiled code to retry at the proc's first call (see tbc_lazy_cmd) */
    Proc *lazyProc;
    Proc *proc;				/* the Proc this record is about (a deleted or redefined proc is no longer reported) */
} TbcDef;

TBC_SHARED Tcl_HashTable tbc_by_body, tbc_by_name, tbc_recs, tbc_refused_by_key, tbc_defs_by_name, tbc_defs_by_proc;
TBC_SHARED int tbc_reg_ready;

static uint64_t tbc_fingerprint(const ByteCode *bc) {
    uint64_t h = UINT64_C(1469598103934665603);
    int i;
    if (!tbcDouble) tbcDouble = Tcl_GetObjType("double");      /* (the ahead-of-time tool calls this without the runtime having started) */
    const unsigned char *p = bc->codeStart;
    for (i = 0; i < bc->numCodeBytes; i++) { h ^= p[i]; h *= UINT64_C(1099511628211); }
    for (i = 0; i < bc->numLitObjects; i++) {
        int len, k;
        Tcl_Obj *lo = bc->objArrayPtr[i];
        const char *s = Tcl_GetStringFromObj(lo, &len);
        h ^= 0xff; h *= UINT64_C(1099511628211);
        for (k = 0; k < len; k++) { h ^= (unsigned char) s[k]; h *= UINT64_C(1099511628211); }
        /* A double the compiler folded (9223372036854775807 / 0.5) can hold a value its own printed text does not parse back to (2**64 prints as
         * 1.844674407370955e+19), and the literal table shares objects by text, so which value a process's bytecode holds depends on that
         * process's history.  Such a literal counts with its exact bits: a process whose bytecode holds another value than the one this code
         * was compiled with does not get this code. */
        if (lo->typePtr == tbcDouble) {
            double d = lo->internalRep.doubleValue, q = strtod(s, NULL);
            if (memcmp(&d, &q, sizeof d) != 0) {
                const unsigned char *b = (const unsigned char *) &d;
                for (k = 0; k < (int) sizeof d; k++) { h ^= b[k]; h *= UINT64_C(1099511628211); }
            }
        }
    }
    return h;
}

/* argument list as the Proc holds it: name, or name \003 default, joined by \002 (the translator builds the same string) */
static char *tbc_canon_args(Proc *p) {
    Tcl_DString ds;
    CompiledLocal *lp = p->firstLocalPtr;
    int i;
    char *r;
    Tcl_DStringInit(&ds);
    for (i = 0; i < p->numArgs && lp; i++, lp = lp->nextPtr) {
        if (i) Tcl_DStringAppend(&ds, "\002", 1);
        Tcl_DStringAppend(&ds, lp->name, lp->nameLength);
        if (lp->defValuePtr) { Tcl_DStringAppend(&ds, "\003", 1); Tcl_DStringAppend(&ds, Tcl_GetString(lp->defValuePtr), -1); }
    }
    r = (char *) ckalloc((size_t) Tcl_DStringLength(&ds) + 1);
    memcpy(r, Tcl_DStringValue(&ds), (size_t) Tcl_DStringLength(&ds) + 1);
    Tcl_DStringFree(&ds);
    return r;
}

static char *tbc_key(const char *ns, const char *args, const char *body) {
    size_t a = strlen(ns), b = strlen(args), c = strlen(body);
    char *k = (char *) ckalloc(a + b + c + 3);
    memcpy(k, ns, a); k[a] = 1;
    memcpy(k + a + 1, args, b); k[a + 1 + b] = 1;
    memcpy(k + a + b + 2, body, c + 1);
    return k;
}

static void tbc_reg_init(void) {
    if (tbc_reg_ready) return;
    Tcl_InitHashTable(&tbc_by_body, TCL_STRING_KEYS);
    Tcl_InitHashTable(&tbc_by_name, TCL_STRING_KEYS);
    Tcl_InitHashTable(&tbc_recs, TCL_ONE_WORD_KEYS);
    Tcl_InitHashTable(&tbc_refused_by_key, TCL_STRING_KEYS);
    Tcl_InitHashTable(&tbc_defs_by_name, TCL_STRING_KEYS);
    Tcl_InitHashTable(&tbc_defs_by_proc, TCL_ONE_WORD_KEYS);
    tbc_reg_ready = 1;
}

/* ---- variables of the frame the interpreter has set up: the same calls bytecode execution makes ---- */
#define TBC_FOLLOW(vp) while (TclIsVarLink(vp)) (vp) = (vp)->value.linkPtr
/* value of compiled local idx (not referenced); NULL with an error message if it is unset or a trace fails */
TBC_INLINE Tcl_Obj *tbc_ld(Tcl_Interp *interp, Var *loc, int idx) {
    Var *vp = &loc[idx];
    TBC_FOLLOW(vp);
    if (TclIsVarDirectReadable(vp)) return vp->value.objPtr;
    return TclPtrGetVarIdx(interp, vp, NULL, NULL, NULL, TCL_LEAVE_ERR_MSG, idx);
}
/* the interpreter's inline paths for a variable with no traces and no links (INST_STORE_*, INST_INCR_*): the result is the new value, not referenced */
TBC_INLINE Tcl_Obj *tbc_storedirect(Var *vp, Tcl_Obj *val) {
    Tcl_Obj *old = vp->value.objPtr;
    Tcl_IncrRefCount(val);
    vp->value.objPtr = val;
    if (old) Tcl_DecrRefCount(old);
    return val;
}
TBC_INLINE Tcl_Obj *tbc_incrdirect(Tcl_Interp *interp, Var *vp, Tcl_Obj *incr) {
    Tcl_Obj *o = vp->value.objPtr;
    if (Tcl_IsShared(o)) {
        o->refCount--;                                  /* known to be shared */
        o = Tcl_DuplicateObj(o);
        Tcl_IncrRefCount(o);
        vp->value.objPtr = o;
    }
    return TclIncrObj(interp, o, incr) == TCL_OK ? o : NULL;
}
/* the element of an array variable if it exists (not created), as the interpreter looks for it before the general path */
TBC_INLINE Var *tbc_arrfind(Var *ap, Tcl_Obj *key) {
    Tcl_HashEntry *h;
    if (!TclIsVarArray(ap)) return NULL;
    h = Tcl_CreateHashEntry(&((TclVarHashTable *) ap->value.tablePtr)->table, (char *) key, NULL);
    return h ? (Var *) ((char *) h - TclOffset(VarInHash, entry)) : NULL;
}
/* set (flags: TCL_APPEND_VALUE, TCL_LIST_ELEMENT as for append and lappend); the result is the variable's new value, NULL on error */
TBC_INLINE Tcl_Obj *tbc_setloc(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *val, int flags) {
    Var *vp = &loc[idx];
    TBC_FOLLOW(vp);
    if (flags == TCL_LEAVE_ERR_MSG && TclIsVarDirectWritable(vp)) return tbc_storedirect(vp, val);   /* a plain set: what the interpreter does inline */
    return TclPtrSetVarIdx(interp, vp, NULL, NULL, NULL, val, flags, idx);
}
TBC_INLINE Tcl_Obj *tbc_incrloc(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *incr) {
    Var *vp = &loc[idx];
    TBC_FOLLOW(vp);
    if (TclIsVarDirectModifyable(vp)) return tbc_incrdirect(interp, vp, incr);
    return TclPtrIncrObjVarIdx(interp, vp, NULL, NULL, NULL, incr, TCL_LEAVE_ERR_MSG, idx);
}
/* incr by a small constant (INST_INCR_SCALAR1_IMM): the interpreter's inline path for an int that is not near overflow, the general one otherwise */
TBC_INLINE Tcl_Obj *tbc_incrimm(Tcl_Interp *interp, Var *loc, int idx, long imm) {
    Var *vp = &loc[idx];
    Tcl_Obj *o, *i_, *r;
    TBC_FOLLOW(vp);
    if (TclIsVarDirectModifyable(vp) && (o = vp->value.objPtr)->typePtr == tbcInt) {
        long a = o->internalRep.longValue, sum = (long) ((unsigned long) a + (unsigned long) imm);
        if (!(((a ^ sum) < 0) && ((a ^ imm) >= 0))) {
            if (Tcl_IsShared(o)) {
                o->refCount--;
                o = tbc_mkint(sum);
                Tcl_IncrRefCount(o);
                vp->value.objPtr = o;
            } else {
                tbc_setint(o, sum);
            }
            return o;
        }
    }
    TclNewIntObj(i_, imm);
    Tcl_IncrRefCount(i_);
    r = tbc_incrloc(interp, loc, idx, i_);
    Tcl_DecrRefCount(i_);
    return r;
}
/* unset compiled local idx; flags nonzero reports an error for a variable that is not set (as `unset` without -nocomplain) */
static int tbc_unsetloc(Tcl_Interp *interp, Var *loc, int idx, int flags) {
    Var *vp = &loc[idx];
    int fl = flags ? TCL_LEAVE_ERR_MSG : 0;
    TBC_FOLLOW(vp);
    if (TclIsVarDirectUnsettable(vp) && !TclIsVarInHash(vp)) {
        if (!TclIsVarUndefined(vp)) { TclDecrRefCount(vp->value.objPtr); }
        else if (fl & TCL_LEAVE_ERR_MSG) goto slow;
        vp->value.objPtr = NULL;
        return TCL_OK;
    }
slow:
    if (TclPtrUnsetVarIdx(interp, vp, NULL, NULL, NULL, fl, idx) != TCL_OK && fl) {
        /* errorInUnset: the message may lack the variable's name when the unset failed inside a trace */
        return TCL_ERROR;
    }
    return TCL_OK;
}
/* ---- typed code on variables that live in the frame (links, namespace variables, array elements) ----
 * Each helper completes the operation in the common case (nothing to follow but links, no trace, the value present and of the type the operation needs)
 * and otherwise reports 0 with nothing changed: the caller then goes on in the boxed code at the same instruction, which does the general thing (traces,
 * errors, conversions, creating the variable) exactly as the interpreter does. */
#define TBC_WRITE_TRACED(vp) ((vp)->flags & VAR_TRACED_WRITE)
/* the value of compiled local idx (not referenced), NULL if the boxed code has to do it */
TBC_INLINE Tcl_Obj *tbc_tld(Var *loc, int idx) {
    Var *vp = &loc[idx];
    TBC_FOLLOW(vp);
    return TclIsVarDirectReadable(vp) ? vp->value.objPtr : NULL;
}
/* set compiled local idx to val (a reference is taken) */
TBC_INLINE int tbc_tset(Var *loc, int idx, Tcl_Obj *val) {
    Var *vp = &loc[idx];
    TBC_FOLLOW(vp);
    if (!TclIsVarDirectWritable(vp)) return 0;
    (void) tbc_storedirect(vp, val);
    return 1;
}
/* store the value of variable vp as the integer w: into the object it holds when nothing else refers to it (as incr does), else into a new one */
TBC_INLINE void tbc_putwide(Var *vp, int64_t w) {
    Tcl_Obj *o = vp->value.objPtr;
    if (o && !Tcl_IsShared(o)) { tbc_setint(o, w); return; }
    vp->value.objPtr = tbc_mkint(w);
    Tcl_IncrRefCount(vp->value.objPtr);
    if (o) Tcl_DecrRefCount(o);
}
TBC_INLINE int tbc_tseti(Var *loc, int idx, int64_t w) {
    Var *vp = &loc[idx];
    TBC_FOLLOW(vp);
    if (!TclIsVarDirectWritable(vp)) return 0;
    tbc_putwide(vp, w);
    return 1;
}
/* incr of compiled local idx holding an integer by imm; *out is the new value */
TBC_INLINE int tbc_tincr(Var *loc, int idx, int64_t imm, int64_t *out) {
    Var *vp = &loc[idx];
    Tcl_Obj *o;
    int64_t sum;
    TBC_FOLLOW(vp);
    if (!TclIsVarDirectModifyable(vp)) return 0;
    o = vp->value.objPtr;
    if (!tbc_isint(o)) return 0;                    /* (a number kept as text is read the way the interpreter reads it) */
    if (__builtin_add_overflow((int64_t) tbc_wide(o), imm, &sum)) return 0;
    tbc_putwide(vp, sum);
    *out = sum;
    return 1;
}
/* an integer as the text of an array element name, without an object of its own: enough to look an element up (the hash functions read only the bytes and the length) */
typedef struct { Tcl_Obj o; char buf[24]; } tbc_ikey_t;
TBC_INLINE Tcl_Obj *tbc_ikey(tbc_ikey_t *k, int64_t w) {
    int n = tbc_fmt_i64(k->buf, w);
    k->buf[n] = 0;
    k->o.refCount = 1; k->o.bytes = k->buf; k->o.length = n; k->o.typePtr = NULL;
    return &k->o;
}
/* the value of element key of the array that is compiled local idx (not referenced), NULL if the boxed code has to do it */
TBC_INLINE Tcl_Obj *tbc_tald(Var *loc, int idx, Tcl_Obj *key) {
    Var *ap = &loc[idx], *vp;
    TBC_FOLLOW(ap);
    if ((ap->flags & VAR_TRACED_READ) || !(vp = tbc_arrfind(ap, key)) || !TclIsVarDirectReadable(vp)) return NULL;
    return vp->value.objPtr;
}
/* the element of the array that is compiled local idx for a store or an increment: the one there, or a new one when the array (or a variable that is not
 * set yet) has no trace; NULL if the boxed code has to do it.  `traced` is the trace flags that rule the fast path out for the array.  A key made by
 * tbc_ikey (fake = 1) is turned into an object of its own for a new element. */
static Var *tbc_taelem(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *key, int fake, int traced) {
    Var *ap = &loc[idx], *vp;
    Tcl_Obj *k = key;
    TBC_FOLLOW(ap);
    if (ap->flags & traced) return NULL;
    if (TclIsVarArray(ap) && (vp = tbc_arrfind(ap, key))) return vp;
    if (TclIsVarTraced(ap)) return NULL;
    if (fake) k = Tcl_NewStringObj(key->bytes, key->length);
    Tcl_IncrRefCount(k);
    vp = TclLookupArrayElement(interp, NULL, k, 0, NULL, 1, 1, ap, idx);
    Tcl_DecrRefCount(k);
    return vp;
}
/* store val (a reference is taken) as element key */
TBC_INLINE int tbc_tast(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *key, int fake, Tcl_Obj *val) {
    Var *vp = tbc_taelem(interp, loc, idx, key, fake, VAR_TRACED_WRITE);
    if (!vp || !TclIsVarDirectWritable(vp)) return 0;
    (void) tbc_storedirect(vp, val);
    return 1;
}
/* store the integer w as element key */
TBC_INLINE int tbc_tasti(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *key, int fake, int64_t w) {
    Var *vp = tbc_taelem(interp, loc, idx, key, fake, VAR_TRACED_WRITE);
    if (!vp || !TclIsVarDirectWritable(vp)) return 0;
    tbc_putwide(vp, w);
    return 1;
}
/* [info exists name(key)] for the array that is compiled local idx: 0 or 1, or -1 if the boxed code has to do it (a read trace would run) */
TBC_INLINE int tbc_texist(Var *loc, int idx, Tcl_Obj *key) {
    Var *ap = &loc[idx], *vp;
    TBC_FOLLOW(ap);
    if (!TclIsVarArray(ap)) return 0;
    if (ap->flags & VAR_TRACED_READ) return -1;
    if (!(vp = tbc_arrfind(ap, key))) return 0;
    if (vp->flags & VAR_TRACED_READ) return -1;
    return !TclIsVarUndefined(vp);
}
/* element key += imm (an element that is not set yet becomes imm); *out is the new value */
TBC_INLINE int tbc_tainc(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *key, int fake, int64_t imm, int64_t *out) {
    Var *vp = tbc_taelem(interp, loc, idx, key, fake, VAR_TRACED_READ | VAR_TRACED_WRITE);
    Tcl_Obj *o;
    int64_t sum = imm;
    if (!vp || !TclIsVarDirectWritable(vp) || (vp->flags & (VAR_TRACED_READ | VAR_TRACED_WRITE))) return 0;
    if ((o = vp->value.objPtr) != NULL) {
        if (!tbc_isint(o)) return 0;
        if (__builtin_add_overflow((int64_t) tbc_wide(o), imm, &sum)) return 0;
    }
    tbc_putwide(vp, sum);
    *out = sum;
    return 1;
}
static Tcl_Obj *tbc_vstore(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name, Tcl_Obj *key, Tcl_Obj *val, int flags);
/* ---- arrays held natively (kind R).  An array that is a compiled local and is touched only by element loads, stores, increments and tests cannot be seen
 * by anything else while typed code runs, so typed code keeps it in a table of its own.  The table remembers the order in which the elements were made;
 * tbc_rflush writes them into the frame in that order when typed code gives up, which gives the hash table the interpreter would have built. */
typedef struct {
    uint64_t h;
    Tcl_Obj *val;
    int len;
    union { char s[28]; char *p; } k;		/* the key's bytes: inline up to 27, else allocated */
} tbc_rent;
typedef struct { tbc_rent *e; int32_t *tab; size_t n, cap, tcap; } tbc_rmap;
TBC_INLINE const char *tbc_rkey(const tbc_rent *r) { return r->len < (int) sizeof r->k.s ? r->k.s : r->k.p; }
static void tbc_rfree(tbc_rmap *m) {
    size_t i;
    for (i = 0; i < m->n; i++) {
        if (m->e[i].len >= (int) sizeof m->e[i].k.s) free(m->e[i].k.p);
        Tcl_DecrRefCount(m->e[i].val);
    }
    free(m->e); free(m->tab);
    memset(m, 0, sizeof *m);
}
TBC_INLINE tbc_rent *tbc_rfind(const tbc_rmap *m, const char *s, int len, uint64_t h) {
    size_t mask, i;
    if (!m->tcap) return NULL;
    mask = m->tcap - 1; i = (size_t) h & mask;
    for (;;) {
        int32_t e = m->tab[i];
        tbc_rent *r;
        if (!e) return NULL;
        r = &m->e[e - 1];
        if (r->h == h && r->len == len && memcmp(tbc_rkey(r), s, (size_t) len) == 0) return r;
        i = (i + 1) & mask;
    }
}
static int tbc_rgrow(tbc_rmap *m) {
    size_t ncap = m->cap ? m->cap * 2 : 16, ntcap = m->tcap ? m->tcap * 2 : 32, i;
    tbc_rent *ne = (tbc_rent *) realloc(m->e, ncap * sizeof *ne);
    int32_t *nt;
    if (!ne) return 0;
    m->e = ne;
    m->cap = ncap;
    nt = (int32_t *) calloc(ntcap, sizeof(int32_t));
    if (!nt) return 0;
    for (i = 0; i < m->n; i++) {
        size_t j = (size_t) m->e[i].h & (ntcap - 1);
        while (nt[j]) j = (j + 1) & (ntcap - 1);
        nt[j] = (int32_t) (i + 1);
    }
    free(m->tab);
    m->tab = nt; m->tcap = ntcap;
    return 1;
}
/* a new element; val is a reference the table then owns.  0 when memory runs out (nothing changed) */
static int tbc_radd(tbc_rmap *m, const char *s, int len, uint64_t h, Tcl_Obj *val) {
    tbc_rent *r;
    size_t j;
    if (m->n >= (size_t) INT32_MAX / 2) return 0;
    if ((m->n + 1) * 2 > m->tcap || m->n == m->cap) { if (!tbc_rgrow(m)) return 0; }
    r = &m->e[m->n];
    r->h = h; r->val = val; r->len = len;
    if (len < (int) sizeof r->k.s) memcpy(r->k.s, s, (size_t) len);
    else { r->k.p = (char *) malloc((size_t) len); if (!r->k.p) return 0; memcpy(r->k.p, s, (size_t) len); }
    j = (size_t) h & (m->tcap - 1);
    while (m->tab[j]) j = (j + 1) & (m->tcap - 1);
    m->tab[j] = (int32_t) (m->n + 1);
    m->n++;
    return 1;
}
/* element := val (a reference is taken).  0 when memory runs out */
static int tbc_rset(tbc_rmap *m, const char *s, int len, Tcl_Obj *val) {
    uint64_t h = tbc_hash(s, len);
    tbc_rent *r = tbc_rfind(m, s, len, h);
    if (r) { Tcl_Obj *old = r->val; Tcl_IncrRefCount(val); r->val = val; Tcl_DecrRefCount(old); return 1; }
    Tcl_IncrRefCount(val);
    if (tbc_radd(m, s, len, h, val)) return 1;
    Tcl_DecrRefCount(val);
    return 0;
}
/* element := the integer w, into the object the element holds when nothing else refers to it (as the interpreter's incr does) */
static int tbc_rseti(tbc_rmap *m, const char *s, int len, int64_t w) {
    uint64_t h = tbc_hash(s, len);
    tbc_rent *r = tbc_rfind(m, s, len, h);
    Tcl_Obj *o;
    if (r) {
        o = r->val;
        if (!Tcl_IsShared(o)) { tbc_setint(o, w); return 1; }
        r->val = tbc_mkint(w); Tcl_IncrRefCount(r->val); Tcl_DecrRefCount(o);
        return 1;
    }
    o = tbc_mkint(w); Tcl_IncrRefCount(o);
    if (tbc_radd(m, s, len, h, o)) return 1;
    Tcl_DecrRefCount(o);
    return 0;
}
/* the element's value (not referenced), NULL if there is none */
TBC_INLINE Tcl_Obj *tbc_rget(const tbc_rmap *m, const char *s, int len) {
    tbc_rent *r = tbc_rfind(m, s, len, tbc_hash(s, len));
    return r ? r->val : NULL;
}
TBC_INLINE int tbc_rhas(const tbc_rmap *m, const char *s, int len) { return tbc_rfind(m, s, len, tbc_hash(s, len)) != NULL; }
/* element += imm (an element that is not there yet becomes imm); *out is the new value.  0, changing nothing, when the value is not an integer, the sum
 * overflows or memory runs out: the boxed code then does it, with the interpreter's error */
static int tbc_rinc(tbc_rmap *m, const char *s, int len, int64_t imm, int64_t *out) {
    uint64_t h = tbc_hash(s, len);
    tbc_rent *r = tbc_rfind(m, s, len, h);
    int64_t sum = imm;
    Tcl_Obj *o;
    if (r) {
        o = r->val;
        if (!tbc_isint(o) || __builtin_add_overflow((int64_t) tbc_wide(o), imm, &sum)) return 0;
        if (!Tcl_IsShared(o)) tbc_setint(o, sum);
        else { r->val = tbc_mkint(sum); Tcl_IncrRefCount(r->val); Tcl_DecrRefCount(o); }
        *out = sum;
        return 1;
    }
    o = tbc_mkint(sum); Tcl_IncrRefCount(o);
    if (!tbc_radd(m, s, len, h, o)) { Tcl_DecrRefCount(o); return 0; }
    *out = sum;
    return 1;
}
/* write the elements into the array that is compiled local idx, in the order they were made, and empty the table */
static void tbc_rflush(Tcl_Interp *interp, Var *loc, int idx, tbc_rmap *m) {
    size_t i;
    for (i = 0; i < m->n; i++) {
        Tcl_Obj *k = Tcl_NewStringObj(tbc_rkey(&m->e[i]), m->e[i].len);
        Tcl_IncrRefCount(k);
        (void) tbc_vstore(interp, loc, idx, NULL, k, m->e[i].val, TCL_LEAVE_ERR_MSG);
        Tcl_DecrRefCount(k);
    }
    tbc_rfree(m);
}
/* ---- array elements and variables named on the stack: the generic paths of INST_LOAD_ARRAY*, INST_STORE_*, INST_INCR_*, INST_EXIST_*,
 * INST_UNSET_*.  idx >= 0: the array is the compiled local idx and key names the element; idx < 0: the variable (or, with a key, the array
 * element) is named by name on the stack.  Results are not referenced. */
#define TBC_READ_TRACED(vp) ((vp)->flags & VAR_TRACED_READ)
static Tcl_Obj *tbc_vload(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name, Tcl_Obj *key) {
    Var *vp, *ap = NULL;
    if (idx >= 0) {
        ap = &loc[idx]; TBC_FOLLOW(ap);
        if (!TBC_READ_TRACED(ap) && (vp = tbc_arrfind(ap, key)) && TclIsVarDirectReadable(vp)) return vp->value.objPtr;
        vp = TclLookupArrayElement(interp, NULL, key, TCL_LEAVE_ERR_MSG, "read", 0, 1, ap, idx);
        if (!vp) return NULL;
        return TclPtrGetVarIdx(interp, vp, ap, NULL, key, TCL_LEAVE_ERR_MSG, idx);
    }
    vp = TclObjLookupVarEx(interp, name, key, TCL_LEAVE_ERR_MSG, "read", 0, 1, &ap);
    if (!vp) return NULL;
    return TclPtrGetVarIdx(interp, vp, ap, name, key, TCL_LEAVE_ERR_MSG, -1);
}
static Tcl_Obj *tbc_vstore(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name, Tcl_Obj *key, Tcl_Obj *val, int flags) {
    Var *vp, *ap = NULL;
    if (idx >= 0) {
        ap = &loc[idx]; TBC_FOLLOW(ap);
        if (flags == TCL_LEAVE_ERR_MSG && !(ap->flags & VAR_TRACED_WRITE) && (vp = tbc_arrfind(ap, key)) && TclIsVarDirectWritable(vp)) return tbc_storedirect(vp, val);
        vp = TclLookupArrayElement(interp, NULL, key, TCL_LEAVE_ERR_MSG, "set", 1, 1, ap, idx);
        if (!vp) return NULL;
        return TclPtrSetVarIdx(interp, vp, ap, NULL, key, val, flags, idx);
    }
    vp = TclObjLookupVarEx(interp, name, key, TCL_LEAVE_ERR_MSG, "set", 1, 1, &ap);
    if (!vp) return NULL;
    return TclPtrSetVarIdx(interp, vp, ap, name, key, val, flags, -1);
}
static Tcl_Obj *tbc_vincr(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name, Tcl_Obj *key, Tcl_Obj *incr) {
    Var *vp, *ap = NULL;
    if (idx >= 0) {
        ap = &loc[idx]; TBC_FOLLOW(ap);
        vp = TclLookupArrayElement(interp, NULL, key, TCL_LEAVE_ERR_MSG, "read", 1, 1, ap, idx);
        if (!vp) return NULL;
        return TclPtrIncrObjVarIdx(interp, vp, ap, NULL, key, incr, TCL_LEAVE_ERR_MSG, idx);
    }
    vp = TclObjLookupVarEx(interp, name, key, TCL_LEAVE_ERR_MSG, "read", 1, 1, &ap);
    if (!vp) { Tcl_AddErrorInfo(interp, "\n    (reading value of variable to increment)"); return NULL; }
    return TclPtrIncrObjVarIdx(interp, vp, ap, name, key, incr, TCL_LEAVE_ERR_MSG, -1);
}
/* lappend with the values given as a list (INST_LAPPEND_LIST*): the variable's new value, NULL on error */
static Tcl_Obj *tbc_vlappend(Tcl_Interp *interp, Var *loc, int idx, int isElem, Tcl_Obj *name, Tcl_Obj *key, Tcl_Obj *val) {
    Var *vp, *ap = NULL;
    Tcl_Obj **objv, *cur, *assign, *res, *p1 = NULL;
    int objc, len, created = 0;
    if (TclListObjGetElements(interp, val, &objc, &objv) != TCL_OK) return NULL;
    if (idx >= 0 && !isElem) {
        vp = &loc[idx]; TBC_FOLLOW(vp);
    } else if (idx >= 0) {
        ap = &loc[idx]; TBC_FOLLOW(ap);
        vp = TclLookupArrayElement(interp, NULL, key, TCL_LEAVE_ERR_MSG, "set", 1, 1, ap, idx);
        if (!vp) return NULL;
    } else {
        vp = TclObjLookupVarEx(interp, name, key, TCL_LEAVE_ERR_MSG, "set", 1, 1, &ap);
        if (!vp) return NULL;
        p1 = name;
    }
    if (TclIsVarInHash(vp)) VarHashRefCount(vp)++;
    if (ap && TclIsVarInHash(ap)) VarHashRefCount(ap)++;
    cur = TclPtrGetVarIdx(interp, vp, ap, p1, key, TCL_LEAVE_ERR_MSG, idx);
    if (TclIsVarInHash(vp)) VarHashRefCount(vp)--;
    if (ap && TclIsVarInHash(ap)) VarHashRefCount(ap)--;
    if (!cur) {
        assign = val;
    } else if (TclListObjLength(interp, cur, &len) != TCL_OK) {
        return NULL;
    } else {
        if (Tcl_IsShared(cur)) { assign = Tcl_DuplicateObj(cur); created = 1; } else assign = cur;
        if (Tcl_ListObjReplace(interp, assign, len, 0, objc, objv) != TCL_OK) {
            if (created) { TclDecrRefCount(assign); }
            return NULL;
        }
    }
    Tcl_IncrRefCount(assign);
    res = TclPtrSetVarIdx(interp, vp, ap, p1, key, assign, TCL_LEAVE_ERR_MSG, idx);
    TclDecrRefCount(assign);
    return res;
}
/* the dictionary update instructions (INST_DICT_SET/UNSET/APPEND/LAPPEND): mode 0 set with nk keys, 1 unset with nk keys, 2 append, 3 lappend
 * (one key and a value); the result is the variable's new value, NULL on error */
static Tcl_Obj *tbc_dictmod(Tcl_Interp *interp, Var *loc, int idx, int mode, int nk, Tcl_Obj **keys, Tcl_Obj *val) {
    Var *vp = &loc[idx];
    Tcl_Obj *dictPtr, *valuePtr, *res;
    int alloc, result = TCL_OK;
    TBC_FOLLOW(vp);
    dictPtr = TclIsVarDirectReadable(vp) ? vp->value.objPtr : TclPtrGetVarIdx(interp, vp, NULL, NULL, NULL, 0, idx);
    if (dictPtr == NULL) { TclNewObj(dictPtr); alloc = 1; }
    else { alloc = Tcl_IsShared(dictPtr); if (alloc) dictPtr = Tcl_DuplicateObj(dictPtr); }
    switch (mode) {
    case 0: result = Tcl_DictObjPutKeyList(interp, dictPtr, nk, keys, val); break;
    case 1: result = Tcl_DictObjRemoveKeyList(interp, dictPtr, nk, keys); break;
    case 2:
    case 3:
        if (Tcl_DictObjGet(interp, dictPtr, keys[0], &valuePtr) != TCL_OK) { result = TCL_ERROR; break; }
        if (mode == 2) {
            if (valuePtr == NULL) Tcl_DictObjPut(NULL, dictPtr, keys[0], val);
            else if (Tcl_IsShared(valuePtr)) { valuePtr = Tcl_DuplicateObj(valuePtr); Tcl_AppendObjToObj(valuePtr, val); Tcl_DictObjPut(NULL, dictPtr, keys[0], valuePtr); }
            else { Tcl_AppendObjToObj(valuePtr, val); TclInvalidateStringRep(dictPtr); }
        } else if (valuePtr == NULL) {
            Tcl_DictObjPut(NULL, dictPtr, keys[0], Tcl_NewListObj(1, &val));
        } else if (Tcl_IsShared(valuePtr)) {
            valuePtr = Tcl_DuplicateObj(valuePtr);
            if (Tcl_ListObjAppendElement(interp, valuePtr, val) != TCL_OK) { TclDecrRefCount(valuePtr); result = TCL_ERROR; break; }
            Tcl_DictObjPut(NULL, dictPtr, keys[0], valuePtr);
        } else {
            if (Tcl_ListObjAppendElement(interp, valuePtr, val) != TCL_OK) { result = TCL_ERROR; break; }
            TclInvalidateStringRep(dictPtr);
        }
        break;
    }
    if (result != TCL_OK) { if (alloc) { TclDecrRefCount(dictPtr); } return NULL; }
    if (TclIsVarDirectWritable(vp)) {
        if (alloc) {
            Tcl_Obj *old = vp->value.objPtr;
            Tcl_IncrRefCount(dictPtr);
            if (old != NULL) { TclDecrRefCount(old); }
            vp->value.objPtr = dictPtr;
        }
        return dictPtr;
    }
    Tcl_IncrRefCount(dictPtr);
    res = TclPtrSetVarIdx(interp, vp, NULL, NULL, NULL, dictPtr, TCL_LEAVE_ERR_MSG, idx);
    TclDecrRefCount(dictPtr);
    return res;
}
/* [array set] on a variable that has no value yet: make it an array (INST_ARRAY_MAKE_*); nonzero on error */
static int tbc_arrmake(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name) {
    Var *vp, *ap = NULL;
    Tcl_Obj *p1 = NULL;
    if (idx >= 0) { vp = &loc[idx]; TBC_FOLLOW(vp); }
    else {
        vp = TclObjLookupVarEx(interp, name, NULL, TCL_LEAVE_ERR_MSG, "set", 1, 0, &ap);
        if (!vp) return 1;
        p1 = name;
    }
    if (vp && !TclIsVarArray(vp)) {
        if (TclIsVarArrayElement(vp) || !TclIsVarUndefined(vp)) {
            TclObjVarErrMsg(interp, p1, NULL, "array set", "variable isn't array", idx);
            Tcl_SetErrorCode(interp, "TCL", "WRITE", "ARRAY", NULL);
            return 1;
        }
        TclSetVarArray(vp);
        vp->value.tablePtr = (TclVarHashTable *) ckalloc(sizeof(TclVarHashTable));
        TclInitVarHashTable(vp->value.tablePtr, TclGetVarNsPtr(vp));
    }
    return 0;
}
/* [string is integer] etc.: the numeric type code of INST_NUM_TYPE */
static int tbc_numtype(Tcl_Obj *o) {
    ClientData ptr;
    int type1, i;
    if (TclGetNumberFromObj(NULL, o, &ptr, &type1) != TCL_OK) return 0;
    if (type1 == TCL_NUMBER_LONG) {
        if (TclGetIntFromObj(NULL, o, &i) != TCL_OK) type1 = TCL_NUMBER_WIDE;
    } else if (type1 == TCL_NUMBER_WIDE) {
        if (TclGetIntFromObj(NULL, o, &i) == TCL_OK) type1 = TCL_NUMBER_LONG;
    } else if (type1 == TCL_NUMBER_BIG) {
        Tcl_WideInt w;
        if (Tcl_GetWideIntFromObj(NULL, o, &w) == TCL_OK) type1 = TCL_NUMBER_WIDE;
    }
    return type1;
}
static Tcl_WideInt tbc_clock(int which) {
    Tcl_Time now;
    switch (which) {
#ifdef TCL_WIDE_CLICKS
    case 0: return TclpGetWideClicks();
#else
    case 0: return (Tcl_WideInt) TclpGetClicks();
#endif
    case 1: Tcl_GetTime(&now); return (Tcl_WideInt) now.sec * 1000000 + now.usec;
    case 2: Tcl_GetTime(&now); return (Tcl_WideInt) now.sec * 1000 + now.usec / 1000;
    default: Tcl_GetTime(&now); return (Tcl_WideInt) now.sec;
    }
}
/* dict update: the values of the keys go to the variables (INST_DICT_UPDATE_START), and come back (INST_DICT_UPDATE_END) */
static int tbc_dupstart(Tcl_Interp *interp, Var *loc, int idx, const int *vi, int nv, Tcl_Obj *keys) {
    Interp *iPtr = (Interp *) interp;
    Var *vp = &loc[idx];
    Tcl_Obj *dictPtr, *valuePtr, **kp;
    int length, i;
    TBC_FOLLOW(vp);
    if (TclIsVarDirectReadable(vp)) dictPtr = vp->value.objPtr;
    else { dictPtr = TclPtrGetVarIdx(interp, vp, NULL, NULL, NULL, TCL_LEAVE_ERR_MSG, idx); if (dictPtr == NULL) return 1; }
    Tcl_IncrRefCount(dictPtr);
    if (TclListObjGetElements(interp, keys, &length, &kp) != TCL_OK) { return 1; }
    if (length != nv) Tcl_Panic("dictUpdateStart argument length mismatch");
    for (i = 0; i < length; i++) {
        Var *v2;
        if (Tcl_DictObjGet(interp, dictPtr, kp[i], &valuePtr) != TCL_OK) { Tcl_DecrRefCount(dictPtr); return 1; }
        v2 = &loc[vi[i]]; TBC_FOLLOW(v2);
        if (valuePtr == NULL) TclObjUnsetVar2(interp, localName(iPtr->varFramePtr, vi[i]), NULL, 0);
        else if (TclPtrSetVarIdx(interp, v2, NULL, NULL, NULL, valuePtr, TCL_LEAVE_ERR_MSG, vi[i]) == NULL) { Tcl_DecrRefCount(dictPtr); return 1; }
    }
    TclDecrRefCount(dictPtr);
    return 0;
}
static int tbc_dupend(Tcl_Interp *interp, Var *loc, int idx, const int *vi, Tcl_Obj *keys) {
    Var *vp = &loc[idx];
    Tcl_Obj *dictPtr, *valuePtr, *res, **kp;
    int length, i, allocdict;
    TBC_FOLLOW(vp);
    if (TclIsVarDirectReadable(vp)) dictPtr = vp->value.objPtr;
    else dictPtr = TclPtrGetVarIdx(interp, vp, NULL, NULL, NULL, 0, idx);
    if (dictPtr == NULL) return 0;                                  /* storage was unset */
    if (Tcl_DictObjSize(interp, dictPtr, &length) != TCL_OK || TclListObjGetElements(interp, keys, &length, &kp) != TCL_OK) return 1;
    allocdict = Tcl_IsShared(dictPtr);
    if (allocdict) dictPtr = Tcl_DuplicateObj(dictPtr);
    if (length > 0) TclInvalidateStringRep(dictPtr);
    for (i = 0; i < length; i++) {
        Var *v2 = &loc[vi[i]];
        TBC_FOLLOW(v2);
        if (TclIsVarDirectReadable(v2)) valuePtr = v2->value.objPtr;
        else valuePtr = TclPtrGetVarIdx(interp, v2, NULL, NULL, NULL, 0, vi[i]);
        if (valuePtr == NULL) Tcl_DictObjRemove(interp, dictPtr, kp[i]);
        else if (dictPtr == valuePtr) Tcl_DictObjPut(interp, dictPtr, kp[i], Tcl_DuplicateObj(valuePtr));
        else Tcl_DictObjPut(interp, dictPtr, kp[i], valuePtr);
    }
    if (TclIsVarDirectWritable(vp)) {
        Tcl_IncrRefCount(dictPtr);
        TclDecrRefCount(vp->value.objPtr);
        vp->value.objPtr = dictPtr;
    } else {
        res = TclPtrSetVarIdx(interp, vp, NULL, NULL, NULL, dictPtr, TCL_LEAVE_ERR_MSG, idx);
        if (res == NULL) { if (allocdict) { TclDecrRefCount(dictPtr); } return 1; }
    }
    return 0;
}
/* dict get / dict exists with a key path (INST_DICT_GET, INST_DICT_EXISTS with more than one key): the keys are keys[0..n-1] and the
 * dictionary is dict; the value (not referenced) or NULL; for exists (exist != 0) nothing is raised and *found tells; for get a missing
 * key or a bad dictionary is an error (NULL with an error message) */
static Tcl_Obj *tbc_dictpath(Tcl_Interp *interp, Tcl_Obj *dict, int n, Tcl_Obj **keys, int exist, int *found) {
    Tcl_Interp *i2 = exist ? NULL : interp;
    Tcl_Obj *dp = dict, *res = NULL;
    if (n > 1) {
        dp = TclTraceDictPath(i2, dp, n - 1, keys, DICT_PATH_READ);
        if (dp == NULL) { if (exist) { *found = 0; return NULL; } return NULL; }
    }
    if (Tcl_DictObjGet(i2, dp, keys[n - 1], &res) == TCL_OK) {
        if (exist) { *found = res ? 1 : 0; return res; }
        if (!res) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("key \"%s\" not known in dictionary", Tcl_GetString(keys[n - 1])));
            Tcl_SetErrorCode(interp, "TCL", "LOOKUP", "DICT", Tcl_GetString(keys[n - 1]), NULL);
            return NULL;
        }
        return res;
    }
    if (exist) *found = 0;
    return NULL;
}
/* does the variable exist ([info exists]); idx >= 0 with no key: the compiled local itself */
static int tbc_vexist(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name, Tcl_Obj *key) {
    Interp *iPtr = (Interp *) interp;
    Var *vp, *ap = NULL;
    if (idx >= 0 && !key) {
        vp = &loc[idx]; TBC_FOLLOW(vp);
        if (TBC_READ_TRACED(vp)) {
            TclObjCallVarTraces(iPtr, NULL, vp, NULL, NULL, TCL_TRACE_READS, 0, idx);
            if (TclIsVarUndefined(vp)) { TclCleanupVar(vp, NULL); vp = NULL; }
        }
    } else if (idx >= 0) {
        ap = &loc[idx]; TBC_FOLLOW(ap);
        if (TclIsVarArray(ap) && !TBC_READ_TRACED(ap)) {
            /* (the interpreter looks the element up without making an entry for it, unless a read trace has to run: an entry made and removed again
             * would change the order in which the array lists its elements) */
            vp = tbc_arrfind(ap, key);
            if (!vp || !TBC_READ_TRACED(vp)) return vp && !TclIsVarUndefined(vp);
        }
        vp = TclLookupArrayElement(interp, NULL, key, 0, "access", 0, 1, ap, idx);
        if (vp) {
            if (TBC_READ_TRACED(vp) || (ap && TBC_READ_TRACED(ap))) TclObjCallVarTraces(iPtr, ap, vp, NULL, key, TCL_TRACE_READS, 0, idx);
            if (TclIsVarUndefined(vp)) { TclCleanupVar(vp, ap); vp = NULL; }
        }
    } else {
        vp = TclObjLookupVarEx(interp, name, key, 0, "access", 0, 1, &ap);
        if (vp) {
            if (TBC_READ_TRACED(vp) || (ap && TBC_READ_TRACED(ap))) TclObjCallVarTraces(iPtr, ap, vp, name, key, TCL_TRACE_READS, 0, -1);
            if (TclIsVarUndefined(vp)) { TclCleanupVar(vp, ap); vp = NULL; }
        }
    }
    return vp && !TclIsVarUndefined(vp);
}
/* unset an array element (idx >= 0, key) or a variable named on the stack; flags as for unset (TCL_LEAVE_ERR_MSG or 0); 0 on success */
static int tbc_vunset(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name, Tcl_Obj *key, int flags) {
    Var *vp, *ap;
    if (idx >= 0) {
        ap = &loc[idx]; TBC_FOLLOW(ap);
        vp = TclLookupArrayElement(interp, NULL, key, flags, "unset", 0, 0, ap, idx);
        if (!vp) return (flags & TCL_LEAVE_ERR_MSG) ? 1 : 0;
        return (TclPtrUnsetVarIdx(interp, vp, ap, NULL, key, flags, idx) != TCL_OK && (flags & TCL_LEAVE_ERR_MSG)) ? 1 : 0;
    }
    return (TclObjUnsetVar2(interp, name, key, flags) != TCL_OK && (flags & TCL_LEAVE_ERR_MSG)) ? 1 : 0;
}
/* [array exists]: 1, 0, or -1 for an error raised by an array trace */
static int tbc_arrexists(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name) {
    Var *vp, *ap = NULL;
    if (idx >= 0) { vp = &loc[idx]; TBC_FOLLOW(vp); name = NULL; }
    else vp = TclObjLookupVarEx(interp, name, NULL, 0, NULL, 0, 0, &ap);
    if (TclCheckArrayTraces(interp, vp, ap, name, idx) == TCL_ERROR) return -1;
    return vp && TclIsVarArray(vp) && !TclIsVarUndefined(vp);
}

/* ---- the interpreter's arithmetic for what the inline paths do not do (bignums, numbers held as text that fail to parse, errors): one small
 * bytecode per operator, made by the interpreter's compiler from `expr {$x OP $y}` in a proc of its own, whose two variable loads become pushes of
 * two literal slots that are set before each run.  The instruction is the interpreter's, so results and error messages are exactly its own. */
typedef struct { ByteCode *bc; int tried; } TbcMop;
TBC_SHARED TbcMop tbc_mops[TBC_NOPS];
static ByteCode *tbc_mop_get(Tcl_Interp *interp, int op) {
    static const char *const ex[TBC_NOPS] = { "$x + $y", "$x - $y", "$x * $y", "$x / $y", "$x % $y", "$x < $y", "$x <= $y", "$x > $y", "$x >= $y",
        "$x == $y", "$x != $y", "$x & $y", "$x | $y", "$x ^ $y", "$x << $y", "$x >> $y", "$x ** $y", "-$x", "+$x", "~$x", "!$x" };
    TbcMop *m = &tbc_mops[op];
    Tcl_Obj *cmd;
    Tcl_CmdInfo ci;
    Proc *p;
    ByteCode *bc;
    int unary = op >= TBC_NEG, k;
    unsigned char *c;
    if (m->tried) return m->bc;
    m->tried = 1;
    cmd = Tcl_ObjPrintf("proc ::tbc::mop%d {x y} {expr {%s}}", op, ex[op]);
    Tcl_IncrRefCount(cmd);
    k = Tcl_EvalObjEx(interp, cmd, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(cmd);
    Tcl_ResetResult(interp);
    if (k != TCL_OK) return NULL;
    cmd = Tcl_ObjPrintf("::tbc::mop%d", op);
    Tcl_IncrRefCount(cmd);
    k = Tcl_GetCommandInfo(interp, Tcl_GetString(cmd), &ci);
    Tcl_DecrRefCount(cmd);
    if (!k || ci.objProc != TclObjInterpProc) return NULL;
    p = (Proc *) ci.objClientData;
    if (TclProcCompileProc(interp, p, p->bodyPtr, p->cmdPtr->nsPtr, "body of proc", "tbc-mop") != TCL_OK) { Tcl_ResetResult(interp); return NULL; }
    if (p->bodyPtr->typePtr != &tclByteCodeType) return NULL;
    bc = (ByteCode *) p->bodyPtr->internalRep.twoPtrValue.ptr1;
    c = bc->codeStart;
    /* the loads of x and y, the operator, done */
    if (bc->numCodeBytes != (unary ? 2 + 1 + 1 : 2 + 2 + 1 + 1) || c[0] != INST_LOAD_SCALAR1 || c[1] != 0
            || (!unary && (c[2] != INST_LOAD_SCALAR1 || c[3] != 1)) || c[bc->numCodeBytes - 1] != INST_DONE) {
        if (getenv("TBC_DEBUG")) { int i; fprintf(stderr, "tbc: mop%d: unexpected code (%d bytes):", op, bc->numCodeBytes); for (i = 0; i < bc->numCodeBytes; i++) fprintf(stderr, " %d", c[i]); fprintf(stderr, "\n"); }
        return NULL;
    }
    c[0] = INST_PUSH1; c[1] = 0;
    if (!unary) { c[2] = INST_PUSH1; c[3] = 1; }
    bc->objArrayPtr = (Tcl_Obj **) ckalloc(2 * sizeof(Tcl_Obj *));
    bc->objArrayPtr[0] = bc->objArrayPtr[1] = NULL;
    bc->numLitObjects = 2;
    bc->numExceptRanges = 0;
    bc->flags |= TCL_BYTECODE_PRECOMPILED;
    m->bc = bc;
    return bc;
}
/* The shifts and bitwise operators on integers beyond the machine range, as ExecuteExtendedBinaryMathOp does them (the cases that are not
 * errors; those are left to the interpreter's own instruction).  0 on success (b consumed, *pa replaced), -1 if this is not one of them. */
static int tbc_bigop(int op, Tcl_Obj **pa, Tcl_Obj *b) {
    Tcl_Obj *a = *pa;
    ClientData p1, p2;
    int t1, t2;
    mp_int b1, b2, br;
    if (op != TBC_SHL && op != TBC_SHR && op != TBC_BAND && op != TBC_BOR && op != TBC_BXOR && op != TBC_ADD && op != TBC_SUB && op != TBC_MULT) return -1;
    if (TclGetNumberFromObj(NULL, a, &p1, &t1) != TCL_OK || TclGetNumberFromObj(NULL, b, &p2, &t2) != TCL_OK) return -1;
    if ((t1 != TCL_NUMBER_LONG && t1 != TCL_NUMBER_BIG) || (t2 != TCL_NUMBER_LONG && t2 != TCL_NUMBER_BIG)) return -1;
    if (op == TBC_SHL || op == TBC_SHR) {
        long shift;
        if (t2 != TCL_NUMBER_LONG) return -1;
        shift = *(const long *) p2;
        if (shift < 0 || shift > INT_MAX) return -1;
        if (t1 == TCL_NUMBER_LONG && *(const long *) p1 == 0) return -1;
        if (Tcl_GetBignumFromObj(NULL, a, &b1) != TCL_OK) return -1;
        mp_init(&br);
        if (op == TBC_SHL) mp_mul_2d(&b1, (int) shift, &br); else mp_signed_rsh(&b1, (int) shift, &br);
        mp_clear(&b1);
    } else {
        /* (two machine integers only get here for bit operators if the operation overflowed, which they cannot; for + - * they do when the result
         * does not fit: the interpreter then does it in bignums too) */
        if (t1 != TCL_NUMBER_BIG && t2 != TCL_NUMBER_BIG && op != TBC_ADD && op != TBC_SUB && op != TBC_MULT) return -1;
        if (Tcl_GetBignumFromObj(NULL, a, &b1) != TCL_OK) return -1;
        if (Tcl_GetBignumFromObj(NULL, b, &b2) != TCL_OK) { mp_clear(&b1); return -1; }
        mp_init(&br);
        if (op == TBC_BAND) mp_and(&b1, &b2, &br);
        else if (op == TBC_BOR) mp_or(&b1, &b2, &br);
        else if (op == TBC_BXOR) mp_xor(&b1, &b2, &br);
        else if (op == TBC_ADD) mp_add(&b1, &b2, &br);
        else if (op == TBC_SUB) mp_sub(&b1, &b2, &br);
        else mp_mul(&b1, &b2, &br);
        mp_clear(&b1);
        mp_clear(&b2);
    }
    if (!Tcl_IsShared(a)) {                             /* as the interpreter's BIG_RESULT: an operand nobody else holds takes the result */
        Tcl_SetBignumObj(a, &br);
    } else {
        Tcl_Obj *n = Tcl_NewBignumObj(&br);
        Tcl_IncrRefCount(n);
        Tcl_DecrRefCount(a);
        *pa = n;
    }
    Tcl_DecrRefCount(b);
    return 0;
}
static int tbc_tebc(Tcl_Interp *interp, int op, Tcl_Obj *a, Tcl_Obj *b, Tcl_Obj **res) {
    Interp *iPtr = (Interp *) interp;
    ByteCode *bc;
    NRE_callback *root;
    int rc;
    if (op < TBC_ADD || op >= TBC_NOPS) return -1;
    bc = tbc_mop_get(interp, op);
    if (!bc) return -1;
    bc->objArrayPtr[0] = a;
    bc->objArrayPtr[1] = b;
    root = TOP_CB(interp);
    iPtr->flags |= ERR_ALREADY_LOGGED;          /* this bytecode has no source: its error is not to be logged by it */
    rc = TclNRRunCallbacks(interp, TclNRExecuteByteCode(interp, bc), root);
    bc->objArrayPtr[0] = bc->objArrayPtr[1] = NULL;
    if (rc != TCL_OK) { iPtr->flags &= ~ERR_ALREADY_LOGGED; return 1; }
    iPtr->flags &= ~ERR_ALREADY_LOGGED;
    *res = tbc_takeres(interp);
    return 0;
}

/* ---- a command the interpreter's own instruction implements (string operations, bitwise operators...), called as a script would call it.
 * The result is referenced; on error nothing is consumed.  A NaN result is an error in an expression operator (nanchk). */
static int tbc_cmdcall(Tcl_Interp *interp, Tcl_Obj *nm, int n, Tcl_Obj **args, int nanchk, Tcl_Obj **out) {
    Tcl_Obj *ov[10], *r;
    int i, rc;
    ov[0] = nm;
    for (i = 0; i < n; i++) ov[i + 1] = args[i];
    rc = Tcl_EvalObjv(interp, n + 1, ov, TCL_EVAL_NOERR);
    if (rc != TCL_OK) return rc;
    r = tbc_takeres(interp);
    if (nanchk && r->typePtr == tbcDouble && r->internalRep.doubleValue != r->internalRep.doubleValue) {
        TclExprFloatError(interp, r->internalRep.doubleValue);
        Tcl_DecrRefCount(r);
        return TCL_ERROR;
    }
    *out = r;
    return TCL_OK;
}
#define TBC_NM(str) ({ static Tcl_Obj *nm_; if (!nm_) { nm_ = Tcl_NewStringObj(str, -1); Tcl_IncrRefCount(nm_); } nm_; })

/* dict incr var key imm, as INST_DICT_INCR_IMM does it; the result is the dict (not referenced), NULL on error */
static Tcl_Obj *tbc_dictincr_var(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *key, long imm) {
    Var *vp = &loc[idx];
    Tcl_Obj *dictPtr, *valuePtr, *value2Ptr, *res;
    int allocateDict, result;
    TBC_FOLLOW(vp);
    dictPtr = TclIsVarDirectReadable(vp) ? vp->value.objPtr : TclPtrGetVarIdx(interp, vp, NULL, NULL, NULL, 0, idx);
    if (dictPtr == NULL) { TclNewObj(dictPtr); allocateDict = 1; }
    else { allocateDict = Tcl_IsShared(dictPtr); if (allocateDict) dictPtr = Tcl_DuplicateObj(dictPtr); }
    result = Tcl_DictObjGet(interp, dictPtr, key, &valuePtr);
    if (result == TCL_OK) {
        if (valuePtr == NULL) {
            Tcl_DictObjPut(NULL, dictPtr, key, Tcl_NewIntObj(imm));
        } else {
            TclNewIntObj(value2Ptr, imm);
            Tcl_IncrRefCount(value2Ptr);
            if (Tcl_IsShared(valuePtr)) { valuePtr = Tcl_DuplicateObj(valuePtr); Tcl_DictObjPut(NULL, dictPtr, key, valuePtr); }
            result = TclIncrObj(interp, valuePtr, value2Ptr);
            if (result == TCL_OK) TclInvalidateStringRep(dictPtr);
            TclDecrRefCount(value2Ptr);
        }
    }
    if (result != TCL_OK) { if (allocateDict) TclDecrRefCount(dictPtr); return NULL; }
    if (TclIsVarDirectWritable(vp)) {
        if (allocateDict) {
            value2Ptr = vp->value.objPtr;
            Tcl_IncrRefCount(dictPtr);
            if (value2Ptr != NULL) TclDecrRefCount(value2Ptr);
            vp->value.objPtr = dictPtr;
        }
        return dictPtr;
    }
    Tcl_IncrRefCount(dictPtr);
    res = TclPtrSetVarIdx(interp, vp, NULL, NULL, NULL, dictPtr, TCL_LEAVE_ERR_MSG, idx);
    TclDecrRefCount(dictPtr);
    return res;
}

/* the part of the interpreter's variable linking (upvar, namespace upvar, variable) that follows once the other variable is found:
 * make compiled local `opnd` a link to otherPtr.  TCL_OK or TCL_ERROR. */
static int tbc_linkvars(Tcl_Interp *interp, Var *loc, int opnd, Var *otherPtr) {
    Var *varPtr = &loc[opnd];
    if ((varPtr != otherPtr) && !TclIsVarTraced(varPtr) && (TclIsVarUndefined(varPtr) || TclIsVarLink(varPtr))) {
        if (!TclIsVarUndefined(varPtr)) {
            Var *linkPtr = varPtr->value.linkPtr;
            if (linkPtr == otherPtr) return TCL_OK;
            if (TclIsVarInHash(linkPtr)) {
                VarHashRefCount(linkPtr)--;
                if (TclIsVarUndefined(linkPtr)) TclCleanupVar(linkPtr, NULL);
            }
        }
        TclSetVarLink(varPtr);
        varPtr->value.linkPtr = otherPtr;
        if (TclIsVarInHash(otherPtr)) VarHashRefCount(otherPtr)++;
    } else if (TclPtrObjMakeUpvarIdx(interp, otherPtr, NULL, 0, opnd) != TCL_OK) {
        return TCL_ERROR;
    }
    return TCL_OK;
}

/* upvar, namespace upvar and variable for typed code, as the boxed code does them.  0: done; 1: the boxed code has to do it at this instruction (an error, which it
 * then raises with its error info; or an upvar to a variable of this very frame, which typed code may be holding unboxed) */
static int tbc_t_upvar(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *level, Tcl_Obj *name) {
    CallFrame *fr, *sv;
    Var *vp, *o;
    Interp *ip = (Interp *) interp;
    if (TclObjGetFrame(interp, level, &fr) == -1) return 1;
    if (fr == ip->varFramePtr) return 1;
    sv = ip->varFramePtr; ip->varFramePtr = fr;
    o = TclObjLookupVarEx(interp, name, NULL, TCL_LEAVE_ERR_MSG, "access", 1, 1, &vp);
    ip->varFramePtr = sv;
    if (!o) return 1;
    return tbc_linkvars(interp, loc, idx, o) ? 1 : 0;
}
static int tbc_t_nsupvar(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *nsname, Tcl_Obj *name) {
    Tcl_Namespace *ns;
    Namespace *sv;
    Var *vp, *o;
    Interp *ip = (Interp *) interp;
    if (TclGetNamespaceFromObj(interp, nsname, &ns) != TCL_OK) return 1;
    sv = ip->varFramePtr->nsPtr; ip->varFramePtr->nsPtr = (Namespace *) ns;
    o = TclObjLookupVarEx(interp, name, NULL, TCL_NAMESPACE_ONLY | TCL_LEAVE_ERR_MSG | TCL_AVOID_RESOLVERS, "access", 1, 1, &vp);
    ip->varFramePtr->nsPtr = sv;
    if (!o) return 1;
    return tbc_linkvars(interp, loc, idx, o) ? 1 : 0;
}
static int tbc_t_variable(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *name) {
    Var *vp, *o = TclObjLookupVarEx(interp, name, NULL, TCL_NAMESPACE_ONLY | TCL_LEAVE_ERR_MSG, "access", 1, 1, &vp);
    if (!o) return 1;
    TclSetVarNamespaceVar(o);
    return tbc_linkvars(interp, loc, idx, o) ? 1 : 0;
}

/* an error ended an instruction: add "while executing ... (procedure ...)" lines to the error info exactly as the bytecode executor does
 * (TclLogCommandInfo), from the command's position in the body (srcOff, srcLen; srcOff < 0: none) and the instruction's operands */
static void tbc_logerr(Tcl_Interp *interp, int pcoff, int srcOff, int srcLen, Tcl_Obj **tos) {
    Interp *iPtr = (Interp *) interp;
    Proc *p = iPtr->varFramePtr->procPtr;
    Tcl_HashEntry *h = p ? Tcl_FindHashEntry(&tbc_recs, (char *) p) : NULL;
    if (h && !(iPtr->flags & ERR_ALREADY_LOGGED)) {
        TbcRec *r = (TbcRec *) Tcl_GetHashValue(h);
        const ByteCode *bc = (const ByteCode *) p->bodyPtr->internalRep.twoPtrValue.ptr1;
        TclLogCommandInfo(interp, bc->source, srcOff >= 0 ? bc->source + srcOff : NULL, srcOff >= 0 ? srcLen : 0, r->origCode + pcoff, tos);
    }
    iPtr->flags &= ~ERR_ALREADY_LOGGED;
}

/* typed code leaving typed mode: store a local (borrowed reference) into its frame slot */
static void tbc_flushr(Tcl_Interp *interp, Var *loc, int idx, Tcl_Obj *val) {
    (void) tbc_setloc(interp, loc, idx, val, 0);
}

/* How many compiled entries may be live on the C stack at once.  Compiled code recurses on the C stack where the interpreter uses its own heap stack; the
 * entry from the interpreter (an untyped call, or the boxed redo of a failed typed chain) costs about 0.7 KB of it per level, so a recursion that reaches
 * Tcl's own limit of 1000 levels needs most of the 512 KiB call stack a WebAssembly engine gives a guest by default, and overflowing it kills the guest
 * where Tcl would raise an error.  Beyond the cap the call is run by the interpreter instead (as inside a coroutine): same results and error info, on
 * the interpreter's stack.  0 turns the cap off (a native process has megabytes of stack); TBC_NEST_CAP=n at compile time sets it. */
#ifndef TBC_NEST_CAP
# if defined(__wasi__) || defined(__wasm__)
#  define TBC_NEST_CAP 200
# else
#  define TBC_NEST_CAP 0
# endif
#endif
TBC_SHARED int tbc_nest;

static int tbc_enter_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]);
static int tbc_enter_nr(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]);

static void tbc_register(Tcl_Interp *interp, TbcEntry *e, int id) {
    int isNew;
    char *k = tbc_key(e->ns, e->args, e->body);
    Tcl_HashEntry *h;
    Tcl_Obj *cn = Tcl_ObjPrintf("::tbc::e%d", id);
    e->id = id;
    tbc_reg_init();
    h = Tcl_CreateHashEntry(&tbc_by_body, k, &isNew);
    if (isNew) Tcl_SetHashValue(h, e);
    ckfree(k);
    h = Tcl_CreateHashEntry(&tbc_by_name, e->name, &isNew);
    e->sameName = isNew ? NULL : (TbcEntry *) Tcl_GetHashValue(h);
    Tcl_SetHashValue(h, e);
    if (e->valid) *e->valid = 0;
    Tcl_NRCreateCommand(interp, Tcl_GetString(cn), tbc_enter_cmd, tbc_enter_nr, e, NULL);
    Tcl_DecrRefCount(cn);
}

/* a proc of this name is being (re)defined or removed: no direct call to any compiled definition of the name may go on */
/* Typed code computes the common math functions itself, which is right only while tcl::mathfunc::* are Tcl's own commands.  tbc_mf_ok says so.  It is
 * cleared when one of them is renamed or deleted (traces set up by tbc_mf_setup), and when a proc is defined under a name that contains
 * ::tcl::mathfunc:: (the compiler emits the relative name tcl::mathfunc::sqrt, so ::ns::tcl::mathfunc::sqrt would be found first). */
TBC_SHARED int tbc_mf_ok;

static void tbc_invalidate_name(const char *name) {
    Tcl_HashEntry *h;
    TbcEntry *e;
    if (strstr(name, "::tcl::mathfunc::")) tbc_mf_ok = 0;
    h = Tcl_FindHashEntry(&tbc_by_name, name);
    if (!h) return;
    for (e = (TbcEntry *) Tcl_GetHashValue(h); e; e = e->sameName) if (e->valid) *e->valid = 0;
}

/* the procs the translator refused (called from a module's Init): a definition equal to one of them is reported with the translator's reason */
static void tbc_register_refused(const TbcRefused *t, int n) {
    int i, isNew;
    tbc_reg_init();
    for (i = 0; i < n; i++) {
        char *k = tbc_key(t[i].ns, t[i].args, t[i].body);
        Tcl_HashEntry *h = Tcl_CreateHashEntry(&tbc_refused_by_key, k, &isNew);
        if (isNew) Tcl_SetHashValue(h, (ClientData) &t[i]);
        ckfree(k);
    }
}

/* ---- tbc::capture: the definitions of the procs the module has no code for, as a Tcl file the translator takes as input (a run of the program
 * with the capture on gives the procs it builds at run time, which the module can then be extended with) */
TBC_SHARED int tbc_capture_on;
TBC_SHARED Tcl_Obj *tbc_capture_defs;		/* list of `proc` commands, in the order the definitions were made */
TBC_SHARED Tcl_HashTable tbc_capture_seen;
TBC_SHARED int tbc_capture_ready;
static void tbc_capture_note(const char *fullName, const char *ns, const char *canonArgs, const char *body) {
    char *k = tbc_key(ns, canonArgs, body);
    int isNew;
    Tcl_Obj *args, *cmd[4];
    const char *a, *b;
    if (!tbc_capture_ready) { Tcl_InitHashTable(&tbc_capture_seen, TCL_STRING_KEYS); tbc_capture_defs = Tcl_NewListObj(0, NULL); Tcl_IncrRefCount(tbc_capture_defs); tbc_capture_ready = 1; }
    Tcl_CreateHashEntry(&tbc_capture_seen, k, &isNew);
    ckfree(k);
    if (!isNew) return;
    /* the argument list: items are name, or name \003 default, separated by \002 */
    args = Tcl_NewListObj(0, NULL);
    a = canonArgs;
    if (*a) for (;;) {
        const char *d;
        b = a;
        while (*b && *b != '\002') b++;
        d = a;
        while (d < b && *d != '\003') d++;
        if (d < b) {
            Tcl_Obj *pair[2];
            pair[0] = Tcl_NewStringObj(a, (int) (d - a)); pair[1] = Tcl_NewStringObj(d + 1, (int) (b - d - 1));
            Tcl_ListObjAppendElement(NULL, args, Tcl_NewListObj(2, pair));
        } else Tcl_ListObjAppendElement(NULL, args, Tcl_NewStringObj(a, (int) (b - a)));
        if (!*b) break;
        a = b + 1;
    }
    cmd[0] = Tcl_NewStringObj("proc", -1); cmd[1] = Tcl_NewStringObj(fullName, -1); cmd[2] = args; cmd[3] = Tcl_NewStringObj(body, -1);
    if (Tcl_IsShared(tbc_capture_defs)) { Tcl_DecrRefCount(tbc_capture_defs); tbc_capture_defs = Tcl_DuplicateObj(tbc_capture_defs); Tcl_IncrRefCount(tbc_capture_defs); }
    if (strcmp(ns, "::") != 0) {
        Tcl_Obj *nsc[3];
        nsc[0] = Tcl_NewStringObj("namespace", -1); nsc[1] = Tcl_NewStringObj("eval", -1); nsc[2] = Tcl_NewStringObj(ns, -1);
        {
            Tcl_Obj *full[4];
            full[0] = nsc[0]; full[1] = nsc[1]; full[2] = nsc[2]; full[3] = Tcl_NewObj();
            Tcl_ListObjAppendElement(NULL, tbc_capture_defs, Tcl_NewListObj(4, full));
        }
    }
    Tcl_ListObjAppendElement(NULL, tbc_capture_defs, Tcl_NewListObj(4, cmd));
}

/* record what became of a proc definition */
static TbcDef *tbc_note_def(Proc *p, const char *fullName, int status, const char *reason) {
    int isNew;
    Tcl_HashEntry *h = Tcl_CreateHashEntry(&tbc_defs_by_name, fullName, &isNew);
    TbcDef *d;
    if (isNew) {
        d = (TbcDef *) ckalloc(sizeof *d);
        d->name = (char *) ckalloc(strlen(fullName) + 1); strcpy(d->name, fullName);
        d->icalls = 0; d->lazyEntry = NULL; d->lazyProc = NULL;
        Tcl_SetHashValue(h, d);
    } else d = (TbcDef *) Tcl_GetHashValue(h);
    d->status = status; d->reason = reason; d->rec = NULL; d->lazyEntry = NULL; d->lazyProc = NULL; d->proc = p;
    h = Tcl_CreateHashEntry(&tbc_defs_by_proc, (char *) p, &isNew);
    Tcl_SetHashValue(h, d);
    return d;
}

/* the interpreter's compile of a body in the context of a proc, fingerprinted (0 if it cannot be compiled) */
static uint64_t tbc_probe(Tcl_Interp *interp, Proc *p, const char *body, const char *name) {
    Tcl_Obj *probe = Tcl_NewStringObj(body, -1);
    uint64_t fp = 0;
    Tcl_IncrRefCount(probe);
    if (TclProcCompileProc(interp, p, probe, p->cmdPtr->nsPtr, "body of proc", name) == TCL_OK && probe->typePtr == &tclByteCodeType)
        fp = tbc_fingerprint((const ByteCode *) probe->internalRep.twoPtrValue.ptr1);
    Tcl_ResetResult(interp);
    Tcl_DecrRefCount(probe);
    return fp;
}

/* replace the proc's compiled code by the stub; returns 1 if done */
/* 1: patched; 0: cannot be; 2: the interpreter's bytecode now is not the one that was compiled (it may be at the proc's first call); 3: the body is
 * shorter than the entry stub (a few instructions: the interpreter runs it faster than a call into compiled code would) */
static int tbc_patch(Tcl_Interp *interp, Proc *p, TbcEntry *e, unsigned char **orig, const char **why) {
    ByteCode *bc;
    Tcl_Obj *cn;
    *why = "the interpreter cannot compile the body";
    if (TclProcCompileProc(interp, p, p->bodyPtr, p->cmdPtr->nsPtr, "body of proc", e->name) != TCL_OK) { Tcl_ResetResult(interp); return 0; }
    if (p->bodyPtr->typePtr != &tclByteCodeType) return 0;
    bc = (ByteCode *) p->bodyPtr->internalRep.twoPtrValue.ptr1;
    if (tbc_fingerprint(bc) != e->fp) { *why = "the interpreter's bytecode for this definition differs from the one that was compiled (a command it uses is redefined or traced, an ensemble changed, or a folded constant differs)"; if (getenv("TBC_DEBUG")) fprintf(stderr, "tbc: %s: bytecode differs from the compiled one\n", e->name); return 2; }
    if (bc->numCodeBytes < 5 || (bc->flags & TCL_BYTECODE_PRECOMPILED)) { *why = (bc->flags & TCL_BYTECODE_PRECOMPILED) ? "the body's bytecode was already replaced" : "trivial body: shorter than the entry stub, and the interpreter runs it faster than a call into compiled code would"; if (getenv("TBC_DEBUG")) fprintf(stderr, "tbc: %s: code too short (%d bytes, %d literals, flags %x)\n", e->name, bc->numCodeBytes, bc->numLitObjects, bc->flags); return (bc->flags & TCL_BYTECODE_PRECOMPILED) ? 0 : 3; }
    cn = Tcl_ObjPrintf("::tbc::e%d", e->id);
    Tcl_IncrRefCount(cn);
    *orig = (unsigned char *) ckalloc((size_t) bc->numCodeBytes);
    memcpy(*orig, bc->codeStart, (size_t) bc->numCodeBytes);
    /* literal 0 becomes our command's name.  Precompiled code holds private references to its literals (released one by one when
     * the code is freed); the global literal table keeps the entries, and the references, it already had. */
    if (bc->numLitObjects < 1) {
        /* a body without literals has no slot for ours: give it a literal array of its own (the one pointer is not freed with the code) */
        bc->objArrayPtr = (Tcl_Obj **) ckalloc(sizeof(Tcl_Obj *));
        bc->numLitObjects = 1;
    }
    bc->objArrayPtr[0] = cn;
    bc->codeStart[0] = INST_PUSH1; bc->codeStart[1] = 0;
    bc->codeStart[2] = INST_INVOKE_STK1; bc->codeStart[3] = 1;
    bc->codeStart[4] = INST_DONE;
    bc->numExceptRanges = 0;
    if (bc->maxStackDepth < 1) bc->maxStackDepth = 1;
    bc->flags |= TCL_BYTECODE_PRECOMPILED;
    return 1;
}

TBC_SHARED int tbc_eager;			/* attach compiled bodies when the procs are defined (TBC_EAGER=1, tbc::attach eager) instead of at their first call */

/* run `trace <add|remove> <kind> <name> <ops> {handler name}` with every word quoted as a list element (names may contain anything) */
static void tbc_trace2(Tcl_Interp *interp, const char *action, const char *kind, const char *name, const char *ops, const char *handler, const char *handlerArg) {
    Tcl_Obj *w[6], *script;
    int n = 0;
    w[n++] = Tcl_NewStringObj("trace", -1); w[n++] = Tcl_NewStringObj(action, -1); w[n++] = Tcl_NewStringObj(kind, -1);
    w[n++] = Tcl_NewStringObj(name, -1); w[n++] = Tcl_NewStringObj(ops, -1);
    if (handlerArg) { Tcl_Obj *hw[2]; hw[0] = Tcl_NewStringObj(handler, -1); hw[1] = Tcl_NewStringObj(handlerArg, -1); w[n++] = Tcl_NewListObj(2, hw); }
    else w[n++] = Tcl_NewStringObj(handler, -1);
    script = Tcl_NewListObj(n, w);
    Tcl_IncrRefCount(script);
    Tcl_EvalObjEx(interp, script, TCL_EVAL_GLOBAL);
    Tcl_DecrRefCount(script);
    Tcl_ResetResult(interp);
}

static void tbc_trace(Tcl_Interp *interp, const char *action, const char *kind, const char *name, const char *ops, const char *handler, int withName) {
    tbc_trace2(interp, action, kind, name, ops, handler, withName ? name : NULL);
}

/* patch the proc with the compiled entry and record it; 1 attached, 2 bytecode differs, 0 cannot */
static int tbc_attach_entry(Tcl_Interp *interp, Proc *p, TbcEntry *e, const char *fullName) {
    unsigned char *orig = NULL;
    const char *why = NULL;
    int rc = tbc_patch(interp, p, e, &orig, &why);
    if (rc != 1) { tbc_note_def(p, fullName, rc == 3 ? TBC_DEF_TRIVIAL : TBC_DEF_DIFFERS, why); return rc; }
    {
        int isNew;
        TbcRec *r = (TbcRec *) ckalloc(sizeof *r);
        Tcl_HashEntry *rh = Tcl_CreateHashEntry(&tbc_recs, (char *) p, &isNew);
        if (!isNew) { TbcRec *old = (TbcRec *) Tcl_GetHashValue(rh); ckfree(old->name); Tcl_DecrRefCount(old->bodyObj); ckfree(old->origCode); ckfree(old); }
        r->origCode = orig;
        r->e = e; r->p = p; r->epoch = ((Interp *) interp)->compileEpoch; r->demoted = 0; r->fresh = 1; r->calls = 0; r->fallbacks = 0;
        tbc_note_def(p, fullName, TBC_DEF_COMPILED, NULL)->rec = r;
        r->name = (char *) ckalloc(strlen(fullName) + 1); strcpy(r->name, fullName);
        r->bodyObj = Tcl_NewStringObj(e->body, -1); Tcl_IncrRefCount(r->bodyObj);
        Tcl_SetHashValue(rh, r);
        /* compiled callers may link directly to it while it stays under its compiled name */
        if (e->valid && strcmp(fullName, e->name) == 0) {
            *e->valid = 1;
            tbc_trace(interp, "add", "command", fullName, "rename delete", "::tbc::invalidate", 1);
        }
    }
    return 1;
}

/* attach at the proc's first call: the interpreter compiles a body then too, so a proc that is never called costs nothing, and the bytecode compared is
 * the one the interpreter has when it runs the proc */
static void tbc_arm_lazy(Tcl_Interp *interp, Proc *p, TbcEntry *e, const char *fullName, int status, const char *reason) {
    TbcDef *d = tbc_note_def(p, fullName, status, reason);
    d->lazyEntry = e; d->lazyProc = p;
    tbc_trace(interp, "add", "execution", fullName, "enter", "::tbc::lazy", 1);
}

/* the proc `fullName` (a command of ours or the program's) has just been defined: attach a compiled body if there is one for it */
static void tbc_attach(Tcl_Interp *interp, Proc *p, struct Namespace *nsPtr, const char *fullName) {
    Tcl_HashEntry *h;
    char *ca, *k;
    if (!tbc_reg_ready) return;
    tbc_invalidate_name(fullName);
    /* a proc defined in a namespace may shadow a global proc of the same name for callers in that namespace */
    if (nsPtr->parentPtr) {
        const char *sn = strrchr(fullName, ':');
        if (sn) {
            Tcl_Obj *g = Tcl_ObjPrintf("::%s", sn + 1);
            tbc_invalidate_name(Tcl_GetString(g));
            Tcl_DecrRefCount(g);
        }
    }
    ca = tbc_canon_args(p);
    k = tbc_key(nsPtr->fullName, ca, Tcl_GetString(p->bodyPtr));
    h = Tcl_FindHashEntry(&tbc_by_body, k);
    if (!h) {
        /* no code for this definition: say why (the translator refused it, the module has code for a different definition of the name, or none) */
        Tcl_HashEntry *rh = Tcl_FindHashEntry(&tbc_refused_by_key, k);
        if (rh) tbc_note_def(p, fullName, TBC_DEF_REFUSED, ((TbcRefused *) Tcl_GetHashValue(rh))->reason);
        else if (Tcl_FindHashEntry(&tbc_by_name, fullName)) tbc_note_def(p, fullName, TBC_DEF_CHANGED, "the module has code for another definition of this name (different body or arguments)");
        else tbc_note_def(p, fullName, TBC_DEF_NOCODE, "not in the module");
        if (tbc_capture_on && !rh) tbc_capture_note(fullName, nsPtr->fullName, ca, Tcl_GetString(p->bodyPtr));
    }
    ckfree(ca);
    ckfree(k);
    if (h) {
        TbcEntry *e = (TbcEntry *) Tcl_GetHashValue(h);
        int rc = tbc_eager ? tbc_attach_entry(interp, p, e, fullName) : 0;
        if (!tbc_eager) tbc_arm_lazy(interp, p, e, fullName, TBC_DEF_PENDING, "compiled code is attached at the proc's first call");
        else if (rc == 2) {
            /* The compile at definition time gave other bytecode than the translator's: that happens when something the compiler looks at changed after
             * the translator's compile (a package that redefines a core command or extends an ensemble: the compile epoch moves, and the interpreter
             * compiles the proc again at its first call).  Look again then, with a one-shot trace on the proc (the interface the program itself has). */
            TbcDef *d = (TbcDef *) Tcl_GetHashValue(Tcl_FindHashEntry(&tbc_defs_by_name, fullName));
            d->lazyEntry = e; d->lazyProc = p;
            tbc_trace(interp, "add", "execution", fullName, "enter", "::tbc::lazy", 1);
        }
    }
}

/* ::tbc::lazy name {cmd args} enter -- the first call of a proc whose bytecode was not the compiled one when it was defined: the interpreter compiles
 * it now, at the current compile epoch, so the check is made again.  One-shot. */
static int tbc_lazy_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_HashEntry *h;
    Tcl_CmdInfo ci;
    TbcDef *d;
    const char *armed, *name;
    Tcl_Command tok;
    Tcl_Obj *full;
    (void) cd;
    if (objc < 2 || !tbc_reg_ready) return TCL_OK;
    armed = Tcl_GetString(objv[1]);
    name = armed;
    h = Tcl_FindHashEntry(&tbc_defs_by_name, armed);
    d = h ? (TbcDef *) Tcl_GetHashValue(h) : NULL;
    /* the command this call is to: the proc under the name it was armed with, or, if it has been renamed since, under the name it is being called by */
    if (!d || !d->lazyEntry || !Tcl_GetCommandInfo(interp, armed, &ci) || ci.objProc != TclObjInterpProc || (Proc *) ci.objClientData != d->lazyProc) {
        Tcl_Obj **w; int n;
        if (objc < 3 || Tcl_ListObjGetElements(NULL, objv[2], &n, &w) != TCL_OK || n < 1) return TCL_OK;
        name = Tcl_GetString(w[0]);
        if (!d || !d->lazyEntry || !Tcl_GetCommandInfo(interp, name, &ci) || ci.objProc != TclObjInterpProc || (Proc *) ci.objClientData != d->lazyProc) {
            /* not this proc (an alias, or a later definition of the name): leave the trace, which goes with its command */
            return TCL_OK;
        }
    }
    tok = Tcl_FindCommand(interp, name, NULL, 0);
    if (!tok) return TCL_OK;
    full = Tcl_NewObj();
    Tcl_IncrRefCount(full);
    Tcl_GetCommandFullName(interp, tok, full);
    tbc_trace2(interp, "remove", "execution", Tcl_GetString(full), "enter", "::tbc::lazy", armed);
    {
        TbcEntry *e = d->lazyEntry;
        Proc *p = d->lazyProc;
        d->lazyEntry = NULL; d->lazyProc = NULL;
        if (tbc_attach_entry(interp, p, e, Tcl_GetString(full)) == 2) {
            TbcDef *nd = (TbcDef *) Tcl_GetHashValue(Tcl_FindHashEntry(&tbc_defs_by_name, Tcl_GetString(full)));
            nd->reason = "the interpreter's bytecode for this definition differs from the compiled one, also at its first call";
        }
    }
    Tcl_DecrRefCount(full);
    return TCL_OK;
}

/* `proc` itself, with the interpreter's own implementation called first and a look at what it defined afterwards: no trace on `proc`, so no copy of every
 * body as a list element (the trace interface passes the command as one) and nothing for `trace info execution` to show.  It is the same command (a
 * rename, an alias or a trace of the program's follows it) with the C function behind it wrapped. */
TBC_SHARED Tcl_ObjCmdProc *tbc_orig_proc;
TBC_SHARED ClientData tbc_orig_proc_cd;

static int tbc_proc_wrap(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Namespace *nsPtr, *altPtr, *cxtPtr;
    const char *simple;
    Tcl_Command tok;
    Tcl_CmdInfo ci;
    Tcl_Obj *full;
    int rc = tbc_orig_proc(tbc_orig_proc_cd, interp, objc, objv);
    (void) cd;
    if (rc != TCL_OK || objc != 4) return rc;
    /* the namespace the interpreter defined the proc in: the one of the variable frame */
    TclGetNamespaceForQualName(interp, Tcl_GetString(objv[1]), ((Interp *) interp)->varFramePtr->nsPtr, 0, &nsPtr, &altPtr, &cxtPtr, &simple);
    if (!nsPtr || !simple) return rc;
    tok = Tcl_FindCommand(interp, simple, (Tcl_Namespace *) nsPtr, TCL_NAMESPACE_ONLY);
    if (!tok || !Tcl_GetCommandInfoFromToken(tok, &ci) || ci.objProc != TclObjInterpProc) return rc;
    full = Tcl_NewObj();
    Tcl_IncrRefCount(full);
    Tcl_GetCommandFullName(interp, tok, full);
    tbc_attach(interp, (Proc *) ci.objClientData, nsPtr, Tcl_GetString(full));
    Tcl_DecrRefCount(full);
    return rc;
}

/* the interpreter fallback: run the proc's body, as written, in the frame that is already set up */
/* the interpreter runs the body itself, on its non-recursive stack (so that a coroutine can suspend inside it): when the compiled code has been
 * invalidated, or when the call is inside a coroutine, which may yield from any depth below it -- compiled code runs on the C stack and cannot
 * be suspended.  The body is compiled by the interpreter in the context of the proc, as the proc's own would be (same locals, same location
 * information), and executed in the frame the call has already set up; the stub's command frame and nesting level are stepped over so that the
 * body sees what it would see without the stub, and the interpreter's own error logging stays the interpreter's. */
static int tbc_levels_back(ClientData data[], Tcl_Interp *interp, int result) {
    Interp *iPtr = (Interp *) interp;
    iPtr->numLevels++;
    if (data[0]) iPtr->cmdFramePtr = (CmdFrame *) data[0];
    if (result == TCL_ERROR) iPtr->flags |= ERR_ALREADY_LOGGED;
    return result;
}
static int tbc_fallback(Tcl_Interp *interp, TbcRec *r) {
    Interp *iPtr = (Interp *) interp;
    Proc *p = iPtr->varFramePtr->procPtr;
    CmdFrame *stub = iPtr->cmdFramePtr;
    if (TclProcCompileProc(interp, p, r->bodyObj, p->cmdPtr->nsPtr, "body of proc", r->name) != TCL_OK) return TCL_ERROR;
    if (r->bodyObj->typePtr != &tclByteCodeType) return Tcl_NREvalObj(interp, r->bodyObj, 0);
    iPtr->numLevels--;
    Tcl_NRAddCallback(interp, tbc_levels_back, stub, NULL, NULL, NULL);
    if (stub) iPtr->cmdFramePtr = stub->nextPtr;
    return TclNRExecuteByteCode(interp, (ByteCode *) r->bodyObj->internalRep.twoPtrValue.ptr1);
}

static int tbc_enter_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    return Tcl_NRCallObjProc(interp, tbc_enter_nr, cd, objc, objv);
}

static int tbc_enter_nr(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Interp *iPtr = (Interp *) interp;
    Proc *p = iPtr->varFramePtr->procPtr;
    Tcl_HashEntry *h = p ? Tcl_FindHashEntry(&tbc_recs, (char *) p) : NULL;
    TbcRec *r;
    (void) cd; (void) objc; (void) objv;
    if (!h) { Tcl_SetObjResult(interp, Tcl_NewStringObj("tbc: compiled body entered by a proc it was not attached to", -1)); return TCL_ERROR; }
    r = (TbcRec *) Tcl_GetHashValue(h);
    if (r->epoch != iPtr->compileEpoch && !r->demoted) {
        /* something the compiler looks at may have changed (a core command redefined, a resolver, an ensemble...): the interpreter
         * would recompile now, so compile the body the same way and see whether it is still the code that was translated */
        r->epoch = iPtr->compileEpoch;
        if (tbc_probe(interp, p, r->e->body, r->name) != r->e->fp) { r->demoted = 1; if (r->e->valid) *r->e->valid = 0; }
    }
    if (r->demoted || iPtr->execEnvPtr->corPtr || (TBC_NEST_CAP && tbc_nest >= TBC_NEST_CAP)) { r->fallbacks++; return tbc_fallback(interp, r); }
    r->calls++;
    if (r->fresh) { r->fresh = 0; iPtr->errorLine = 1; }
    {   /* the interpreter reports the frame of a body that came from the program as source, not as "precompiled" (the stub's flag) */
        CmdFrame *cf = iPtr->cmdFramePtr;
        if (cf && cf->type == TCL_LOCATION_PREBC && cf->data.tebc.codePtr && (void *) cf->data.tebc.codePtr == (void *) p->bodyPtr->internalRep.twoPtrValue.ptr1) cf->type = TCL_LOCATION_BC;
    }
    {
        /* the stub's own invocation of this command is a nesting level the interpreter does not have: give it back while the body runs, so that
         * the depth the body's calls see (and the recursion limit they hit) is the interpreter's */
        int code;
        iPtr->numLevels--;
        tbc_nest++;
        code = r->e->fn(interp, p);
        tbc_nest--;
        iPtr->numLevels++;
        /* the body has logged its own errors (tbc_logerr); the stub that called it must not add a line of its own */
        if (code == TCL_ERROR) iPtr->flags |= ERR_ALREADY_LOGGED;
        return code;
    }
}

static int tbc_inval_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_HashEntry *h;
    (void) cd; (void) interp;
    if (objc < 2 || !tbc_reg_ready) return TCL_OK;
    tbc_invalidate_name(Tcl_GetString(objv[1]));
    return TCL_OK;
}

/* tbc::fingerprint ::proc -- the fingerprint of a proc's compiled body (used by the ahead-of-time tool) */
static int tbc_fp_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_CmdInfo ci;
    Proc *p;
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "procname"); return TCL_ERROR; }
    if (!Tcl_GetCommandInfo(interp, Tcl_GetString(objv[1]), &ci) || ci.objProc != TclObjInterpProc) { Tcl_SetObjResult(interp, Tcl_NewStringObj("not a proc", -1)); return TCL_ERROR; }
    p = (Proc *) ci.objClientData;
    if (TclProcCompileProc(interp, p, p->bodyPtr, p->cmdPtr->nsPtr, "body of proc", Tcl_GetString(objv[1])) != TCL_OK) return TCL_ERROR;
    if (p->bodyPtr->typePtr != &tclByteCodeType) { Tcl_SetObjResult(interp, Tcl_NewStringObj("not compiled", -1)); return TCL_ERROR; }
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("%llx", (unsigned long long) tbc_fingerprint((const ByteCode *) p->bodyPtr->internalRep.twoPtrValue.ptr1)));
    return TCL_OK;
}

/* tbc::attached -- the procs that currently run a compiled body */
static int tbc_attached_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_HashSearch hs;
    Tcl_HashEntry *h;
    Tcl_Obj *r = Tcl_NewListObj(0, NULL);
    (void) cd; (void) objc; (void) objv;
    if (tbc_reg_ready) {
        for (h = Tcl_FirstHashEntry(&tbc_recs, &hs); h; h = Tcl_NextHashEntry(&hs)) {
            TbcRec *rec = (TbcRec *) Tcl_GetHashValue(h);
            Tcl_CmdInfo ci;
            if (Tcl_GetCommandInfo(interp, rec->name, &ci) && ci.objProc == TclObjInterpProc && (Proc *) ci.objClientData == rec->p && !rec->demoted)
                Tcl_ListObjAppendElement(NULL, r, Tcl_NewStringObj(rec->name, -1));
        }
    }
    Tcl_SetObjResult(interp, r);
    return TCL_OK;
}

/* ---- tbc::profile and tbc::report: what runs compiled and what is left to the interpreter, and why.
 * The report needs nothing at run time beyond the records made when procs are defined.  Calls of the interpreter's procs, and the scripts the
 * program evaluates at run time (eval, uplevel, namespace eval, source, apply), are only counted while the profile is on: that uses Tcl's own
 * command-trace interface with inline compilation allowed, so no code is recompiled and nothing attached is disturbed. */
typedef struct TbcScript {
    const char *kind;
    char *head;				/* the first part of the text */
    unsigned long count, chars;
} TbcScript;
TBC_SHARED Tcl_HashTable tbc_scripts;
TBC_SHARED int tbc_scripts_ready, tbc_prof_on;
TBC_SHARED Tcl_Trace tbc_prof_trace;
TBC_SHARED unsigned long tbc_scripts_dropped;

static int tbc_def_interpreted(const TbcDef *d) { return (d->status != TBC_DEF_COMPILED && d->status != TBC_DEF_PENDING) || (d->rec && d->rec->demoted); }
static const char *tbc_def_word(const TbcDef *d) {
    if (d->status == TBC_DEF_COMPILED) return d->rec && d->rec->demoted ? "demoted" : "compiled";
    switch (d->status) {
    case TBC_DEF_NOCODE: return "no-code"; case TBC_DEF_CHANGED: return "changed"; case TBC_DEF_DIFFERS: return "differs";
    case TBC_DEF_REFUSED: return "refused"; case TBC_DEF_TRIVIAL: return "trivial"; case TBC_DEF_PENDING: return "pending"; default: return "early";
    }
}
static const char *tbc_def_why(const TbcDef *d) {
    if (d->status == TBC_DEF_COMPILED && d->rec && d->rec->demoted) return "the interpreter's bytecode changed after the compiled code was attached (a command it uses was redefined or traced)";
    return d->reason ? d->reason : "";
}

static void tbc_note_script(const char *kind, Tcl_Obj *const *words, int n) {
    Tcl_DString ds;
    char key[320];
    int i, len;
    const char *text;
    Tcl_HashEntry *h;
    int isNew;
    TbcScript *sc;
    if (!tbc_scripts_ready) { Tcl_InitHashTable(&tbc_scripts, TCL_STRING_KEYS); tbc_scripts_ready = 1; }
    Tcl_DStringInit(&ds);
    for (i = 0; i < n; i++) { if (i) Tcl_DStringAppend(&ds, " ", 1); Tcl_DStringAppend(&ds, Tcl_GetString(words[i]), -1); }
    text = Tcl_DStringValue(&ds); len = Tcl_DStringLength(&ds);
    snprintf(key, sizeof key, "%s:%d:%.200s", kind, len, text);
    if (tbc_scripts.numEntries >= 20000 && !Tcl_FindHashEntry(&tbc_scripts, key)) { tbc_scripts_dropped++; Tcl_DStringFree(&ds); return; }
    h = Tcl_CreateHashEntry(&tbc_scripts, key, &isNew);
    if (isNew) {
        sc = (TbcScript *) ckalloc(sizeof *sc);
        sc->kind = kind; sc->count = 0; sc->chars = (unsigned long) len;
        sc->head = (char *) ckalloc(121); strncpy(sc->head, text, 120); sc->head[120] = 0;
        Tcl_SetHashValue(h, sc);
    } else sc = (TbcScript *) Tcl_GetHashValue(h);
    sc->count++;
    Tcl_DStringFree(&ds);
}

static int tbc_prof_cb(ClientData cd, Tcl_Interp *interp, int level, const char *cmdString, Tcl_Command tok, int objc, Tcl_Obj *const objv[]) {
    Tcl_CmdInfo ci;
    (void) cd; (void) level; (void) cmdString;
    if (!Tcl_GetCommandInfoFromToken(tok, &ci)) return TCL_OK;
    if (ci.objProc == TclObjInterpProc) {
        Tcl_HashEntry *h = Tcl_FindHashEntry(&tbc_defs_by_proc, (char *) ci.objClientData);
        TbcDef *d;
        if (!h) {
            Tcl_Obj *full = Tcl_NewObj();
            Tcl_IncrRefCount(full);
            Tcl_GetCommandFullName(interp, tok, full);
            {   /* does the module have code for this definition?  If so the program only needs to load it first; if not it is simply not in the module */
                Proc *pp = (Proc *) ci.objClientData;
                char *ca = tbc_canon_args(pp);
                char *k = tbc_key(pp->cmdPtr->nsPtr->fullName, ca, Tcl_GetString(pp->bodyPtr));
                int have = Tcl_FindHashEntry(&tbc_by_body, k) != NULL;
                ckfree(ca); ckfree(k);
                d = have ? tbc_note_def(pp, Tcl_GetString(full), TBC_DEF_EARLY, "defined before the module was loaded: the module has code for it, but it was never offered it (load the module first)")
                         : tbc_note_def(pp, Tcl_GetString(full), TBC_DEF_NOCODE, "not in the module (defined before it was loaded)");
            }
            Tcl_DecrRefCount(full);
        } else d = (TbcDef *) Tcl_GetHashValue(h);
        if (tbc_def_interpreted(d)) d->icalls++;
        return TCL_OK;
    }
    if (((Command *) tok)->nsPtr == ((Interp *) interp)->globalNsPtr && objc >= 2) {
        const char *nm = Tcl_GetCommandName(interp, tok);
        if (strcmp(nm, "eval") == 0) tbc_note_script("eval", objv + 1, objc - 1);
        else if (strcmp(nm, "uplevel") == 0) {
            const char *l = Tcl_GetString(objv[1]);
            int skip = (objc > 2 && (l[0] == '#' || (l[0] >= '0' && l[0] <= '9'))) ? 2 : 1;
            tbc_note_script("uplevel", objv + skip, objc - skip);
        } else if (strcmp(nm, "source") == 0) tbc_note_script("source", objv + objc - 1, 1);
        else if (strcmp(nm, "apply") == 0) tbc_note_script("apply", objv + 1, 1);
        else if (strcmp(nm, "namespace") == 0 && objc >= 4 && strcmp(Tcl_GetString(objv[1]), "eval") == 0) tbc_note_script("namespace eval", objv + 3, objc - 3);
    }
    return TCL_OK;
}

static void tbc_scripts_reset(void) {
    Tcl_HashSearch hs;
    Tcl_HashEntry *h;
    if (tbc_scripts_ready) {
        for (h = Tcl_FirstHashEntry(&tbc_scripts, &hs); h; h = Tcl_NextHashEntry(&hs)) { TbcScript *sc = (TbcScript *) Tcl_GetHashValue(h); ckfree(sc->head); ckfree(sc); }
        Tcl_DeleteHashTable(&tbc_scripts);
        tbc_scripts_ready = 0;
    }
    tbc_scripts_dropped = 0;
    if (tbc_reg_ready) {
        for (h = Tcl_FirstHashEntry(&tbc_defs_by_name, &hs); h; h = Tcl_NextHashEntry(&hs)) ((TbcDef *) Tcl_GetHashValue(h))->icalls = 0;
    }
}

/* tbc::capture on|off|clear|count|get|write path -- the definitions of procs without compiled code, made while it is on, as Tcl commands */
static int tbc_capture_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *a;
    (void) cd;
    if (objc < 2 || objc > 3) { Tcl_WrongNumArgs(interp, 1, objv, "on|off|clear|count|get|write path"); return TCL_ERROR; }
    a = Tcl_GetString(objv[1]);
    if (strcmp(a, "on") == 0) tbc_capture_on = 1;
    else if (strcmp(a, "off") == 0) tbc_capture_on = 0;
    else if (strcmp(a, "clear") == 0) {
        if (tbc_capture_ready) { Tcl_DeleteHashTable(&tbc_capture_seen); Tcl_DecrRefCount(tbc_capture_defs); tbc_capture_ready = 0; }
    } else if (strcmp(a, "count") == 0) {
        Tcl_SetObjResult(interp, Tcl_NewIntObj(tbc_capture_ready ? tbc_capture_seen.numEntries : 0));
        return TCL_OK;
    } else if (strcmp(a, "get") == 0 || strcmp(a, "write") == 0) {
        Tcl_Obj *text = Tcl_NewObj();
        int n = 0, i;
        Tcl_Obj **w;
        if (tbc_capture_ready) Tcl_ListObjGetElements(NULL, tbc_capture_defs, &n, &w);
        for (i = 0; i < n; i++) { Tcl_AppendObjToObj(text, w[i]); Tcl_AppendToObj(text, "\n", 1); }
        if (a[0] == 'g') { Tcl_SetObjResult(interp, text); return TCL_OK; }
        if (objc != 3) { Tcl_WrongNumArgs(interp, 2, objv, "path"); return TCL_ERROR; }
        {
            Tcl_Channel ch = Tcl_OpenFileChannel(interp, Tcl_GetString(objv[2]), "w", 0666);
            int len;
            const char *bytes;
            if (!ch) { Tcl_DecrRefCount(text); return TCL_ERROR; }
            Tcl_SetChannelOption(NULL, ch, "-encoding", "utf-8");
            bytes = Tcl_GetStringFromObj(text, &len);
            Tcl_Write(ch, bytes, len);
            Tcl_Close(interp, ch);
            Tcl_DecrRefCount(text);
        }
    } else {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("bad option: must be on, off, clear, count, get or write", -1));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(tbc_capture_on));
    return TCL_OK;
}

/* tbc::attach eager|lazy|status -- when compiled bodies are attached: at the proc's first call (the default; a proc that is never called costs nothing),
 * or when it is defined (also TBC_EAGER=1 in the environment) */
static int tbc_attach_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *a;
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "eager|lazy|status"); return TCL_ERROR; }
    a = Tcl_GetString(objv[1]);
    if (strcmp(a, "eager") == 0) tbc_eager = 1;
    else if (strcmp(a, "lazy") == 0) tbc_eager = 0;
    else if (strcmp(a, "status") != 0) { Tcl_SetObjResult(interp, Tcl_NewStringObj("bad option: must be eager, lazy or status", -1)); return TCL_ERROR; }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(tbc_eager ? "eager" : "lazy", -1));
    return TCL_OK;
}

/* tbc::profile on|off|reset|status */
static int tbc_profile_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    const char *a;
    (void) cd;
    if (objc != 2) { Tcl_WrongNumArgs(interp, 1, objv, "on|off|reset|status"); return TCL_ERROR; }
    a = Tcl_GetString(objv[1]);
    if (strcmp(a, "on") == 0) {
        if (!tbc_prof_on) { tbc_prof_trace = Tcl_CreateObjTrace(interp, 1000000, TCL_ALLOW_INLINE_COMPILATION, tbc_prof_cb, NULL, NULL); tbc_prof_on = 1; }
    } else if (strcmp(a, "off") == 0) {
        if (tbc_prof_on) { Tcl_DeleteTrace(interp, tbc_prof_trace); tbc_prof_on = 0; }
    } else if (strcmp(a, "reset") == 0) {
        tbc_scripts_reset();
    } else if (strcmp(a, "status") != 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("bad option: must be on, off, reset or status", -1));
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(tbc_prof_on));
    return TCL_OK;
}

static int tbc_def_cmp(const void *a, const void *b) {
    const TbcDef *x = *(TbcDef *const *) a, *y = *(TbcDef *const *) b;
    if (x->icalls != y->icalls) return x->icalls < y->icalls ? 1 : -1;
    return strcmp(x->name, y->name);
}
static int tbc_script_cmp(const void *a, const void *b) {
    const TbcScript *x = *(TbcScript *const *) a, *y = *(TbcScript *const *) b;
    if (x->count != y->count) return x->count < y->count ? 1 : -1;
    return strcmp(x->head, y->head);
}

/* tbc::report ?-text?  -- a dict: compiled, compiled_calls, coroutine_calls, interpreted, interpreted_calls (while profiling), profile,
 * procs {{name state reason calls}...} (the interpreted ones, most called first), scripts {{kind count chars head}...} (most evaluated first);
 * with -text the same as a table. */
static int tbc_report_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_HashSearch hs;
    Tcl_HashEntry *h;
    TbcDef **ds = NULL;
    TbcScript **ss = NULL;
    int nd = 0, ns = 0, i, text = 0, ncomp = 0, npend = 0;
    Tcl_Obj *pendNames = Tcl_NewListObj(0, NULL);
    unsigned long ccalls = 0, cocalls = 0, icalls = 0;
    (void) cd;
    if (objc > 2 || (objc == 2 && strcmp(Tcl_GetString(objv[1]), "-text") != 0)) { Tcl_WrongNumArgs(interp, 1, objv, "?-text?"); return TCL_ERROR; }
    text = objc == 2;
    if (tbc_reg_ready) {
        ds = (TbcDef **) ckalloc((size_t) (tbc_defs_by_name.numEntries + 1) * sizeof *ds);
        for (h = Tcl_FirstHashEntry(&tbc_defs_by_name, &hs); h; h = Tcl_NextHashEntry(&hs)) {
            TbcDef *d = (TbcDef *) Tcl_GetHashValue(h);
            Tcl_CmdInfo ci;
            /* a proc that was deleted or defined again since is not reported */
            if (!Tcl_GetCommandInfo(interp, d->name, &ci) || ci.objProc != TclObjInterpProc || (Proc *) ci.objClientData != d->proc) continue;
            if (d->rec) { ccalls += d->rec->calls; cocalls += d->rec->fallbacks; }
            if (d->status == TBC_DEF_PENDING) { npend++; Tcl_ListObjAppendElement(NULL, pendNames, Tcl_NewStringObj(d->name, -1)); }
            else if (tbc_def_interpreted(d)) { ds[nd++] = d; icalls += d->icalls; } else ncomp++;
        }
        qsort(ds, (size_t) nd, sizeof *ds, tbc_def_cmp);
    }
    if (tbc_scripts_ready) {
        ss = (TbcScript **) ckalloc((size_t) (tbc_scripts.numEntries + 1) * sizeof *ss);
        for (h = Tcl_FirstHashEntry(&tbc_scripts, &hs); h; h = Tcl_NextHashEntry(&hs)) ss[ns++] = (TbcScript *) Tcl_GetHashValue(h);
        qsort(ss, (size_t) ns, sizeof *ss, tbc_script_cmp);
    }
    if (text) {
        Tcl_Obj *o = Tcl_ObjPrintf("procs run compiled: %d (%lu calls; %lu more ran the interpreter's version because they were inside a coroutine or demoted)\n"
                "procs with compiled code waiting for their first call: %d\n"
                "procs left to the interpreter: %d%s\n", ncomp, ccalls, cocalls, npend, nd, tbc_prof_on ? "" : "   (turn tbc::profile on to count their calls and the scripts evaluated)");
        if (tbc_prof_on || icalls) Tcl_AppendPrintfToObj(o, "calls of those procs while profiling: %lu\n", icalls);
        for (i = 0; i < nd; i++) Tcl_AppendPrintfToObj(o, "  %-9s %10lu  %s  -- %s\n", tbc_def_word(ds[i]), ds[i]->icalls, ds[i]->name, tbc_def_why(ds[i]));
        if (ns) {
            Tcl_AppendPrintfToObj(o, "scripts evaluated at run time (while profiling): %d distinct%s\n", ns, tbc_scripts_dropped ? " (more were not recorded)" : "");
            for (i = 0; i < ns; i++) {
                char head[121]; int k;
                strcpy(head, ss[i]->head);
                for (k = 0; head[k]; k++) if (head[k] == '\n' || head[k] == '\t') head[k] = ' ';
                Tcl_AppendPrintfToObj(o, "  %-14s %8lu x %8lu chars  %s\n", ss[i]->kind, ss[i]->count, ss[i]->chars, head);
            }
        }
        Tcl_SetObjResult(interp, o);
    } else {
        Tcl_Obj *r = Tcl_NewDictObj(), *pl = Tcl_NewListObj(0, NULL), *sl = Tcl_NewListObj(0, NULL);
        for (i = 0; i < nd; i++) {
            Tcl_Obj *e[4];
            e[0] = Tcl_NewStringObj(ds[i]->name, -1); e[1] = Tcl_NewStringObj(tbc_def_word(ds[i]), -1);
            e[2] = Tcl_NewStringObj(tbc_def_why(ds[i]), -1); e[3] = Tcl_NewWideIntObj((Tcl_WideInt) ds[i]->icalls);
            Tcl_ListObjAppendElement(NULL, pl, Tcl_NewListObj(4, e));
        }
        for (i = 0; i < ns; i++) {
            Tcl_Obj *e[4];
            e[0] = Tcl_NewStringObj(ss[i]->kind, -1); e[1] = Tcl_NewWideIntObj((Tcl_WideInt) ss[i]->count);
            e[2] = Tcl_NewWideIntObj((Tcl_WideInt) ss[i]->chars); e[3] = Tcl_NewStringObj(ss[i]->head, -1);
            Tcl_ListObjAppendElement(NULL, sl, Tcl_NewListObj(4, e));
        }
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("compiled", -1), Tcl_NewIntObj(ncomp));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("compiled_calls", -1), Tcl_NewWideIntObj((Tcl_WideInt) ccalls));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("coroutine_calls", -1), Tcl_NewWideIntObj((Tcl_WideInt) cocalls));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("pending", -1), Tcl_NewIntObj(npend));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("pending_procs", -1), pendNames);
        pendNames = NULL;
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("interpreted", -1), Tcl_NewIntObj(nd));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("interpreted_calls", -1), Tcl_NewWideIntObj((Tcl_WideInt) icalls));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("profile", -1), Tcl_NewIntObj(tbc_prof_on));
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("procs", -1), pl);
        Tcl_DictObjPut(NULL, r, Tcl_NewStringObj("scripts", -1), sl);
        Tcl_SetObjResult(interp, r);
    }
    if (pendNames) Tcl_DecrRefCount(pendNames);
    if (ds) ckfree(ds);
    if (ss) ckfree(ss);
    return TCL_OK;
}

/* The generated code uses the headers' own macros and structure layouts (object allocation, variables, frames), so it is only valid in the Tcl it was
 * compiled against: the same version and the same threading and memory-debugging configuration.  A mismatch is refused when the module loads
 * (an inline TclNewObj from a build with another allocator would otherwise take objects from a pool nothing refills). */
static int tbc_check_build(Tcl_Interp *interp) {
    const char *th = Tcl_GetVar2(interp, "tcl_platform", "threaded", TCL_GLOBAL_ONLY);
    int threaded = th && th[0] == '1', md;
    Tcl_Obj *v;
#ifdef TCL_THREADS
    const int want_threads = 1;
#else
    const int want_threads = 0;
#endif
#ifdef USE_THREAD_ALLOC
    const int want_alloc = 1;
#else
    const int want_alloc = 0;
#endif
#ifdef TCL_MEM_DEBUG
    const int want_md = 1;
#else
    const int want_md = 0;
#endif
    if (threaded != (want_threads != 0) || (want_threads && !want_alloc)) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("this module was compiled %s TCL_THREADS and %s USE_THREAD_ALLOC, which is not how this Tcl was built: compile it with the flags of the Tcl it loads into",
                want_threads ? "with" : "without", want_alloc ? "with" : "without"));
        return TCL_ERROR;
    }
    if (Tcl_Eval(interp, "::tcl::pkgconfig get memdebug") == TCL_OK) {
        v = Tcl_GetObjResult(interp);
        md = 0;
        Tcl_GetBooleanFromObj(NULL, v, &md);
        if (md != want_md) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("this module was compiled with a different TCL_MEM_DEBUG setting than this Tcl", -1));
            return TCL_ERROR;
        }
    }
    Tcl_ResetResult(interp);
    {
        int major, minor, type;
        Tcl_GetVersion(&major, &minor, NULL, &type);
        if (major != TCL_MAJOR_VERSION || minor != TCL_MINOR_VERSION) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("this module was compiled for Tcl %d.%d, not %d.%d", TCL_MAJOR_VERSION, TCL_MINOR_VERSION, major, minor));
            return TCL_ERROR;
        }
    }
    {
        const char *pl = Tcl_GetVar(interp, "tcl_patchLevel", TCL_GLOBAL_ONLY);
        if (pl && strcmp(pl, TCL_PATCH_LEVEL) != 0) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("this module was compiled for Tcl %s (the internals it uses are checked for that release only), not %s", TCL_PATCH_LEVEL, pl));
            return TCL_ERROR;
        }
    }
    return TCL_OK;
}

/* called from a module's Init: the helper commands and the trace that notices new procs (once per interpreter) */
/* is there a namespace other than the global one with a tcl::mathfunc child that holds commands? */
static int tbc_mf_shadowed(Namespace *ns, int top) {
    Tcl_HashSearch search;
    Tcl_HashEntry *h;
    if (!top) {
        Tcl_HashEntry *t = Tcl_FindHashEntry(&ns->childTable, "tcl");
        if (t) {
            Tcl_HashEntry *m = Tcl_FindHashEntry(&((Namespace *) Tcl_GetHashValue(t))->childTable, "mathfunc");
            if (m && ((Namespace *) Tcl_GetHashValue(m))->cmdTable.numEntries > 0) return 1;
        }
    }
    for (h = Tcl_FirstHashEntry(&ns->childTable, &search); h; h = Tcl_NextHashEntry(&search)) {
        if (tbc_mf_shadowed((Namespace *) Tcl_GetHashValue(h), 0)) return 1;
    }
    return 0;
}

static void tbc_mf_setup(Tcl_Interp *interp) {
    static const char *const names[] = { "abs", "acos", "asin", "atan", "atan2", "bool", "ceil", "cos", "cosh", "double", "entier", "exp", "floor", "fmod",
        "hypot", "int", "isqrt", "log", "log10", "pow", "rand", "round", "sin", "sinh", "sqrt", "srand", "tan", "tanh", "wide", NULL };
    int i, ok = 1;
    for (i = 0; names[i]; i++) {
        Tcl_CmdInfo ci;
        Tcl_Obj *full = Tcl_ObjPrintf("::tcl::mathfunc::%s", names[i]);
        Tcl_IncrRefCount(full);
        if (!Tcl_GetCommandInfo(interp, Tcl_GetString(full), &ci) || !ci.isNativeObjectProc || ci.objProc == TclObjInterpProc) ok = 0;
        else tbc_trace(interp, "add", "command", Tcl_GetString(full), "rename delete", "::tbc::invalidate", 1);
        Tcl_DecrRefCount(full);
    }
    if (ok && tbc_mf_shadowed(((Interp *) interp)->globalNsPtr, 1)) ok = 0;
    tbc_mf_ok = ok;
}

static void tbc_install(Tcl_Interp *interp) {
    static int done;
    tbc_reg_init();
    if (done) return;
    done = 1;
    Tcl_CreateObjCommand(interp, "::tbc::invalidate", tbc_inval_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::fingerprint", tbc_fp_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::attached", tbc_attached_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::report", tbc_report_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::profile", tbc_profile_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::capture", tbc_capture_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::lazy", tbc_lazy_cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::tbc::attach", tbc_attach_cmd, NULL, NULL);
    tbc_mf_setup(interp);
    if (getenv("TBC_EAGER") && getenv("TBC_EAGER")[0] == '1') tbc_eager = 1;
    {
        Tcl_CmdInfo ci;
        if (Tcl_GetCommandInfo(interp, "::proc", &ci) && ci.isNativeObjectProc && ci.objProc == Tcl_ProcObjCmd) {
            tbc_orig_proc = ci.objProc; tbc_orig_proc_cd = ci.objClientData;
            ci.objProc = tbc_proc_wrap;
            Tcl_SetCommandInfo(interp, "::proc", &ci);
        }
    }
}

#endif
