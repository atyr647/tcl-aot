/* tcl-aot-sh: a tclsh with tbc::fingerprint, the shell translate.tcl runs in.
 *
 * It is built from the same Tcl as the programs the generated code will run in, so that the bytecode the translator reads (and fingerprints) is
 * the bytecode those programs compile. */
#include "tbc_hook.h"

static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "::tbc::fingerprint", tbc_fp_cmd, NULL, NULL);
    return TCL_OK;
}

int main(int argc, char **argv) {
    Tcl_Main(argc, argv, AppInit);
    return 0;
}
