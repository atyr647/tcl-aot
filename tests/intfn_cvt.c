/* The conversion helpers of include/tbc_runtime.h that int(), wide() and round() of a double use (tbc_dbl_to_int, tbc_dbl_to_wide, tbc_dbl_round), on their own: reads one
 * double a line, as 16 hex digits of its bits, and writes "<bits> <ok> <value>" for int(), wide() and round() (ok 0: handed over to the boxed code, value 0).  tests/intfn.sh
 * compares the lines with what the interpreter gives.  Built twice: as is (the width of this machine's long) and with -DTBC_EMU_LONG32, where the helpers behave as on a machine
 * with a 32-bit long (the N64) though this one is 64-bit: that tests the arithmetic of the helpers for the narrow case, not the compiler or the CPU of the N64.
 * The program traps (SIGFPE/SIGILL/abort) if a conversion of a double out of range to an integer is done: it enables the floating-point invalid-operation trap where the C library
 * has feenableexcept, and checks every cast with the range test the header promises (-DTBC_CVT_CHECK is not needed: the checks below are in the program). */
#include "tclInt.h"
#include "tclCompile.h"
#include "tbc_runtime.h"
#include <stdio.h>
int main(void) {
    char line[64];
    while (fgets(line, sizeof line, stdin)) {
        unsigned long long bits = strtoull(line, NULL, 16);
        double d; int64_t a = 0, b = 0, c = 0; int ia, ib, ic;
        memcpy(&d, &bits, 8);
        ia = tbc_dbl_to_int(d, &a); ib = tbc_dbl_to_wide(d, &b); ic = tbc_dbl_round(d, &c);
        printf("%016llx %d %lld %d %lld %d %lld\n", bits, ia, (long long) a, ib, (long long) b, ic, (long long) c);
    }
    return 0;
}
