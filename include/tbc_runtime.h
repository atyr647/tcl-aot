/* tbc_runtime.h -- runtime support for the C that translate.tcl generates from Tcl 8.6 bytecode.
 *
 * Boxed code keeps the bytecode's operand stack in C variables s0..sN and a proc's locals in l0..lN or in the interpreter's call frame, all
 * Tcl_Obj pointers, and follows the interpreter's reference-counting rules (the stack and each variable own one reference).  Integer and double
 * arithmetic has inline fast paths; everything else (strings that look like numbers, bignums, errors) goes through Tcl's own ::tcl::mathop
 * commands, so results and error messages are the interpreter's.  Typed code keeps integers and doubles in C variables and leaves for the boxed
 * code (the D labels of the generated functions) when an assumption fails.
 *
 * A few internal Tcl functions are used (declared below, or in tclInt.h through tbc_hook.h); they are plain exported symbols of a statically
 * linked libtcl.  Because of that a generated module is valid for one Tcl release only; tbc_check_build refuses to load it into another.
 */
#ifndef TBC_RUNTIME_H
#define TBC_RUNTIME_H

#include <tcl.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <math.h>

extern Tcl_Obj *TclLsetList(Tcl_Interp *, Tcl_Obj *listPtr, Tcl_Obj *indexArgPtr, Tcl_Obj *valuePtr);
extern Tcl_Obj *TclLindexList(Tcl_Interp *, Tcl_Obj *listPtr, Tcl_Obj *argPtr);
extern int TclIncrObj(Tcl_Interp *, Tcl_Obj *valuePtr, Tcl_Obj *incrPtr);
extern void TclExprFloatError(Tcl_Interp *, double value);   /* "domain error" for NaN results, as expr raises */

#define TBC_INLINE static inline __attribute__((always_inline))
#define TBC_UNLIKELY(x) __builtin_expect(!!(x), 0)
#define TBC_LIKELY(x) __builtin_expect(!!(x), 1)

/* The state the compiled code shares.  A module in one file keeps it static.  A module split over several files (translate.tcl -split) defines it in one of them
 * (TBC_SPLIT_OWNER, the file with the module's Init) and the others declare it (TBC_SPLIT_USER). */
#if defined(TBC_SPLIT_OWNER)
# define TBC_SHARED
#elif defined(TBC_SPLIT_USER)
# define TBC_SHARED extern
#else
# define TBC_SHARED static
#endif
TBC_SHARED const Tcl_ObjType *tbcInt, *tbcWide, *tbcDouble, *tbcString, *tbcList;
TBC_SHARED Tcl_Obj *tbcZero, *tbcOne, *tbcEmpty;
enum { TBC_ADD, TBC_SUB, TBC_MULT, TBC_DIV, TBC_MOD, TBC_LT, TBC_LE, TBC_GT, TBC_GE, TBC_EQ, TBC_NEQ, TBC_BAND, TBC_BOR, TBC_BXOR, TBC_SHL, TBC_SHR, TBC_POW, TBC_NEG, TBC_POS, TBC_BNOT, TBC_LNOT, TBC_NOPS };
TBC_SHARED Tcl_Obj *tbcMathop[TBC_NOPS];

static void tbc_rt_init(void) {
    static int done;
    static const char *const names[TBC_NOPS] = { "::tcl::mathop::+", "::tcl::mathop::-", "::tcl::mathop::*", "::tcl::mathop::/",
        "::tcl::mathop::%", "::tcl::mathop::<", "::tcl::mathop::<=", "::tcl::mathop::>", "::tcl::mathop::>=", "::tcl::mathop::==",
        "::tcl::mathop::!=", "::tcl::mathop::&", "::tcl::mathop::|", "::tcl::mathop::^", "::tcl::mathop::<<", "::tcl::mathop::>>",
        "::tcl::mathop::**", "::tcl::mathop::-", "::tcl::mathop::+", "::tcl::mathop::~", "::tcl::mathop::!" };
    int i;
    if (done) return;
    done = 1;
    tbcInt = Tcl_GetObjType("int");
    tbcWide = Tcl_GetObjType("wideInt");
    tbcDouble = Tcl_GetObjType("double");
    tbcString = Tcl_GetObjType("string");
    tbcList = Tcl_GetObjType("list");
    if (!tbcWide) tbcWide = (const Tcl_ObjType *) &tbcWide;   /* a type no object has; keeps "typePtr == NULL" from matching */
    tbcZero = Tcl_NewIntObj(0); Tcl_IncrRefCount(tbcZero);
    tbcOne = Tcl_NewIntObj(1); Tcl_IncrRefCount(tbcOne);
    tbcEmpty = Tcl_NewObj(); Tcl_IncrRefCount(tbcEmpty);
    for (i = 0; i < TBC_NOPS; i++) { tbcMathop[i] = Tcl_NewStringObj(names[i], -1); Tcl_IncrRefCount(tbcMathop[i]); }
}

/* A literal from the bytecode's literal table: a string object that keeps its string form; numbers get their numeric form too,
 * as they would the first time the interpreter used them, so the fast paths see them. */
static Tcl_Obj *tbc_lit_d(double d) { Tcl_Obj *o = Tcl_NewDoubleObj(d); Tcl_IncrRefCount(o); return o; }
static Tcl_Obj *tbc_lit(const char *s, int len) {
    Tcl_Obj *o = Tcl_NewStringObj(s, len);
    Tcl_WideInt w;
    double d;
    Tcl_IncrRefCount(o);
    if (len > 0) {
        if (Tcl_GetWideIntFromObj(NULL, o, &w) != TCL_OK) (void) Tcl_GetDoubleFromObj(NULL, o, &d);
    }
    return o;
}

/* ---- numbers ---- */

/* an object that is not (yet) a number by type may still hold one as text (a list element, a substring...): the interpreter parses it the
 * first time an instruction needs it and keeps the number; so do we -- with its own parser, so the same strings are numbers */
static __attribute__((noinline)) int tbc_cvt_int(Tcl_Obj *o) {
    ClientData ptr;
    int type;
    if (o->typePtr == tbcDouble || o->typePtr == tbcList) return 0;         /* (a list would only be re-parsed to fail: not a number) */
    if (TclGetNumberFromObj(NULL, o, &ptr, &type) != TCL_OK) return 0;
    return o->typePtr == tbcInt || o->typePtr == tbcWide;
}
TBC_INLINE int tbc_isint(Tcl_Obj *o) { return o->typePtr == tbcInt || o->typePtr == tbcWide || tbc_cvt_int(o); }
TBC_INLINE Tcl_WideInt tbc_wide(Tcl_Obj *o) { return o->typePtr == tbcInt ? (Tcl_WideInt) o->internalRep.longValue : o->internalRep.wideValue; }

/* 1: integer in *w, 2: double in *d, 0: anything else (strings, lists, bignums...) */
static __attribute__((noinline)) int tbc_num_text(Tcl_Obj *o, Tcl_WideInt *w, double *d) {
    ClientData ptr;
    int type;
    if (o->typePtr == tbcList) return 0;
    if (TclGetNumberFromObj(NULL, o, &ptr, &type) != TCL_OK) return 0;
    if (type == TCL_NUMBER_LONG) { *w = (Tcl_WideInt) *(const long *) ptr; return 1; }
    if (type == TCL_NUMBER_WIDE) { *w = *(const Tcl_WideInt *) ptr; return 1; }
    if (type == TCL_NUMBER_DOUBLE) { *d = *(const double *) ptr; return 2; }
    return 0;
}
TBC_INLINE int tbc_num(Tcl_Obj *o, Tcl_WideInt *w, double *d) {
    const Tcl_ObjType *t = o->typePtr;
    if (t == tbcInt) { *w = (Tcl_WideInt) o->internalRep.longValue; return 1; }
    if (t == tbcWide) { *w = o->internalRep.wideValue; return 1; }
    if (t == tbcDouble) { *d = o->internalRep.doubleValue; return 2; }
    return tbc_num_text(o, w, d);
}

/* an object that holds a finite number, as a tagged number (the kind W of the translator): 1 with *tag 0 and *iv, or *tag 1 and *dv; or 0 (text that is not a number, a
 * bignum, NaN) */
TBC_INLINE int tbc_wload(Tcl_Obj *o, int *tag, int64_t *iv, double *dv) {
    Tcl_WideInt w;
    double x;
    int k = tbc_num(o, &w, &x);
    if (k == 1) { *tag = 0; *iv = (int64_t) w; return 1; }
    if (k == 2 && x == x) { *tag = 1; *dv = x; return 1; }
    return 0;
}

/* ---- math functions (tcl::mathfunc::*) in typed code ---- */

/* an object that holds a finite number, as a double: 1 and *d set, or 0 (text that is not a number, a bignum, NaN) */
TBC_INLINE int tbc_getdbl(Tcl_Obj *o, double *d) {
    Tcl_WideInt w;
    double x;
    int k = tbc_num(o, &w, &x);
    if (k == 1) { *d = (double) w; return 1; }
    if (k == 2 && x == x) { *d = x; return 1; }
    return 0;
}
/* the same, but an integer must be one a double holds exactly (|n| <= 2^53) */
TBC_INLINE int tbc_getdbl_exact(Tcl_Obj *o, double *d) {
    Tcl_WideInt w;
    double x;
    int k = tbc_num(o, &w, &x);
    if (k == 1) { if (w < -INT64_C(9007199254740992) || w > INT64_C(9007199254740992)) return 0; *d = (double) w; return 1; }
    if (k == 2 && x == x) { *d = x; return 1; }
    return 0;
}
/* A compiler may assume that a libm function returns no NaN when it can see that its argument is none (clang for wasm32 did so for asin of an integer, and
 * folded the test below away).  A trip through a volatile object keeps the result opaque. */
TBC_INLINE double tbc_opaque_dbl(double d) { volatile double v = d; return v; }
/* the result of a libm function as expr accepts it (CheckDoubleResult in Tcl): not NaN, and either errno is clear or it is ERANGE with a result of 0 or infinity */
#define TBC_MF_OK(r, e) ((r) == (r) && ((e) == 0 || ((e) == ERANGE && ((r) == 0.0 || isinf(r)))))
/* int() and wide() of a double, for a result that fits a long; 0 if the boxed code has to do it (Tcl makes a bignum and wraps it; and where long is not 64 bits wide() differs from int()) */
TBC_INLINE int tbc_dbl_to_int(double d, int64_t *out) {
    if (sizeof(long) != 8 || !(d < (double) LONG_MAX && d > (double) LONG_MIN)) return 0;
    *out = (int64_t) (long) d;
    return 1;
}
/* round() of a double, as ExprRoundFunc does it; 0 if the result is a bignum */
TBC_INLINE int tbc_dbl_round(double d, int64_t *out) {
    double intPart, fractPart = modf(d, &intPart);
    long max = LONG_MAX, min = LONG_MIN, result;
    if (sizeof(long) != 8) return 0;
    if (fractPart <= -0.5) min++; else if (fractPart >= 0.5) max--;
    if (intPart >= (double) max || intPart <= (double) min) return 0;
    result = (long) intPart;
    if (fractPart <= -0.5) result--; else if (fractPart >= 0.5) result++;
    *out = (int64_t) result;
    return 1;
}

/* Result of a binary operation replaces *pa (the stack slot holding the left operand); the right operand's reference is
 * released.  A temporary (unshared) left operand is overwritten in place, like the interpreter does. */
