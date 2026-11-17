/* module-shell: a tclsh (or a wish) with one generated module linked in, for running a program with its compiled procs.
 *
 * Compile with -DMODULE=<name>, the InitName given to translate.tcl (the module's Init function is <name>_Init).  The module is registered as a
 * static package, so a script starts it with `load {} <name>`; do that before the program defines its procs (procs defined earlier keep running in the
 * interpreter).
 *
 * Further macros, set by tools/tcl-aot (the drop-in build) and not needed to run a module by hand:
 *   -DTBC_AUTOLOAD        the module is started before the program's first command, so an unchanged program gets its compiled procs; the environment
 *                         variable TBC_OFF=1 leaves it out (the same shell then runs the interpreter alone: the reference for a comparison)
 *   -DTBC_WITH_TK         Tk (a static libtk) is registered as a package: `package require Tk` finds it, as in a tclsh that has Tk installed
 *   -DTBC_WISH            with TBC_WITH_TK: behave as `wish` (Tk_Main: the main window exists and wish's switches are understood)
 *   -DTBC_TCL_LIBRARY=\"dir\", -DTBC_TK_LIBRARY=\"dir\"   where the scripts of Tcl's and Tk's libraries are, when TCL_LIBRARY and TK_LIBRARY are not set
 * Environment (for tools/tcl-aot): TBC_CAPTURE=file records the procs the program defines (tbc::capture, written when it exits), see docs/usage.md. */
#include <stdlib.h>
#include <tcl.h>
#ifdef TBC_WITH_TK
#include <tk.h>
#endif

#ifndef MODULE
#error "define MODULE to the name of the generated module"
#endif
#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define STR2(a) #a
#define STR(a) STR2(a)

extern int CAT(MODULE, _Init)(Tcl_Interp *);

static void defaultdir(const char *var, const char *dir) {
    if (dir && !getenv(var)) {
        Tcl_Obj *o = Tcl_ObjPrintf("%s=%s", var, dir);
        Tcl_PutEnv(Tcl_GetString(o));
        Tcl_DecrRefCount(o);
    }
}

static int AppInit(Tcl_Interp *interp) {
#ifdef TBC_TCL_LIBRARY
    defaultdir("TCL_LIBRARY", TBC_TCL_LIBRARY);
#endif
#ifdef TBC_TK_LIBRARY
    defaultdir("TK_LIBRARY", TBC_TK_LIBRARY);
#endif
    if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR;
#ifdef TBC_WITH_TK
    Tcl_StaticPackage(NULL, "Tk", Tk_Init, Tk_SafeInit);
    /* what a pkgIndex.tcl does for a shared Tk: without it `package require Tk` does not find a Tk that is linked in */
    if (Tcl_EvalEx(interp, "package ifneeded Tk " TK_PATCH_LEVEL " {load {} Tk}", -1, TCL_EVAL_GLOBAL) != TCL_OK) return TCL_ERROR;
#ifdef TBC_WISH
    if (Tk_Init(interp) != TCL_OK) return TCL_ERROR;
#endif
#endif
    Tcl_StaticPackage(NULL, STR(MODULE), CAT(MODULE, _Init), NULL);
#ifdef TBC_AUTOLOAD
    /* after Tk_Init: the procs of Tk's own library are not part of the program */
    if (!getenv("TBC_OFF") || getenv("TBC_OFF")[0] != '1') {
        if (CAT(MODULE, _Init)(interp) != TCL_OK) return TCL_ERROR;
    }
#endif
    return TCL_OK;
}

int main(int argc, char **argv) {
#if defined(TBC_WITH_TK) && defined(TBC_WISH)
    Tk_Main(argc, argv, AppInit);
#else
    Tcl_Main(argc, argv, AppInit);
#endif
    return 0;
}
