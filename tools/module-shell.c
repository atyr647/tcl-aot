/* module-shell: a tclsh with one generated module linked in, for running a program with its compiled procs.
 *
 * Compile with -DMODULE=<name>, the InitName given to translate.tcl (the module's Init function is <name>_Init).  The module is registered as a
 * static package, so a script starts it with `load {} <name>`; do that before the program defines its procs (procs defined earlier keep running in the
 * interpreter). */
#include <tcl.h>

#ifndef MODULE
#error "define MODULE to the name of the generated module"
#endif
#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define STR2(a) #a
#define STR(a) STR2(a)

extern int CAT(MODULE, _Init)(Tcl_Interp *);

static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR;
    Tcl_StaticPackage(NULL, STR(MODULE), CAT(MODULE, _Init), NULL);
    return TCL_OK;
}

int main(int argc, char **argv) {
    Tcl_Main(argc, argv, AppInit);
    return 0;
}