/* an integer value in an object, as the interpreter's TclSetLongObj / TclNewLongObj macros do it (Tcl_SetWideIntObj is a call and tests the range) */
TBC_INLINE void tbc_setint(Tcl_Obj *o, Tcl_WideInt r) {
    TclInvalidateStringRep(o);
    TclFreeIntRep(o);
    if (sizeof(long) == sizeof(Tcl_WideInt) || r == (long) r) { o->internalRep.longValue = (long) r; o->typePtr = tbcInt; }
    else { o->internalRep.wideValue = r; o->typePtr = tbcWide; }
}
TBC_INLINE Tcl_Obj *tbc_mkint(Tcl_WideInt r) {
    Tcl_Obj *o;
    TclNewObj(o);
    o->bytes = NULL;
    if (sizeof(long) == sizeof(Tcl_WideInt) || r == (long) r) { o->internalRep.longValue = (long) r; o->typePtr = tbcInt; }
    else { o->internalRep.wideValue = r; o->typePtr = tbcWide; }
    return o;
}
/* incr of a local held as an object: *po is the variable's value (an object it owns); the new value is in *out.  0 if the boxed code has to do it (not a
 * machine integer, overflow).  An unshared object is changed in place, as the executor does it. */
TBC_INLINE int tbc_incr_local(Tcl_Obj **po, int64_t imm, int64_t *out) {
    Tcl_Obj *o = *po;
    int64_t sum;
    if (!tbc_isint(o) || __builtin_add_overflow((int64_t) tbc_wide(o), imm, &sum)) return 0;
    if (Tcl_IsShared(o)) {
        Tcl_Obj *n = tbc_mkint(sum);
        Tcl_IncrRefCount(n);
        Tcl_DecrRefCount(o);
        *po = n;
    } else {
        tbc_setint(o, sum);
    }
    *out = sum;
    return 1;
}

TBC_INLINE void tbc_putint(Tcl_Obj **pa, Tcl_Obj *a, Tcl_Obj *b, Tcl_WideInt r) {
    if (!Tcl_IsShared(a)) {
        tbc_setint(a, r);
    } else {
        Tcl_Obj *n = tbc_mkint(r);
        Tcl_IncrRefCount(n);
        Tcl_DecrRefCount(a);
        *pa = n;
    }
    Tcl_DecrRefCount(b);
}
TBC_INLINE void tbc_putdbl(Tcl_Obj **pa, Tcl_Obj *a, Tcl_Obj *b, double r) {
    if (!Tcl_IsShared(a)) {
        Tcl_SetDoubleObj(a, r);
    } else {
        Tcl_Obj *n = Tcl_NewDoubleObj(r);
        Tcl_IncrRefCount(n);
        Tcl_DecrRefCount(a);
        *pa = n;
    }
    Tcl_DecrRefCount(b);
}
TBC_INLINE void tbc_putbool(Tcl_Obj **pa, Tcl_Obj *a, Tcl_Obj *b, int v) {
    Tcl_Obj *r = v ? tbcOne : tbcZero;
    Tcl_IncrRefCount(r);
    Tcl_DecrRefCount(a);
    *pa = r;
    Tcl_DecrRefCount(b);
}

/* the interpreter's result object, taken over (it keeps its reference) and replaced by a fresh empty one: what the interpreter's own
 * instructions do after a command; Tcl_ResetResult would also clear the error code and error info [Tcl bug 804681] */
TBC_INLINE Tcl_Obj *tbc_takeres(Tcl_Interp *interp) {
    Interp *ip = (Interp *) interp;
    Tcl_Obj *r = ip->objResultPtr, *n = Tcl_NewObj();
    Tcl_IncrRefCount(n);
    ip->objResultPtr = n;
    return r;
}
/* the command frame of the bytecode that is running (the stub of the proc, whose location tables are the original body's): point it at the
 * instruction that is being executed, as the interpreter does before it invokes a command, so that `info frame` and the line numbers of
 * scripts run from here are the original's.  Commands are invoked with the same flags as the interpreter's invoke instruction. */
#define TBC_EV (TCL_EVAL_NOERR | TCL_EVAL_SOURCE_IN_FRAME)
TBC_INLINE void tbc_setpc(Tcl_Interp *interp, int pc) {
    CmdFrame *cf = ((Interp *) interp)->cmdFramePtr;
    if (cf && cf->type == TCL_LOCATION_BC) cf->data.tebc.pc = (char *) ((ByteCode *) cf->data.tebc.codePtr)->codeStart + pc;
}

/* The interpreter looks for asynchronous handlers, cancellation and limit expiry every 64 instructions; compiled code does so at each pass
 * through a loop head (every 64th: a loop is the only way to run for long without making a call) */
/* the log of an error in the boxed code: the live stack slots are the words of the command that failed */
#define TBC_XLOG(pc, so, sl, d, ...) do { if (rcg_ == TCL_ERROR) { Tcl_Obj *t_[(d) + 1] = { NULL, ##__VA_ARGS__ }; tbc_logerr(interp, pc, so, sl, &t_[d]); } } while (0)
TBC_SHARED unsigned tbc_ticks;
/* Forced hand-over, for testing: a module translated with TBC_FORCE_DEOPT=1 asks here at every typed instruction, and hands over to boxed code when the answer
 * is yes, about once in TBC_FORCE_RATE instructions (a pseudo-random countdown from TBC_FORCE_SEED).  Without TBC_FORCE_RATE it never does. */
TBC_SHARED long tbc_force_n, tbc_force_rate;
TBC_SHARED unsigned long tbc_force_rng;
TBC_SHARED int tbc_force_ready;
static int tbc_force_due(void) {
    if (!tbc_force_ready) {
        const char *r = getenv("TBC_FORCE_RATE"), *sd = getenv("TBC_FORCE_SEED");
        tbc_force_ready = 1;
        tbc_force_rate = r ? atol(r) : 0;
        tbc_force_rng = sd ? (unsigned long) atol(sd) * 2654435761UL + 88172645463325252UL : 88172645463325252UL;
        tbc_force_n = tbc_force_rate;
    }
    if (tbc_force_rate <= 0 || --tbc_force_n > 0) return 0;
    tbc_force_rng ^= tbc_force_rng << 13; tbc_force_rng ^= tbc_force_rng >> 7; tbc_force_rng ^= tbc_force_rng << 17;
    tbc_force_n = 1 + (long) (tbc_force_rng % (unsigned long) (2 * tbc_force_rate));
    return 1;
}
TBC_INLINE int tbc_tick_due(Tcl_Interp *interp) {
    Interp *iPtr = (Interp *) interp;
    return ((++tbc_ticks & 63) == 0) && (TclAsyncReady(iPtr) || TclCanceled(iPtr) || TclLimitReady(iPtr->limit));
}
/* run what is due; nonzero if that raised an error */
static int tbc_poll(Tcl_Interp *interp) {
    Interp *iPtr = (Interp *) interp;
    if (TclAsyncReady(iPtr) && Tcl_AsyncInvoke(interp, TCL_OK) == TCL_ERROR) return 1;
    if (TclCanceled(iPtr) && Tcl_Canceled(interp, TCL_LEAVE_ERR_MSG) == TCL_ERROR) return 1;
    if (TclLimitReady(iPtr->limit) && Tcl_LimitCheck(interp) == TCL_ERROR) return 1;
    return 0;
}

#ifdef TBC_HOOK
/* the interpreter's own instruction for an operator, run on the operands (b is NULL for a unary operator): 0 and *res (referenced) on success,
 * 1 on error (the interpreter's error, as the instruction raises it), -1 if this is not available */
static int tbc_tebc(Tcl_Interp *interp, int op, Tcl_Obj *a, Tcl_Obj *b, Tcl_Obj **res);
static int tbc_bigop(int op, Tcl_Obj **pa, Tcl_Obj *b);
#endif
/* The general case, by calling ::tcl::mathop::<op> exactly as a script would.  On error the operands stay where they are. */
static int tbc_slow(Tcl_Interp *interp, int op, Tcl_Obj **pa, Tcl_Obj *b) {
    Tcl_Obj *objv[3], *r;
    int rc;
#ifdef TBC_HOOK
    if (tbc_bigop(op, pa, b) == 0) return 0;
    rc = tbc_tebc(interp, op, *pa, b, &r);
    if (rc >= 0) {
        if (rc) return 1;
        Tcl_DecrRefCount(*pa); Tcl_DecrRefCount(b); *pa = r;
        return 0;
    }
#endif
    objv[0] = tbcMathop[op]; objv[1] = *pa; objv[2] = b;
    rc = Tcl_EvalObjv(interp, 3, objv, TCL_EVAL_NOERR);
    if (rc != TCL_OK) return 1;
    r = tbc_takeres(interp);
    if (r->typePtr == tbcDouble && r->internalRep.doubleValue != r->internalRep.doubleValue) {   /* NaN: expr raises, mathop does not */
        TclExprFloatError(interp, r->internalRep.doubleValue);
        Tcl_DecrRefCount(r);
        return 1;
    }
    Tcl_DecrRefCount(*pa);
    Tcl_DecrRefCount(b);
    *pa = r;
    return 0;
}

/* The unary operators (-, +, ~, !): the common cases here, the rest by the mathop command, which raises the interpreter's errors.  The operand
 * stays in place on error. */
static int tbc_slow1(Tcl_Interp *interp, int op, Tcl_Obj **pa) {
    Tcl_Obj *objv[2], *r;
#ifdef TBC_HOOK
    {
        int rc1 = tbc_tebc(interp, op, *pa, NULL, &r);
        if (rc1 >= 0) {
            if (rc1) return 1;
            Tcl_DecrRefCount(*pa); *pa = r;
            return 0;
        }
    }
#endif
    objv[0] = tbcMathop[op]; objv[1] = *pa;
    if (Tcl_EvalObjv(interp, 2, objv, TCL_EVAL_NOERR) != TCL_OK) return 1;
    r = tbc_takeres(interp);
    if (r->typePtr == tbcDouble && r->internalRep.doubleValue != r->internalRep.doubleValue) { TclExprFloatError(interp, r->internalRep.doubleValue); Tcl_DecrRefCount(r); return 1; }
    Tcl_DecrRefCount(*pa);
    *pa = r;
    return 0;
}
static int tbc_un(Tcl_Interp *interp, int op, Tcl_Obj **pa) {
    Tcl_Obj *a = *pa, *r = NULL;
    Tcl_WideInt x = 0;
    double dx = 0;
    int ta = tbc_num(a, &x, &dx);
    switch (op) {
    case TBC_NEG:
        if (ta == 1 && x != INT64_MIN) r = tbc_mkint(-x);
        else if (ta == 2 && dx == dx) r = Tcl_NewDoubleObj(-dx);
        break;
    case TBC_POS:
        /* as INST_UPLUS: a number without a string form of its own stays as it is, any other is replaced by one that has none ("+7.90" is 7.9, "+0x10" is 16) */
        if (ta == 1 || (ta == 2 && dx == dx)) { if (!a->bytes) return 0; r = ta == 1 ? tbc_mkint(x) : Tcl_NewDoubleObj(dx); }
        break;
    case TBC_BNOT:
        if (ta == 1) r = tbc_mkint(~x);
        break;
    case TBC_LNOT:
        if (ta == 1) r = x == 0 ? tbcOne : tbcZero;
        else if (ta == 2 && dx == dx) r = dx == 0.0 ? tbcOne : tbcZero;
        break;
    }
    if (!r) return tbc_slow1(interp, op, pa);
    Tcl_IncrRefCount(r);
    Tcl_DecrRefCount(a);
    *pa = r;
    return 0;
}

#define TBC_2P53 (((Tcl_WideInt) 1) << 53)

/* a comparison of two objects as the interpreter does it (numbers as numbers, anything else as strings), from typed code: the operands are left as they are.  0 and *r
 * 0 or 1, or 1 on an error (nothing consumed, no result left) */
