/* The shell the tests run in: a tclsh with the generated module Testprocs linked in (load {} Testprocs) and two commands the tests use. */
#include <pthread.h>
#include <tcl.h>
#include <unistd.h>

extern int Testprocs_Init(Tcl_Interp *);

/* tbcasync ms: after ms milliseconds another thread marks an asynchronous handler that makes the running command fail with "async stop" */
static Tcl_AsyncHandler asyncHandler;

static int AsyncProc(ClientData cd, Tcl_Interp *interp, int code) {
    (void) cd;
    (void) code;
    Tcl_SetObjResult(interp, Tcl_NewStringObj("async stop", -1));
    return TCL_ERROR;
}

static void *AsyncThread(void *arg) {
    usleep((useconds_t) ((long) arg) * 1000);
    Tcl_AsyncMark(asyncHandler);
    return NULL;
}

static int AsyncCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    int ms;
    pthread_t thread;
    (void) cd;
    if (objc != 2 || Tcl_GetIntFromObj(interp, objv[1], &ms) != TCL_OK) return TCL_ERROR;
    if (!asyncHandler) asyncHandler = Tcl_AsyncCreate(AsyncProc, NULL);
    pthread_create(&thread, NULL, AsyncThread, (void *) (long) ms);
    pthread_detach(thread);
    return TCL_OK;
}

/* errline: the interpreter's errorLine, which standard error reporting leaves behind between commands */
static int ErrLineCmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void) cd;
    (void) objc;
    (void) objv;
    Tcl_SetObjResult(interp, Tcl_NewIntObj(Tcl_GetErrorLine(interp)));
    return TCL_OK;
}

static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) != TCL_OK) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "errline", ErrLineCmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "tbcasync", AsyncCmd, NULL, NULL);
    Tcl_StaticPackage(NULL, "Testprocs", Testprocs_Init, NULL);
    return TCL_OK;
}

int main(int argc, char **argv) {
    Tcl_Main(argc, argv, AppInit);
    return 0;
}