static int tbc_cmpo(Tcl_Interp *interp, int op, Tcl_Obj *a, Tcl_Obj *b, int64_t *r);

/* Returns 0 on success, nonzero on error (nothing consumed). */
TBC_INLINE int tbc_bin(Tcl_Interp *interp, int op, Tcl_Obj **pa, Tcl_Obj *b) {
    Tcl_Obj *a = *pa;
    Tcl_WideInt x = 0, y = 0, r;
    double dx = 0, dy = 0;
    int ta = tbc_num(a, &x, &dx), tb = tbc_num(b, &y, &dy);
    if (op >= TBC_BAND) {                                       /* bitwise operators and **: only machine integers are done here */
        if (ta == 1 && tb == 1) {
            switch (op) {
            case TBC_BAND: tbc_putint(pa, a, b, x & y); return 0;
            case TBC_BOR: tbc_putint(pa, a, b, x | y); return 0;
            case TBC_BXOR: tbc_putint(pa, a, b, x ^ y); return 0;
            case TBC_SHL:
                if (y >= 0 && y < 64) { r = (Tcl_WideInt) ((uint64_t) x << y); if ((r >> y) == x) { tbc_putint(pa, a, b, r); return 0; } }
                else if (y >= 64 && x == 0) { tbc_putint(pa, a, b, 0); return 0; }
                break;
            case TBC_SHR:
                if (y >= 0) { r = y >= 64 ? (x < 0 ? -1 : 0) : (x >> y); tbc_putint(pa, a, b, r); return 0; }
                break;
            case TBC_POW:
                if (y == 1) { Tcl_DecrRefCount(b); return 0; }                   /* x**1 is x itself, text and all */
                if (y >= 0) {
                    Tcl_WideInt base = x, acc = 1, e = y;
                    int ok = 1;
                    while (e) {
                        if ((e & 1) && __builtin_mul_overflow(acc, base, &acc)) { ok = 0; break; }
                        e >>= 1;
                        if (e && __builtin_mul_overflow(base, base, &base)) { ok = 0; break; }
                    }
                    if (ok) { tbc_putint(pa, a, b, acc); return 0; }
                }
                break;
            }
        }
        return tbc_slow(interp, op, pa, b);
    }
    if (ta == 1 && tb == 1) {
        switch (op) {
        case TBC_ADD: if (!__builtin_add_overflow(x, y, &r)) { tbc_putint(pa, a, b, r); return 0; } break;
        case TBC_SUB: if (!__builtin_sub_overflow(x, y, &r)) { tbc_putint(pa, a, b, r); return 0; } break;
        case TBC_MULT: if (!__builtin_mul_overflow(x, y, &r)) { tbc_putint(pa, a, b, r); return 0; } break;
        case TBC_DIV:
            if (y != 0 && y != -1) {
                r = x / y;
                if ((x % y != 0) && ((x < 0) != (y < 0))) r--;      /* Tcl rounds toward minus infinity */
                tbc_putint(pa, a, b, r); return 0;
            }
            break;
        case TBC_MOD:
            if (y != 0 && y != -1) {
                r = x % y;
                if (r != 0 && ((r < 0) != (y < 0))) r += y;         /* the result takes the divisor's sign */
                tbc_putint(pa, a, b, r); return 0;
            }
            break;
        case TBC_LT: tbc_putbool(pa, a, b, x < y); return 0;
        case TBC_LE: tbc_putbool(pa, a, b, x <= y); return 0;
        case TBC_GT: tbc_putbool(pa, a, b, x > y); return 0;
        case TBC_GE: tbc_putbool(pa, a, b, x >= y); return 0;
        case TBC_EQ: tbc_putbool(pa, a, b, x == y); return 0;
        case TBC_NEQ: tbc_putbool(pa, a, b, x != y); return 0;
        }
    } else if (ta && tb) {                                          /* at least one double */
        if (ta == 1) {
            if (op >= TBC_LT && (x > TBC_2P53 || x < -TBC_2P53)) goto slow;     /* not exactly representable: let Tcl compare */
            dx = (double) x;
        }
        if (tb == 1) {
            if (op >= TBC_LT && (y > TBC_2P53 || y < -TBC_2P53)) goto slow;
            dy = (double) y;
        }
        {   /* a NaN result is an error in expr: leave it to the slow path, which reports it */
            double dr;
            switch (op) {
            case TBC_ADD: dr = dx + dy; if (dr == dr) { tbc_putdbl(pa, a, b, dr); return 0; } goto slow;
            case TBC_SUB: dr = dx - dy; if (dr == dr) { tbc_putdbl(pa, a, b, dr); return 0; } goto slow;
            case TBC_MULT: dr = dx * dy; if (dr == dr) { tbc_putdbl(pa, a, b, dr); return 0; } goto slow;
            case TBC_DIV: if (dy != 0.0) { dr = dx / dy; if (dr == dr) { tbc_putdbl(pa, a, b, dr); return 0; } } goto slow;
            default: break;
            }
        }
        switch (op) {
        case TBC_LT: tbc_putbool(pa, a, b, dx < dy); return 0;
        case TBC_LE: tbc_putbool(pa, a, b, dx <= dy); return 0;
        case TBC_GT: tbc_putbool(pa, a, b, dx > dy); return 0;
        case TBC_GE: tbc_putbool(pa, a, b, dx >= dy); return 0;
        case TBC_EQ: tbc_putbool(pa, a, b, dx == dy); return 0;
        case TBC_NEQ: tbc_putbool(pa, a, b, dx != dy); return 0;
        }
    }
    if (op >= TBC_LT && op <= TBC_NEQ && (!ta || !tb)) {            /* a comparison with something that is not a number: the interpreter compares the strings */
        ClientData p1, p2;
        int t1, t2;
        if (TclCheckEmptyString(a) > 0 || TclCheckEmptyString(b) > 0 || TclGetNumberFromObj(NULL, a, &p1, &t1) != TCL_OK
                || TclGetNumberFromObj(NULL, b, &p2, &t2) != TCL_OK) {
            int m = TclStringCmp(a, b, op == TBC_EQ || op == TBC_NEQ, 0, -1);
            tbc_putbool(pa, a, b, op == TBC_LT ? m < 0 : op == TBC_LE ? m <= 0 : op == TBC_GT ? m > 0 : op == TBC_GE ? m >= 0 : op == TBC_EQ ? m == 0 : m != 0);
            return 0;
        }
    }
slow:
    return tbc_slow(interp, op, pa, b);
}

/* Truth value for a conditional jump; TCL_OK or TCL_ERROR (message in the interpreter, as for `if {$x}`). */
TBC_INLINE int tbc_truth(Tcl_Interp *interp, Tcl_Obj *o, int *res) {
    const Tcl_ObjType *t = o->typePtr;
    if (t == tbcInt) { *res = o->internalRep.longValue != 0; return TCL_OK; }
    if (t == tbcWide) { *res = o->internalRep.wideValue != 0; return TCL_OK; }
    if (t == tbcDouble) { *res = o->internalRep.doubleValue != 0.0; return TCL_OK; }
    return Tcl_GetBooleanFromObj(interp, o, res);
}

/* ---- variables ---- */

static void tbc_unset_err(Tcl_Interp *interp, const char *name) {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("can't read \"%s\": no such variable", name));
    Tcl_SetErrorCode(interp, "TCL", "READ", "VARNAME", NULL);
}

/* incr by an immediate or by an integer object; *pv is the variable's object.  Returns 0 or nonzero on error. */
TBC_INLINE int tbc_incr(Tcl_Interp *interp, Tcl_Obj **pv, Tcl_WideInt imm, Tcl_Obj *incObj) {
    Tcl_Obj *o = *pv;
    Tcl_WideInt w, step = imm;
    if (!o) {                                                       /* incr of an unset variable creates it */
        if (incObj && Tcl_GetWideIntFromObj(interp, incObj, &step) != TCL_OK) return 1;
        o = Tcl_NewWideIntObj(step);
        Tcl_IncrRefCount(o);
        *pv = o;
        return 0;
    }
    if (incObj) {
        if (!tbc_isint(incObj)) goto slow;
        step = tbc_wide(incObj);
    }
    if (tbc_isint(o) && !__builtin_add_overflow(tbc_wide(o), step, &w)) {
        if (!Tcl_IsShared(o)) {
            Tcl_SetWideIntObj(o, w);
        } else {
            Tcl_Obj *n = Tcl_NewWideIntObj(w);
            Tcl_IncrRefCount(n);
            Tcl_DecrRefCount(o);
            *pv = n;
        }
        return 0;
    }
slow:
    {
        Tcl_Obj *inc = incObj, *n;
        int rc;
        if (!inc) { inc = Tcl_NewWideIntObj(imm); Tcl_IncrRefCount(inc); }
        if (Tcl_IsShared(o)) {
            n = Tcl_DuplicateObj(o);
            Tcl_IncrRefCount(n);
            Tcl_DecrRefCount(o);
            *pv = o = n;
        }
        rc = TclIncrObj(interp, o, inc);
        if (!incObj) Tcl_DecrRefCount(inc);
        return rc != TCL_OK;
    }
}

/* append: *pv is the variable's object (NULL if unset), v the value on top of the stack.  Returns 0 or nonzero on error. */
TBC_INLINE int tbc_append(Tcl_Obj **pv, Tcl_Obj *v) {
    Tcl_Obj *o = *pv;
    if (!o) {
        *pv = v;
        Tcl_IncrRefCount(v);
        return 0;
    }
    if (Tcl_IsShared(o)) {
        Tcl_Obj *n = Tcl_DuplicateObj(o);
        Tcl_IncrRefCount(n);
        Tcl_DecrRefCount(o);
        *pv = o = n;
    }
    Tcl_AppendObjToObj(o, v);
    return 0;
}

/* ---- lists, strings, dicts ---- */

/* lindex list index: the result carries a reference.  NULL on error. */
TBC_INLINE Tcl_Obj *tbc_lindex(Tcl_Interp *interp, Tcl_Obj *list, Tcl_Obj *idx) {
    if (tbc_isint(idx)) {
        int n;
        Tcl_Obj **v;
        Tcl_WideInt w = tbc_wide(idx);
        if (Tcl_ListObjGetElements(interp, list, &n, &v) != TCL_OK) return NULL;
        {
            Tcl_Obj *r;
            /* outside the list Tcl's own index rules apply (an index is a 32-bit quantity: 4294967295 is -1, -4294967295 is 1, and
             * anything beyond is a "bad index" error) */
            if (w < 0 || w >= n) return TclLindexList(interp, list, idx);
            r = v[w];
            Tcl_IncrRefCount(r);
            return r;
        }
    }
    return TclLindexList(interp, list, idx);
}

/* strcat as the interpreter's INST_STR_CONCAT1 does it (tclExecute.c): all-byte-array operands give a byte array, anything else a string built with one
 * allocation; when nothing but the first operand has any content the result is the first operand itself.  The result has a reference count of 1. */
static Tcl_Obj *tbc_concat(int n, Tcl_Obj **v) {
    int i, len, first, app = 0, onlyb = 1;
    Tcl_Obj *r;
    char *p;
    const char *b;
    for (i = 0; i < n; i++) {
        Tcl_Obj *o = v[i];
        if (o->typePtr != &tclByteArrayType && o->bytes != tclEmptyStringRep) { onlyb = 0; break; }
        if (o->typePtr == &tclByteArrayType && o->bytes != NULL) { onlyb = 0; break; }
    }
    if (onlyb) {
        for (i = 1; i < n; i++) if (v[i]->bytes != tclEmptyStringRep) { Tcl_GetByteArrayFromObj(v[i], &len); app += len; }
    } else {
        for (i = 1; i < n; i++) { (void) Tcl_GetStringFromObj(v[i], &len); app += len; }
    }
    if (app < 0) Tcl_Panic("max size for a Tcl value (%d bytes) exceeded", INT_MAX);
    if (app == 0) { Tcl_IncrRefCount(v[0]); return v[0]; }
    if (onlyb) {
        const unsigned char *fb = Tcl_GetByteArrayFromObj(v[0], &first);
        if (first + app < 0) Tcl_Panic("max size for a Tcl value (%d bytes) exceeded", INT_MAX);
        r = Tcl_NewObj();
        p = (char *) Tcl_SetByteArrayLength(r, first + app);
        memcpy(p, fb, (size_t) first);
        p += first;
        for (i = 1; i < n; i++) if (v[i]->bytes != tclEmptyStringRep) { b = (const char *) Tcl_GetByteArrayFromObj(v[i], &len); memcpy(p, b, (size_t) len); p += len; }
    } else {
        b = Tcl_GetStringFromObj(v[0], &first);
        if (first + app < 0) Tcl_Panic("max size for a Tcl value (%d bytes) exceeded", INT_MAX);
        r = Tcl_NewObj();
        p = (char *) Tcl_Alloc((unsigned) (first + app + 1));
        r->bytes = p;
        r->length = first + app;
        memcpy(p, b, (size_t) first);
        p += first;
        for (i = 1; i < n; i++) { b = Tcl_GetStringFromObj(v[i], &len); memcpy(p, b, (size_t) len); p += len; }
        *p = '\0';
    }
    Tcl_IncrRefCount(r);
    return r;
}

/* dict incr by an immediate: *pd is the variable's dict (NULL if unset), key the key object.  Returns 0 or nonzero on error. */
static int tbc_dict_incr(Tcl_Interp *interp, Tcl_Obj **pd, Tcl_Obj *key, Tcl_WideInt imm) {
    Tcl_Obj *dict = *pd, *val = NULL;
    int fresh = 0;
    if (!dict) { dict = Tcl_NewObj(); fresh = 1; }
    else if (Tcl_IsShared(dict)) { dict = Tcl_DuplicateObj(dict); fresh = 1; }
    if (Tcl_DictObjGet(interp, dict, key, &val) != TCL_OK) goto fail;
    if (!val) {
        if (Tcl_DictObjPut(interp, dict, key, Tcl_NewWideIntObj(imm)) != TCL_OK) goto fail;
    } else if (tbc_isint(val)) {
        Tcl_WideInt w;
        if (!__builtin_add_overflow(tbc_wide(val), imm, &w)) {
            if (Tcl_DictObjPut(interp, dict, key, Tcl_NewWideIntObj(w)) != TCL_OK) goto fail;
            goto stored;
        }
        goto slow;
    } else {
        Tcl_Obj *nv, *inc;
        int rc;
    slow:
        nv = Tcl_DuplicateObj(val);
        Tcl_IncrRefCount(nv);
        inc = Tcl_NewWideIntObj(imm);
        Tcl_IncrRefCount(inc);
        rc = TclIncrObj(interp, nv, inc);
        Tcl_DecrRefCount(inc);
        if (rc == TCL_OK) rc = Tcl_DictObjPut(interp, dict, key, nv);
        Tcl_DecrRefCount(nv);
        if (rc != TCL_OK) goto fail;
    }
stored:
    if (fresh) {
        Tcl_IncrRefCount(dict);
        if (*pd) Tcl_DecrRefCount(*pd);
        *pd = dict;
    }
    return 0;
fail:
    if (fresh) { Tcl_IncrRefCount(dict); Tcl_DecrRefCount(dict); }
    return 1;
}


/* ===================================================================================================================
 * Typed variants.
 *
 * Each translated proc is compiled to one C function per argument-type signature (I = int64, D = double, B = Tcl_Obj*).
 * Inside, values the translator can prove are integers or doubles live in plain C variables; whenever something unexpected
 * happens (overflow, a non-numeric value, a redefined callee...) the function boxes its live values and continues in the
 * ordinary boxed code at the same instruction ("deoptimisation"), so results are always the interpreter's.
 *
 * A typed function returns its result in the C return value (int64_t, double or Tcl_Obj*), and reports anything else through
 * tbc_st: 0 = normal; 1 = the function deoptimised and its result is the boxed object in tbc_box (callers expecting a typed
 * result must then continue in boxed code); 2 = error (Tcl return code in tbc_rc, message already in the interpreter).
 * Single interpreter, single thread.
 * ================================================================================================================= */

#include <inttypes.h>

TBC_SHARED int tbc_st, tbc_rc;
TBC_SHARED int tbc_susp;			/* boxed code has suspended a coroutine: the callbacks are in place, the frames above must return without touching the result */
/* The boxed code of a proc enters typed code again at a loop head by calling the typed variant for boxed arguments with tbc_rpc1 set to the instruction + 1 and
 * the operand stack in tbc_rstk/tbc_rn; the variant reads and clears them first thing.  tbc_noosr is set by typed code that was entered that way (or that has just
 * given up) when it goes on in the boxed code: that boxed code must not try to enter typed code at its loop heads once more. */
TBC_SHARED int tbc_noosr, tbc_rpc1, tbc_rn;
TBC_SHARED Tcl_Obj **tbc_rstk;
#define TBC_GNOF(f, g, ...) (tbc_noosr = (f), g(__VA_ARGS__))
TBC_SHARED Tcl_Obj *tbc_box;
TBC_SHARED int tbc_depth, tbc_maxdepth;
#ifndef TBC_REMK
#define TBC_REMK 0
#endif

#define TBC_2P53 (((Tcl_WideInt) 1) << 53)

TBC_INLINE Tcl_Obj *tbc_ref(Tcl_Obj *o) { Tcl_IncrRefCount(o); return o; }
/* `string first`, `string last`, `string index`, `string range` for operands whose characters are all one byte (ASCII), in place of the command (the command converts
 * its operands to Unicode arrays).  The operand must be a plain string (no number, list or byte array: their own conversions apply) whose character count equals its
 * byte count, which is O(1) once Tcl has counted them (the command does the same count).  Each function returns 0, having done nothing, for anything else; the caller
 * then makes the call.  The semantics are those of StringFirstCmd, StringLastCmd, StringIndexCmd and StringRangeCmd (tclCmdMZ.c): the needle must not be empty and
 * not longer than the haystack; an index outside the string gives the empty string; first is raised to 0 and last lowered to the end for a range. */
TBC_INLINE const char *tbc_ascii(Tcl_Obj *o, int *len) {
    const char *s;
    if (o->typePtr && o->typePtr != tbcString) return NULL;
    s = Tcl_GetStringFromObj(o, len);
    return Tcl_GetCharLength(o) == *len ? s : NULL;
}
static int tbc_s_first(Tcl_Obj *needle, Tcl_Obj *hay, int64_t *out) {
    int nl, hl;
    const char *n = tbc_ascii(needle, &nl), *h = n ? tbc_ascii(hay, &hl) : NULL;
    if (!h) return 0;
    *out = -1;
    if (nl > 0 && nl <= hl) {
        const char *p = h, *end = h + hl - nl + 1;
        while (p < end && (p = (const char *) memchr(p, n[0], (size_t) (end - p)))) {
            if (memcmp(p, n, (size_t) nl) == 0) { *out = p - h; break; }
            p++;
        }
    }
    return 1;
}
static int tbc_s_last(Tcl_Obj *needle, Tcl_Obj *hay, int64_t *out) {
    int nl, hl;
    const char *n = tbc_ascii(needle, &nl), *h = n ? tbc_ascii(hay, &hl) : NULL;
    if (!h) return 0;
    *out = -1;
    if (nl > 0 && nl <= hl) {
        const char *p;
        for (p = h + hl - nl; p >= h; p--) if (*p == n[0] && memcmp(p, n, (size_t) nl) == 0) { *out = p - h; break; }
    }
    return 1;
}
/* (the one-character strings are shared: an object that something may change in place is never shared, so a reference count above one is all that is needed) */
static Tcl_Obj *tbc_chr1[128];
static int tbc_s_index(Tcl_Obj *s, int64_t i, Tcl_Obj **out) {
    int len;
    const char *str = tbc_ascii(s, &len);
    if (!str) return 0;
    if (i < 0 || i >= len) { *out = tbcEmpty; Tcl_IncrRefCount(tbcEmpty); return 1; }
    {
        unsigned char c = (unsigned char) str[i];
        if (!tbc_chr1[c]) { tbc_chr1[c] = Tcl_NewStringObj((const char *) &c, 1); Tcl_IncrRefCount(tbc_chr1[c]); }
        *out = tbc_chr1[c]; Tcl_IncrRefCount(*out);
    }
    return 1;
}
/* INST_STR_MATCH as the executor does it (tclExecute.c): the Unicode matcher when either operand is a string object, the byte matcher for a byte array, else the UTF-8
 * matcher.  The command (TclStringMatchObj) takes the Unicode path for a plain string too, which builds Unicode arrays of both operands. */
static int tbc_s_match(Tcl_Obj *str, Tcl_Obj *pat, int nocase) {
    int l1, l2;
    if (str->typePtr == tbcString || pat->typePtr == tbcString) {
        Tcl_UniChar *u1 = Tcl_GetUnicodeFromObj(str, &l1), *u2 = Tcl_GetUnicodeFromObj(pat, &l2);
        return TclUniCharMatch(u1, l1, u2, l2, nocase);
    }
    if (TclIsPureByteArray(str) && !nocase) {
        unsigned char *b1 = Tcl_GetByteArrayFromObj(str, &l1), *b2 = Tcl_GetByteArrayFromObj(pat, &l2);
        return TclByteArrayMatch(b1, l1, b2, l2, 0);
    }
    return Tcl_StringCaseMatch(TclGetString(str), TclGetString(pat), nocase);
}
/* INST_REGEXP as the executor does it: the compiled expression of the pattern (cached in the pattern object), then one match; 0 on success (the match is 0 or 1) */
static int tbc_s_regexp(Tcl_Interp *interp, Tcl_Obj *str, Tcl_Obj *pat, int cflags, int *match) {
    Tcl_RegExp re = Tcl_GetRegExpFromObj(interp, pat, cflags);
    if (!re) return 1;
    *match = Tcl_RegExpExecObj(interp, re, str, 0, 0, 0);
    return *match < 0;
}
static int tbc_s_range(Tcl_Obj *s, int64_t first, int64_t last, Tcl_Obj **out) {
    int len;
    const char *str = tbc_ascii(s, &len);
    if (!str) return 0;
    if (first < 0) first = 0;
    if (last >= len) last = len - 1;
    if (last >= first) *out = Tcl_NewStringObj(str + first, (int) (last - first + 1));
    else *out = tbcEmpty;
    Tcl_IncrRefCount(*out);
    return 1;
}
/* an owned string object (one reference) of a key held as text in a buffer of typed code */
TBC_INLINE int tbc_fmt_i64(char *buf, int64_t w);
TBC_INLINE Tcl_Obj *tbc_newpair(int64_t i, int64_t j) { char kb[48]; int n, k; n = k = 0; { char t[24]; int a = 0; uint64_t u = i < 0 ? (uint64_t) 0 - (uint64_t) i : (uint64_t) i; do { t[a++] = (char) ('0' + u % 10); u /= 10; } while (u); if (i < 0) kb[n++] = '-'; while (a) kb[n++] = t[--a]; } kb[n++] = ','; { char t[24]; int a = 0; uint64_t u = j < 0 ? (uint64_t) 0 - (uint64_t) j : (uint64_t) j; do { t[a++] = (char) ('0' + u % 10); u /= 10; } while (u); if (j < 0) kb[n++] = '-'; while (a) kb[n++] = t[--a]; } (void) k; { Tcl_Obj *o = Tcl_NewStringObj(kb, n); Tcl_IncrRefCount(o); return o; } }
TBC_INLINE Tcl_Obj *tbc_newkey(const char *s, int n) { Tcl_Obj *o = Tcl_NewStringObj(s, n); Tcl_IncrRefCount(o); return o; }
TBC_INLINE Tcl_Obj *tbc_newint(int64_t w) { Tcl_Obj *o = Tcl_NewWideIntObj(w); Tcl_IncrRefCount(o); return o; }
/* `binary scan $data <t>[u]* var` for t one of c s S i I: the list tclBinary.c's BinaryScanCmd builds (ScanNumber's byte order and sign extension; a
 * number is read from its bytes, trailing bytes that do not make a whole number are ignored; no data gives the empty object).  Refcount 0.  Equal values share one
 * object in Tcl's own scan (a cache); here for c only, the one format whose values are always few. */
static Tcl_Obj *tbc_bscan(Tcl_Obj *data, int type, int uns) {
    int len, size = type == 'c' ? 1 : (type == 's' || type == 'S') ? 2 : 4, n, i;
    const unsigned char *b = Tcl_GetByteArrayFromObj(data, &len);
    Tcl_Obj *res, **el, *small[256];
    n = len / size;
    if (n == 0) return Tcl_NewObj();
    el = (Tcl_Obj **) ckalloc((size_t) n * sizeof(Tcl_Obj *));
    if (size == 1) memset(small, 0, sizeof small);
    for (i = 0; i < n; i++) {
        const unsigned char *p = b + (size_t) i * (size_t) size;
        long v;
        switch (type) {
        case 'c': v = p[0]; if (!uns && (v & 0x80)) v -= 0x100; break;
        case 's': v = p[0] + (p[1] << 8); if (!uns && (v & 0x8000)) v -= 0x10000; break;
        case 'S': v = p[1] + (p[0] << 8); if (!uns && (v & 0x8000)) v -= 0x10000; break;
        case 'i': v = (long) (p[0] + (p[1] << 8) + (p[2] << 16) + (((unsigned long) p[3]) << 24)); if (!uns && v >= 0x80000000L) v -= 0x100000000L; break;
        default: v = (long) (p[3] + (p[2] << 8) + (p[1] << 16) + (((unsigned long) p[0]) << 24)); if (!uns && v >= 0x80000000L) v -= 0x100000000L; break;
        }
        if (size == 1) {
            int idx = (int) (v & 0xFF);
            if (!small[idx]) { small[idx] = Tcl_NewLongObj(v); Tcl_IncrRefCount(small[idx]); }
            el[i] = small[idx];
        } else {
            el[i] = Tcl_NewLongObj(v);
        }
    }
    res = Tcl_NewListObj(n, el);
    ckfree((char *) el);
    if (size == 1) for (i = 0; i < 256; i++) if (small[i]) Tcl_DecrRefCount(small[i]);
    return res;
}
TBC_INLINE Tcl_Obj *tbc_newdbl(double d) { Tcl_Obj *o = Tcl_NewDoubleObj(d); Tcl_IncrRefCount(o); return o; }

static void tbc_depth_error(Tcl_Interp *interp) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj("too many nested evaluations (infinite loop?)", -1));
    Tcl_SetErrorCode(interp, "TCL", "LIMIT", "STACK", NULL);
}

/* After a typed function returned with tbc_st != 0, from the command entry point. */
static int tbc_finish(Tcl_Interp *interp) {
    if (tbc_st == 4) { tbc_st = 0; return TCL_OK; }
    if (tbc_st == 1) {
        Tcl_SetObjResult(interp, tbc_box);
        Tcl_DecrRefCount(tbc_box);
        tbc_box = NULL;
        tbc_st = 0;
        return TCL_OK;
    }
    tbc_st = 0;
    return tbc_rc;
}

/* Arguments: only values whose string form is what we would print for the number (so passing a typed value on and
 * re-boxing it later cannot change what a script sees). */
static int tbc_parse_canon(const char *s, int len, int64_t *out) {
    int neg = 0, i = 0;
    uint64_t v = 0;
    if (len <= 0 || len > 20) return 0;
    if (s[0] == '-') { neg = 1; i = 1; if (len == 1) return 0; }
    if (s[i] == '0') { if (len - i != 1 || neg) return 0; *out = 0; return 1; }
    for (; i < len; i++) {
        unsigned c = (unsigned) ((unsigned char) s[i]) - '0';
        if (c > 9) return 0;
        if (v > (UINT64_MAX - c) / 10) return 0;
        v = v * 10 + c;
    }
    if (neg) { if (v > (uint64_t) INT64_MAX + 1) return 0; *out = (int64_t) (0 - v); }
    else { if (v > (uint64_t) INT64_MAX) return 0; *out = (int64_t) v; }
    return 1;
}
static int tbc_cmpo(Tcl_Interp *interp, int op, Tcl_Obj *a, Tcl_Obj *b, int64_t *r) {
    Tcl_Obj *x = a;
    Tcl_WideInt w = 0;
    Tcl_IncrRefCount(a); Tcl_IncrRefCount(b);                      /* tbc_bin consumes its operands */
    if (tbc_bin(interp, op, &x, b)) { Tcl_DecrRefCount(a); Tcl_DecrRefCount(b); Tcl_ResetResult(interp); return 1; }
    if (Tcl_GetWideIntFromObj(NULL, x, &w) != TCL_OK) { Tcl_DecrRefCount(x); return 1; }
    Tcl_DecrRefCount(x);
    *r = (int64_t) w;
    return 0;
}
TBC_INLINE int tbc_arg_int(Tcl_Obj *o, int64_t *w) {
    const Tcl_ObjType *t = o->typePtr;
    if (t == tbcInt || t == tbcWide) {
        if (o->bytes == NULL) { *w = tbc_wide(o); return 1; }
        return tbc_parse_canon(o->bytes, o->length, w);
    }
    if ((t == NULL || t == tbcString) && o->bytes != NULL) return tbc_parse_canon(o->bytes, o->length, w);
    return 0;
}
TBC_INLINE int tbc_arg_dbl(Tcl_Obj *o, double *d) {
    if (o->typePtr == tbcDouble && o->bytes == NULL && o->internalRep.doubleValue == o->internalRep.doubleValue) {
        *d = o->internalRep.doubleValue;
        return 1;
    }
    return 0;
}

/* A proc that adapts (wadapt in translate.tcl) has a second typed version with tagged numbers.  Its integer version calls this where an object operand is not an integer: if it is
 * a finite double the flag is set, the entry of the proc and the loop-head entry of the boxed code use the tagged version from then on, and this call hands over as before. */
TBC_INLINE void tbc_wnote(int *flag, Tcl_Obj *o) {
    Tcl_WideInt w;
    double d;
    if (!*flag && tbc_num(o, &w, &d) == 2 && d == d) *flag = 1;
}

/* the same for a value that is going to live in a typed variable: it must come back as it was (see tbc_arg_int): an integer in its canonical form, a double without a
 * string form of its own */
TBC_INLINE int tbc_wload_canon(Tcl_Obj *o, int *tag, int64_t *iv, double *dv) {
    if (tbc_arg_int(o, iv)) { *tag = 0; return 1; }
    if (tbc_arg_dbl(o, dv)) { *tag = 1; return 1; }
    return 0;
}

/* ---- lists ---- */

/* lindex with an integer index; the result carries a reference.  NULL on error. */
TBC_INLINE Tcl_Obj *tbc_lindex_i(Tcl_Interp *interp, Tcl_Obj *list, int64_t i) {
    int n;
    Tcl_Obj **v, *r;
    if (list->typePtr == tbcList) { n = ListRepPtr(list)->elemCount; v = &ListRepPtr(list)->elements; }	/* (what Tcl_ListObjGetElements does for a list) */
    else if (Tcl_ListObjGetElements(interp, list, &n, &v) != TCL_OK) return NULL;
    if (i < 0 || i >= n) {
        Tcl_Obj *io = tbc_newint(i);
        r = TclLindexList(interp, list, io);
        Tcl_DecrRefCount(io);
        return r;
    }
    r = v[i];
    Tcl_IncrRefCount(r);
    return r;
}

/* lindex list end-k */
TBC_INLINE Tcl_Obj *tbc_lindex_end(Tcl_Interp *interp, Tcl_Obj *list, int64_t k) {
    int n;
    Tcl_Obj **v, *r;
    if (list->typePtr == tbcList) { n = ListRepPtr(list)->elemCount; v = &ListRepPtr(list)->elements; }
    else if (Tcl_ListObjGetElements(interp, list, &n, &v) != TCL_OK) return NULL;
    r = (n - 1 - k >= 0) ? v[n - 1 - k] : tbcEmpty;
    Tcl_IncrRefCount(r);
    return r;
}

/* lset with an integer index.  The caller has dropped the stack's reference to the list, so the variable's is the only one.
 * An unshared list without a string form is updated in place; anything else goes to Tcl's own lset.  The result carries a
 * reference; NULL on error. */
TBC_INLINE Tcl_Obj *tbc_lset_i(Tcl_Interp *interp, Tcl_Obj *list, int64_t i, Tcl_Obj *val) {
    if (list->typePtr == tbcList && list->bytes == NULL && !Tcl_IsShared(list)) {
        int n;
        Tcl_Obj **v;
        if (Tcl_ListObjGetElements(interp, list, &n, &v) == TCL_OK && i >= 0 && i < n) {
            Tcl_Obj *old = v[i];
            if (old != val) {
                v[i] = val;
                Tcl_IncrRefCount(val);
                Tcl_DecrRefCount(old);
            }
            Tcl_IncrRefCount(list);
            return list;
        }
    }
    {
        Tcl_Obj *io = tbc_newint(i), *r = TclLsetList(interp, list, io, val);
        Tcl_DecrRefCount(io);
        return r;
    }
}

/* ---- strings ---- */

TBC_INLINE int tbc_fmt_i64(char *buf, int64_t w) {
    char tmp[24];
    int n = 0, len = 0;
    uint64_t u = w < 0 ? (uint64_t) 0 - (uint64_t) w : (uint64_t) w;
    do { tmp[n++] = (char) ('0' + u % 10); u /= 10; } while (u);
    if (w < 0) buf[len++] = '-';
    while (n) buf[len++] = tmp[--n];
    return len;
}

/* append to the string in a variable (NULL = unset) */
TBC_INLINE void tbc_append_bytes(Tcl_Obj **pv, const char *s, int len) {
    Tcl_Obj *o = *pv;
    if (!o) { o = Tcl_NewStringObj(s, len); Tcl_IncrRefCount(o); *pv = o; return; }
    if (Tcl_IsShared(o)) {
        Tcl_Obj *n = Tcl_DuplicateObj(o);
        Tcl_IncrRefCount(n);
        Tcl_DecrRefCount(o);
        *pv = o = n;
    }
    Tcl_AppendToObj(o, s, len);
}
TBC_INLINE void tbc_append_i(Tcl_Obj **pv, int64_t w) {
    char buf[24];
    int n = tbc_fmt_i64(buf, w);
    tbc_append_bytes(pv, buf, n);
}

/* building a string from parts (strcat) with one allocation for the result in the common case */
typedef struct { char *p; int n, cap; char buf[120]; } tbc_cat_t;
TBC_INLINE void tbc_cat_init(tbc_cat_t *c) { c->p = c->buf; c->n = 0; c->cap = (int) sizeof c->buf; }
static void tbc_cat_grow(tbc_cat_t *c, int need) {
    int cap = c->cap * 2;
    char *np;
    while (cap < c->n + need) cap *= 2;
    np = (char *) Tcl_Alloc((unsigned) cap);
    memcpy(np, c->p, (size_t) c->n);
    if (c->p != c->buf) Tcl_Free(c->p);
    c->p = np;
    c->cap = cap;
}
TBC_INLINE void tbc_cat_bytes(tbc_cat_t *c, const char *s, int len) {
    if (TBC_UNLIKELY(c->n + len > c->cap)) tbc_cat_grow(c, len);
    memcpy(c->p + c->n, s, (size_t) len);
    c->n += len;
}
TBC_INLINE void tbc_cat_i(tbc_cat_t *c, int64_t w) {
    char buf[24];
    int n = tbc_fmt_i64(buf, w);
    tbc_cat_bytes(c, buf, n);
}
TBC_INLINE void tbc_cat_o(tbc_cat_t *c, Tcl_Obj *o) {
    int len;
    const char *s = Tcl_GetStringFromObj(o, &len);
    tbc_cat_bytes(c, s, len);
}
TBC_INLINE Tcl_Obj *tbc_cat_done(tbc_cat_t *c) {
    Tcl_Obj *o = Tcl_NewStringObj(c->p, c->n);
    if (c->p != c->buf) Tcl_Free(c->p);
    Tcl_IncrRefCount(o);
    return o;
}

/* ---- dicts ---- */

TBC_INLINE int tbc_dict_exists(Tcl_Obj *dict, Tcl_Obj *key) {
    Tcl_Obj *v = NULL;
    return Tcl_DictObjGet(NULL, dict, key, &v) == TCL_OK && v != NULL;
}

/* dict incr by an immediate (compare tbc_dict_incr above): updates an unshared integer value in place, as the interpreter does */
static int tbc_dict_incr2(Tcl_Interp *interp, Tcl_Obj **pd, Tcl_Obj *key, Tcl_WideInt imm) {
    Tcl_Obj *dict = *pd, *val = NULL;
    int fresh = 0;
    if (dict && !Tcl_IsShared(dict) && dict->bytes == NULL && Tcl_DictObjGet(NULL, dict, key, &val) == TCL_OK && val != NULL &&
            tbc_isint(val) && !Tcl_IsShared(val)) {
        Tcl_WideInt w;
        if (!__builtin_add_overflow(tbc_wide(val), imm, &w)) { Tcl_SetWideIntObj(val, w); return 0; }
    }
    (void) fresh;
    return tbc_dict_incr(interp, pd, key, imm);
}



/* ---- expr's operand policy (INST_TRY_CVT_TO_NUMERIC) ---- */
extern int TclGetNumberFromObj(Tcl_Interp *, Tcl_Obj *, ClientData *, int *);
#define TBC_NUM_LONG 1
#define TBC_NUM_WIDE 2
#define TBC_NUM_BIG 3
#define TBC_NUM_DOUBLE 4
#define TBC_NUM_NAN 5

/* A numeric-looking value is replaced by the number itself, whose string form is then the canonical one ("0x10" -> 16,
 * "1e15" -> 1000000000000000.0); anything else is left alone.  NaN is an error, as in expr.  Returns 0, or nonzero on error. */
static int tbc_trycvt(Tcl_Interp *interp, Tcl_Obj **ps) {
    Tcl_Obj *o = *ps, *n;
    ClientData p;
    int type;
    if (o->bytes != NULL && o->length == 0) return 0;
    if (TclGetNumberFromObj(NULL, o, &p, &type) != TCL_OK) return 0;
    if (type == TBC_NUM_NAN) { TclExprFloatError(interp, *(const double *) p); return 1; }
    if (o->bytes == NULL) return 0;                                  /* already formatted from the number */
    switch (type) {
    case TBC_NUM_LONG: n = Tcl_NewWideIntObj((Tcl_WideInt) *(const long *) p); break;
    case TBC_NUM_WIDE: n = Tcl_NewWideIntObj(*(const Tcl_WideInt *) p); break;
    case TBC_NUM_DOUBLE: n = Tcl_NewDoubleObj(*(const double *) p); break;
    default: {                                                       /* bignum: let ::tcl::mathop::+ rebuild it */
        Tcl_Obj *objv[3];
        int rc;
        objv[0] = tbcMathop[TBC_ADD]; objv[1] = o; objv[2] = tbcZero;
        rc = Tcl_EvalObjv(interp, 3, objv, TCL_EVAL_NOERR);
        if (rc != TCL_OK) return 1;
        n = tbc_takeres(interp);
        Tcl_DecrRefCount(o);
        *ps = n;
        return 0;
    }
    }
    Tcl_IncrRefCount(n);
    Tcl_DecrRefCount(o);
    *ps = n;
    return 0;
}


/* Overflow-checked 64-bit multiply.  On wasm32 the compiler's builtin becomes a call to a 128-bit multiply routine; operands that
 * both fit in 32 bits (the common case) cannot overflow, so test for that first. */
#ifdef __wasm__
TBC_INLINE int tbc_mul_ovf(int64_t a, int64_t b, int64_t *r) {
    if (((uint64_t) a + UINT64_C(0x80000000)) < UINT64_C(0x100000000) && ((uint64_t) b + UINT64_C(0x80000000)) < UINT64_C(0x100000000)) {
        *r = (int64_t) ((uint64_t) a * (uint64_t) b);
        return 0;
    }
    return __builtin_mul_overflow(a, b, r);
}
#else
#define tbc_mul_ovf(a, b, r) __builtin_mul_overflow((a), (b), (r))
#endif

/* The boxed arithmetic helper, out of line, for the generic (boxed) code: it is the cold path, and expanding the full fast path at
 * every site would make the C functions several times larger. */
static __attribute__((noinline)) int tbc_bin_g(Tcl_Interp *interp, int op, Tcl_Obj **pa, Tcl_Obj *b) { return tbc_bin(interp, op, pa, b); }
/* one function per operator, for the frame-based code: the operator is a constant inside, so the dispatch on it and the paths of the other operators
 * are gone (the generic one above stays for the tools that pass it as a value) */
#define TBC_BINOP_FN(NAME) static __attribute__((noinline)) int tbc_bin_##NAME(Tcl_Interp *interp, Tcl_Obj **pa, Tcl_Obj *b) { return tbc_bin(interp, TBC_##NAME, pa, b); }
TBC_BINOP_FN(ADD) TBC_BINOP_FN(SUB) TBC_BINOP_FN(MULT) TBC_BINOP_FN(DIV) TBC_BINOP_FN(MOD)
TBC_BINOP_FN(LT) TBC_BINOP_FN(LE) TBC_BINOP_FN(GT) TBC_BINOP_FN(GE) TBC_BINOP_FN(EQ) TBC_BINOP_FN(NEQ)
TBC_BINOP_FN(BAND) TBC_BINOP_FN(BOR) TBC_BINOP_FN(BXOR) TBC_BINOP_FN(SHL) TBC_BINOP_FN(SHR) TBC_BINOP_FN(POW)

/* dict get with a missing key: Tcl's error */
static void tbc_dict_nokey(Tcl_Interp *interp, Tcl_Obj *key) {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("key \"%s\" not known in dictionary", Tcl_GetString(key)));
    Tcl_SetErrorCode(interp, "TCL", "LOOKUP", "DICT", Tcl_GetString(key), NULL);
}
/* lappend to a variable (NULL = unset): unshared lists are extended in place; returns nonzero on error */
static int tbc_lappend(Tcl_Interp *interp, Tcl_Obj **pv, Tcl_Obj *elem) {
    Tcl_Obj *o = *pv;
    if (!o) { o = Tcl_NewListObj(0, NULL); Tcl_IncrRefCount(o); *pv = o; }
    else if (Tcl_IsShared(o)) { Tcl_Obj *d = Tcl_DuplicateObj(o); Tcl_IncrRefCount(d); Tcl_DecrRefCount(o); o = d; *pv = o; }
    if (Tcl_ListObjAppendElement(interp, o, elem) != TCL_OK) { Tcl_SetErrorCode(interp, "TCL", "WRITE", "VARNAME", NULL); return 1; }
    return 0;
}

/* Typed int vector: a list local that provably holds only integers and never leaves the proc is kept as a raw int64 array.  It is
 * turned into a real Tcl list (tbc_ivec_list) the moment typed code gives up (deoptimisation), so Tcl semantics are unchanged. */
typedef struct { int64_t *p; int64_t n; int64_t cap; } tbc_ivec;
#define TBC_IVEC_MAX (INT64_C(1) << 26)
static tbc_ivec tbc_ivec_new(int64_t n, int64_t v) {
    tbc_ivec a = {NULL, 0, 0};
    if (n < 0 || n > TBC_IVEC_MAX) return a;
    a.p = v == 0 ? (int64_t *) calloc((size_t) (n ? n : 1), sizeof(int64_t)) : (int64_t *) malloc((size_t) (n ? n : 1) * sizeof(int64_t));
    if (!a.p) return a;
    a.n = n; a.cap = n ? n : 1;
    if (v != 0) { int64_t i; for (i = 0; i < n; i++) a.p[i] = v; }
    return a;
}
/* append v; 0 (nothing changed) when the vector would be too long or memory runs out */
static int tbc_ivec_push(tbc_ivec *a, int64_t v) {
    if (a->n == a->cap) {
        int64_t nc = a->cap ? a->cap * 2 : 16;
        int64_t *np;
        if (nc > TBC_IVEC_MAX) return 0;
        np = (int64_t *) realloc(a->p, (size_t) nc * sizeof(int64_t));
        if (!np) return 0;
        a->p = np; a->cap = nc;
    }
    a->p[a->n++] = v;
    return 1;
}
/* a copy of the vector (the one a foreach loop goes through, as the interpreter's goes through the list the loop began with); p is NULL if memory runs out */
static tbc_ivec tbc_ivec_copy(const tbc_ivec *a) {
    tbc_ivec c = {NULL, 0, 0};
    c.p = (int64_t *) malloc((size_t) (a->n ? a->n : 1) * sizeof(int64_t));
    if (!c.p) return c;
    if (a->n) memcpy(c.p, a->p, (size_t) a->n * sizeof(int64_t));
    c.n = a->n; c.cap = a->n ? a->n : 1;
    return c;
}
/* A list object (one reference) with the vector's contents; take != 0 releases the vector. */
static Tcl_Obj *tbc_ivec_list(tbc_ivec *a, int take) {
    Tcl_Obj *l;
    int64_t i;
    l = Tcl_NewListObj(0, NULL);
    for (i = 0; i < a->n; i++) Tcl_ListObjAppendElement(NULL, l, Tcl_NewWideIntObj(a->p[i]));
    Tcl_IncrRefCount(l);
    if (take) { free(a->p); a->p = NULL; a->n = a->cap = 0; }
    return l;
}
/* Typed string -> int map: a dict local that holds integer values only and never leaves the proc.  Entries keep their insertion order, as
 * a Tcl dict does.  A key that is a canonical integer (the text of an int64: no sign but -, no leading zero, not -0) is held as the integer, with no key object
 * (keys[e] == NULL, iks[e] the integer), whether it came in as an integer or as text; any other key is a shared Tcl_Obj reference compared by its string form.
 * tbc_imap_dict turns the map into a real dict. */
typedef struct { Tcl_Obj **keys; int64_t *vals; int64_t *iks; uint64_t *hs; int32_t *tab; size_t n, cap, tcap; } tbc_imap;
static void tbc_imap_free(tbc_imap *m) {
    size_t i;
    for (i = 0; i < m->n; i++) if (m->keys[i]) Tcl_DecrRefCount(m->keys[i]);
    free(m->keys); free(m->vals); free(m->iks); free(m->hs); free(m->tab);
    memset(m, 0, sizeof *m);
}
static int tbc_imap_init(tbc_imap *m) {
    memset(m, 0, sizeof *m);
    m->cap = 16; m->tcap = 32;
    m->keys = (Tcl_Obj **) malloc(m->cap * sizeof(Tcl_Obj *));
    m->vals = (int64_t *) malloc(m->cap * sizeof(int64_t));
    m->iks = (int64_t *) malloc(m->cap * sizeof(int64_t));
    m->hs = (uint64_t *) malloc(m->cap * sizeof(uint64_t));
    m->tab = (int32_t *) calloc(m->tcap, sizeof(int32_t));
    if (!m->keys || !m->vals || !m->iks || !m->hs || !m->tab) { free(m->keys); free(m->vals); free(m->iks); free(m->hs); free(m->tab); memset(m, 0, sizeof *m); return 0; }
    return 1;
}
TBC_INLINE uint64_t tbc_hash(const char *s, int len) {
    uint64_t h = UINT64_C(1469598103934665603);
    int i;
    for (i = 0; i < len; i++) { h ^= (unsigned char) s[i]; h *= UINT64_C(1099511628211); }
    return h ^ (h >> 29);
}
TBC_INLINE uint64_t tbc_ihash(int64_t k) {
    uint64_t h = (uint64_t) k * UINT64_C(0x9E3779B97F4A7C15);
    return h ^ (h >> 32);
}
/* is the text the canonical decimal form of an int64?  (then *k is the integer) */
TBC_INLINE int tbc_canon_int(const char *s, int len, int64_t *k) {
    uint64_t v = 0;
    int i = 0, neg = 0;
    if (len <= 0 || len > 20) return 0;
    if (s[0] == '-') { neg = 1; i = 1; if (len == 1) return 0; }
    if (s[i] == '0' && len - i > 1) return 0;
    if (neg && s[i] == '0') return 0;
    for (; i < len; i++) {
        unsigned d = (unsigned char) s[i] - '0';
        if (d > 9) return 0;
        if (v > (UINT64_MAX - d) / 10) return 0;
        v = v * 10 + d;
    }
    if (neg) { if (v > UINT64_C(9223372036854775808)) return 0; *k = (int64_t) (0 - v); }
    else { if (v > UINT64_C(9223372036854775807)) return 0; *k = (int64_t) v; }
    return 1;
}
TBC_INLINE int64_t tbc_imap_find_i(const tbc_imap *m, int64_t k, uint64_t h) {
    size_t mask = m->tcap - 1, i = (size_t) h & mask;
    for (;;) {
        int32_t e = m->tab[i];
        if (!e) return -1;
        e--;
        if (m->hs[e] == h && !m->keys[e] && m->iks[e] == k) return e;
        i = (i + 1) & mask;
    }
}
TBC_INLINE int64_t tbc_imap_find_s(const tbc_imap *m, const char *s, int len, uint64_t h) {
    size_t mask = m->tcap - 1, i = (size_t) h & mask;
    for (;;) {
        int32_t e = m->tab[i];
        if (!e) return -1;
        e--;
        if (m->hs[e] == h && m->keys[e]) {
            int kl;
            const char *ks = Tcl_GetStringFromObj(m->keys[e], &kl);
            if (kl == len && memcmp(ks, s, (size_t) len) == 0) return e;
        }
        i = (i + 1) & mask;
    }
}
TBC_INLINE int64_t tbc_imap_find(const tbc_imap *m, const char *s, int len) {
    int64_t k;
    if (tbc_canon_int(s, len, &k)) return tbc_imap_find_i(m, k, tbc_ihash(k));
    return tbc_imap_find_s(m, s, len, tbc_hash(s, len));
}
TBC_INLINE int tbc_imap_has(const tbc_imap *m, const char *s, int len) { return tbc_imap_find(m, s, len) >= 0; }
TBC_INLINE int tbc_imap_has_i(const tbc_imap *m, int64_t k) { return tbc_imap_find_i(m, k, tbc_ihash(k)) >= 0; }
static int tbc_imap_grow(tbc_imap *m) {
    size_t ncap = m->cap * 2, ntcap = m->tcap * 2, i;
    Tcl_Obj **nk = (Tcl_Obj **) realloc(m->keys, ncap * sizeof(Tcl_Obj *));
    int64_t *nv, *ni;
    uint64_t *nh;
    int32_t *nt;
    if (!nk) return 0;
    m->keys = nk;
    nv = (int64_t *) realloc(m->vals, ncap * sizeof(int64_t));
    if (!nv) return 0;
    m->vals = nv;
    ni = (int64_t *) realloc(m->iks, ncap * sizeof(int64_t));
    if (!ni) return 0;
    m->iks = ni;
    nh = (uint64_t *) realloc(m->hs, ncap * sizeof(uint64_t));
    if (!nh) return 0;
    m->hs = nh;
    m->cap = ncap;
    nt = (int32_t *) calloc(ntcap, sizeof(int32_t));
    if (!nt) return 0;
    for (i = 0; i < m->n; i++) {
        size_t j = (size_t) m->hs[i] & (ntcap - 1);
        while (nt[j]) j = (j + 1) & (ntcap - 1);
        nt[j] = (int32_t) (i + 1);
    }
    free(m->tab);
    m->tab = nt; m->tcap = ntcap;
    return 1;
}
/* add a new entry (the key is not in the map): ik/key as described above.  Returns 1 when memory runs out. */
static int tbc_imap_add(tbc_imap *m, Tcl_Obj *key, int64_t ik, uint64_t h, int64_t val) {
    size_t j;
    if (m->n >= (size_t) INT32_MAX / 2) return 1;
    if ((m->n + 1) * 2 > m->tcap || m->n == m->cap) { if (!tbc_imap_grow(m)) return 1; }
    m->keys[m->n] = key; m->iks[m->n] = ik; m->vals[m->n] = val; m->hs[m->n] = h;
    j = (size_t) h & (m->tcap - 1);
    while (m->tab[j]) j = (j + 1) & (m->tcap - 1);
    m->tab[j] = (int32_t) (m->n + 1);
    m->n++;
    return 0;
}
/* dict incr by an immediate, key an integer.  Returns 1, changing nothing, if the sum overflows or memory runs out (the caller then falls back to the generic code). */
static int tbc_imap_incr_i(tbc_imap *m, int64_t k, int64_t imm) {
    uint64_t h = tbc_ihash(k);
    int64_t e = tbc_imap_find_i(m, k, h);
    if (e >= 0) {
        int64_t r;
        if (__builtin_add_overflow(m->vals[e], imm, &r)) return 1;
        m->vals[e] = r;
        return 0;
    }
    return tbc_imap_add(m, NULL, k, h, imm);
}
/* the same, key as text; key: the key object when one exists (else NULL: one is made when the key is new and not an integer) */
static int tbc_imap_incr(tbc_imap *m, const char *s, int len, Tcl_Obj *key, int64_t imm) {
    int64_t k, e;
    uint64_t h;
    if (tbc_canon_int(s, len, &k)) return tbc_imap_incr_i(m, k, imm);
    h = tbc_hash(s, len);
    e = tbc_imap_find_s(m, s, len, h);
    if (e >= 0) {
        int64_t r;
        if (__builtin_add_overflow(m->vals[e], imm, &r)) return 1;
        m->vals[e] = r;
        return 0;
    }
    if (key) Tcl_IncrRefCount(key); else { key = Tcl_NewStringObj(s, len); Tcl_IncrRefCount(key); }
    if (tbc_imap_add(m, key, 0, h, imm)) { Tcl_DecrRefCount(key); return 1; }
    return 0;
}
/* a dict object (one reference) with the map's contents; take != 0 releases the map */
static Tcl_Obj *tbc_imap_dict(tbc_imap *m, int take) {
    Tcl_Obj *d = Tcl_NewDictObj();
    size_t i;
    for (i = 0; i < m->n; i++) Tcl_DictObjPut(NULL, d, m->keys[i] ? m->keys[i] : Tcl_NewWideIntObj(m->iks[i]), Tcl_NewWideIntObj(m->vals[i]));
    Tcl_IncrRefCount(d);
    if (take) tbc_imap_free(m);
    return d;
}
static int tbc_imap_get(const tbc_imap *m, const char *s, int len, int64_t *out) {
    int64_t e = tbc_imap_find(m, s, len);
    if (e < 0) return 0;
    *out = m->vals[e];
    return 1;
}
static int tbc_imap_get_i(const tbc_imap *m, int64_t k, int64_t *out) {
    int64_t e = tbc_imap_find_i(m, k, tbc_ihash(k));
    if (e < 0) return 0;
    *out = m->vals[e];
    return 1;
}
/* the key of a stack slot as bytes (a boxed value, or an integer formatted into buf) */
TBC_INLINE const char *tbc_key_obj(Tcl_Obj *o, int *len) { return Tcl_GetStringFromObj(o, len); }

/* Typed code uses the built-in command only while it has not been redefined (rename, proc, namespace shadowing). */
TBC_SHARED Tcl_ObjCmdProc *tbc_orig_lrepeat;
static void tbc_capture_builtins(Tcl_Interp *interp) {
    Tcl_CmdInfo ci;
    if (!tbc_orig_lrepeat && Tcl_GetCommandInfo(interp, "lrepeat", &ci)) tbc_orig_lrepeat = ci.objProc;
}
static int tbc_is_lrepeat(Tcl_Interp *interp) {
    Tcl_CmdInfo ci;
    return tbc_orig_lrepeat && Tcl_GetCommandInfo(interp, "lrepeat", &ci) && ci.objProc == tbc_orig_lrepeat;
}

/* Counters (compile with -DTBC_COV): how often each typed variant is entered and each hand-over point is taken.  A hand-over site also carries what the
 * instruction is (TBC_HITI), for tbc::hot.  The table is part of the shared state, so a module split over several files counts in one place. */
#ifdef TBC_COV
#define TBC_COV_MAX 131072
typedef struct { const char *name; const char *info; long hits; } TbcCov;
#if defined(TBC_SPLIT_USER)
extern TbcCov tbc_cov[TBC_COV_MAX];
#elif defined(TBC_SPLIT_OWNER)
TbcCov tbc_cov[TBC_COV_MAX];
#else
static TbcCov tbc_cov[TBC_COV_MAX];
#endif
TBC_SHARED int tbc_cov_n;
/* (the last slot takes the sites beyond the table: a module built for forced hand-over has a site at every instruction) */
#define TBC_HITI(nm, inf) do { static int idx_ = -1; if (idx_ < 0) { idx_ = tbc_cov_n < TBC_COV_MAX - 1 ? tbc_cov_n++ : TBC_COV_MAX - 1; tbc_cov[idx_].name = (nm); tbc_cov[idx_].info = (inf); } tbc_cov[idx_].hits++; } while (0)
#define TBC_HIT(nm) TBC_HITI(nm, NULL)
static int tbc_cov_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    Tcl_Obj *r = Tcl_NewObj();
    int i;
    (void) cd; (void) objc; (void) objv;
    for (i = 0; i < tbc_cov_n && i < TBC_COV_MAX; i++) {
        Tcl_ListObjAppendElement(NULL, r, Tcl_NewStringObj(tbc_cov[i].name, -1));
        Tcl_ListObjAppendElement(NULL, r, Tcl_NewWideIntObj(tbc_cov[i].hits));
    }
    Tcl_SetObjResult(interp, r);
    return TCL_OK;
}

/* tbc::hot ?-top n? ?-dict? ?-reset?: what the compiled procs did, from the counters.  For every proc: how often typed code was entered (by variant), how often it
 * was entered again at a loop head from the boxed code ("resumed"), how often it handed over at an instruction, after a call, and at which instructions (most often
 * first).  A site is "unsupported" when typed code has no code for the instruction at all (it hands over there every time), "guard" when it hands over only when
 * a check fails (an operand that is not the kind the code assumed, an overflow, a variable with a trace...).  -dict gives the same as a dict:
 * {proc {entries {variant n ...} resumed n resumes {variant n ...} handovers n aftercall n sites {{pc op detail kind n} ...}} ...}. */
typedef struct { const char *proc; int plen; long entries, resumed, handovers, aftercall; } TbcHotProc;
static const char *tbc_hot_split(const char *name, int *plen, int *pc, const char **variant, int *vlen) {
    /* "V:<proc>/<variant>[/RE]", "D:<proc>/<variant>:<pc>", "C:..." and "R:..." likewise */
    const char *p = name + 2, *end = name + strlen(name), *slash;
    *pc = -1;
    if (name[0] != 'V') { const char *c = end; while (c > p && c[-1] != ':') c--; if (c > p) { *pc = atoi(c); end = c - 1; } }
    else if (end - name > 3 && strcmp(end - 3, "/RE") == 0) end -= 3;
    slash = end; while (slash > p && slash[-1] != '/') slash--;
    if (slash <= p) { *plen = (int) (end - p); *variant = end; *vlen = 0; return p; }
    *plen = (int) (slash - 1 - p); *variant = slash; *vlen = (int) (end - slash);
    return p;
}
static int tbc_hot_cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int i, j, top = 5, asDict = 0, reset = 0, np = 0;
    TbcHotProc *procs;
    Tcl_Obj *res = Tcl_NewObj();
    (void) cd;
    for (i = 1; i < objc; i++) {
        const char *a = Tcl_GetString(objv[i]);
        if (strcmp(a, "-dict") == 0) asDict = 1;
        else if (strcmp(a, "-reset") == 0) reset = 1;
        else if (strcmp(a, "-top") == 0 && i + 1 < objc && Tcl_GetIntFromObj(interp, objv[++i], &top) == TCL_OK) ;
        else { Tcl_SetObjResult(interp, Tcl_NewStringObj("usage: tbc::hot ?-top n? ?-dict? ?-reset?", -1)); return TCL_ERROR; }
    }
    procs = (TbcHotProc *) ckalloc(sizeof(TbcHotProc) * (tbc_cov_n + 1));
    for (i = 0; i < tbc_cov_n && i < TBC_COV_MAX; i++) {
        int plen, pc, vlen; const char *variant; const char *pn = tbc_hot_split(tbc_cov[i].name, &plen, &pc, &variant, &vlen);
        for (j = 0; j < np; j++) if (procs[j].plen == plen && memcmp(procs[j].proc, pn, plen) == 0) break;
        if (j == np) { procs[np].proc = pn; procs[np].plen = plen; procs[np].entries = procs[np].resumed = procs[np].handovers = procs[np].aftercall = 0; np++; }
        switch (tbc_cov[i].name[0]) {
        case 'V': if (strcmp(tbc_cov[i].name + strlen(tbc_cov[i].name) - 3, "/RE") == 0 && strlen(tbc_cov[i].name) > 3) procs[j].resumed += tbc_cov[i].hits; else procs[j].entries += tbc_cov[i].hits; break;
        case 'D': procs[j].handovers += tbc_cov[i].hits; break;
        case 'C': case 'R': procs[j].aftercall += tbc_cov[i].hits; break;
        }
    }
    /* procs by hand-overs, then entries, descending (a plain selection sort: a module has some hundreds of procs) */
    for (i = 0; i < np; i++) for (j = i + 1; j < np; j++)
        if (procs[j].handovers > procs[i].handovers || (procs[j].handovers == procs[i].handovers && procs[j].entries + procs[j].resumed > procs[i].entries + procs[i].resumed)) { TbcHotProc t = procs[i]; procs[i] = procs[j]; procs[j] = t; }
    for (i = 0; i < np; i++) {
        Tcl_Obj *ents = Tcl_NewObj(), *resv = Tcl_NewObj(), *sites = Tcl_NewObj(), *pr = Tcl_NewObj();
        int ns = 0, *order = (int *) ckalloc(sizeof(int) * (tbc_cov_n + 1)), k; long *siteHits = (long *) ckalloc(sizeof(long) * (tbc_cov_n + 1));
        if (procs[i].entries + procs[i].resumed + procs[i].handovers + procs[i].aftercall == 0) { ckfree((char *) order); ckfree((char *) siteHits); continue; }
        for (j = 0; j < tbc_cov_n && j < TBC_COV_MAX; j++) {
            int plen, pc, vlen; const char *variant; const char *pn = tbc_hot_split(tbc_cov[j].name, &plen, &pc, &variant, &vlen);
            if (plen != procs[i].plen || memcmp(pn, procs[i].proc, plen) != 0 || !tbc_cov[j].hits) continue;
            if (tbc_cov[j].name[0] == 'V') {
                int nl = (int) strlen(tbc_cov[j].name), re = nl > 3 && strcmp(tbc_cov[j].name + nl - 3, "/RE") == 0;
                Tcl_Obj *l = re ? resv : ents;
                Tcl_ListObjAppendElement(NULL, l, Tcl_NewStringObj(variant, vlen));
                Tcl_ListObjAppendElement(NULL, l, Tcl_NewWideIntObj(tbc_cov[j].hits));
            }
            else if (tbc_cov[j].name[0] == 'D') order[ns++] = j;
        }
        /* the variants of a proc have the same instructions: one line per instruction, the hits of all variants added */
        { long *tot = (long *) ckalloc(sizeof(long) * (ns + 1)); int m = 0;
          for (j = 0; j < ns; j++) {
              int pj, vl; const char *vv; int pl; tbc_hot_split(tbc_cov[order[j]].name, &pl, &pj, &vv, &vl);
              for (k = 0; k < m; k++) { int pk, vl2; const char *vv2; int pl2; tbc_hot_split(tbc_cov[order[k]].name, &pl2, &pk, &vv2, &vl2); if (pk == pj) break; }
              if (k == m) { order[m] = order[j]; tot[m++] = tbc_cov[order[j]].hits; } else tot[k] += tbc_cov[order[j]].hits;
          }
          ns = m;
          for (j = 0; j < ns; j++) for (k = j + 1; k < ns; k++) if (tot[k] > tot[j]) { long tt = tot[j]; int t = order[j]; tot[j] = tot[k]; tot[k] = tt; order[j] = order[k]; order[k] = t; }
          for (j = 0; j < ns; j++) siteHits[j] = tot[j];
          ckfree((char *) tot); }
        for (j = 0; j < 0; j++) for (k = j + 1; k < ns; k++) if (tbc_cov[order[k]].hits > tbc_cov[order[j]].hits) { int t = order[j]; order[j] = order[k]; order[k] = t; }
        for (j = 0; j < ns; j++) {
            int plen, pc, vlen; const char *variant; const char *inf = tbc_cov[order[j]].info ? tbc_cov[order[j]].info : "? ? ?";
            Tcl_Obj *site = Tcl_NewObj(); const char *sp1 = strchr(inf, ' '), *sp2 = sp1 ? strchr(sp1 + 1, ' ') : NULL;
            (void) tbc_hot_split(tbc_cov[order[j]].name, &plen, &pc, &variant, &vlen);
            Tcl_ListObjAppendElement(NULL, site, Tcl_NewIntObj(pc));
            Tcl_ListObjAppendElement(NULL, site, Tcl_NewStringObj(sp1 ? sp1 + 1 : inf, sp2 ? (int) (sp2 - sp1 - 1) : -1));
            Tcl_ListObjAppendElement(NULL, site, Tcl_NewStringObj(sp2 ? sp2 + 1 : "", -1));
            Tcl_ListObjAppendElement(NULL, site, Tcl_NewStringObj(inf, sp1 ? (int) (sp1 - inf) : -1));
            Tcl_ListObjAppendElement(NULL, site, Tcl_NewWideIntObj(siteHits[j]));
            Tcl_ListObjAppendElement(NULL, sites, site);
        }
        ckfree((char *) order); ckfree((char *) siteHits);
        if (asDict) {
            Tcl_DictObjPut(NULL, pr, Tcl_NewStringObj("entries", -1), ents);
            Tcl_DictObjPut(NULL, pr, Tcl_NewStringObj("resumed", -1), Tcl_NewWideIntObj(procs[i].resumed));
            Tcl_DictObjPut(NULL, pr, Tcl_NewStringObj("resumes", -1), resv);
            Tcl_DictObjPut(NULL, pr, Tcl_NewStringObj("handovers", -1), Tcl_NewWideIntObj(procs[i].handovers));
            Tcl_DictObjPut(NULL, pr, Tcl_NewStringObj("aftercall", -1), Tcl_NewWideIntObj(procs[i].aftercall));
            Tcl_DictObjPut(NULL, pr, Tcl_NewStringObj("sites", -1), sites);
            Tcl_DictObjPut(NULL, res, Tcl_NewStringObj(procs[i].proc, procs[i].plen), pr);
        } else {
            long ent = procs[i].entries + procs[i].resumed;
            Tcl_AppendPrintfToObj(res, "%.*s: typed entries %ld, resumed at a loop head %ld, handed over at an instruction %ld, after a call %ld", procs[i].plen, procs[i].proc, procs[i].entries, procs[i].resumed, procs[i].handovers, procs[i].aftercall);
            if (ent > 0 && procs[i].handovers) Tcl_AppendPrintfToObj(res, " (%ld%% of entries and resumes)", (procs[i].handovers * 100) / ent);
            Tcl_AppendToObj(res, "\n", 1);
            Tcl_ListObjLength(NULL, sites, &ns);
            for (j = 0; j < ns && j < top; j++) {
                Tcl_Obj *site; int pc; long n; Tcl_ListObjIndex(NULL, sites, j, &site);
                { Tcl_Obj *e0, *e1, *e2, *e3, *e4; Tcl_ListObjIndex(NULL, site, 0, &e0); Tcl_ListObjIndex(NULL, site, 1, &e1); Tcl_ListObjIndex(NULL, site, 2, &e2); Tcl_ListObjIndex(NULL, site, 3, &e3); Tcl_ListObjIndex(NULL, site, 4, &e4);
                  Tcl_GetIntFromObj(NULL, e0, &pc); Tcl_GetWideIntFromObj(NULL, e4, (Tcl_WideInt *) &n);
                  Tcl_AppendPrintfToObj(res, "    pc %-4d %-16s %-10s %-24s %ld\n", pc, Tcl_GetString(e1), Tcl_GetString(e3), Tcl_GetString(e2), n); }
            }
            if (ns > top) Tcl_AppendPrintfToObj(res, "    (%d more sites)\n", ns - top);
        }
    }
    ckfree((char *) procs);
    if (reset) { for (i = 0; i < tbc_cov_n && i < TBC_COV_MAX; i++) tbc_cov[i].hits = 0; }
    Tcl_SetObjResult(interp, res);
    return TCL_OK;
}
#else
#define TBC_HIT(nm) ((void) 0)
#define TBC_HITI(nm, inf) ((void) 0)
#endif

#endif
